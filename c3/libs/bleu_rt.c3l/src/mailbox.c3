<*
 A multi-producer, single-consumer queue of `Command` values, and the wake-up
 that tells the owning worker that it is not empty.

 Any thread may `post`; only the owning worker calls `take_all`. Commands are
 plain values copied in and out, so nothing in the queue is owned by it. The
 ring buffer grows geometrically (doubling) up to `max_capacity`; past that,
 `post` refuses with BUSY rather than letting memory grow without bound.

 Lost-wake-up discipline: `post` enqueues and signals under the same mutex that
 `take_all` holds while it drains the wake-up, so a command posted just after
 the consumer looked at an empty queue always raises a new signal.
*>
module bleu::rt::mailbox <Command>;
import std::thread, bleu::error, bleu::rt::wakeup;

<* Capacity the ring starts with (before it grows). *>
const usz INITIAL_CAPACITY = 16;

<* Capacity used when the caller does not choose one. *>
const usz DEFAULT_MAX_CAPACITY = 4096;

<*
 The queue. Create it with `init`, release it with `free`.

 The embedded wake-up is what a worker's poller waits on; see `wakeup()`.
*>
struct Mailbox
{
	Allocator allocator;
	Mutex mutex;
	Wakeup wake;
	Command[] ring;
	usz head;
	usz count;
	usz max_capacity;
	bool closed;
}

<*
 Create an empty, open mailbox.

 @param allocator : "Allocator for the ring buffer"
 @param max_capacity : "Most commands the queue holds before `post` returns BUSY"
 @require max_capacity > 0 : "A mailbox needs room for at least one command"
 @return? error::BACKEND_FAILURE : "The wake-up could not be created"
*>
fn void? Mailbox.init(&self, Allocator allocator, usz max_capacity = DEFAULT_MAX_CAPACITY)
{
	self.allocator = allocator;
	self.max_capacity = max_capacity;
	self.mutex.init()!!;
	if (catch err = self.wake.init())
	{
		self.mutex.destroy();
		return err~;
	}
	usz initial = min(INITIAL_CAPACITY, max_capacity);
	self.ring = alloc::new_array(allocator, Command, (sz)initial);
}

<*
 Release the ring buffer and the wake-up. Commands still queued are discarded.
 The mailbox must not be used afterwards.
*>
fn void Mailbox.free(&self)
{
	self.wake.close();
	self.mutex.destroy();
	alloc::free(self.allocator, self.ring.ptr);
	*self = { };
}

<*
 Enqueue a command and wake the consumer. Callable from any thread.

 @return? error::UNAVAILABLE : "The mailbox is closed; no further commands are accepted"
 @return? error::BUSY : "The queue holds `max_capacity` commands already"
*>
fn void? Mailbox.post(&self, Command command)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	if (self.closed)
	{
		return error::raise(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "mailbox is closed")~;
	}
	if (self.count == (usz)self.ring.len)
	{
		if (self.count >= self.max_capacity)
		{
			return error::raise(error::BUSY, error::Domain.INTERNAL, 0, "mailbox is full (%d commands)", self.count)~;
		}
		self.grow();
	}
	self.ring[(self.head + self.count) % (usz)self.ring.len] = command;
	self.count++;
	// The wake-up is open for as long as the mailbox is, so a failure here is a bug.
	self.wake.signal()!!;
}

<*
 Move every queued command into `buffer`, in the order they were posted, and
 return how many were moved. If `buffer` is smaller than the queue, the rest stay
 queued and the wake-up stays signalled, so the next wait returns at once.

 Must be called by the owning worker only.
*>
fn usz Mailbox.take_all(&self, Command[] buffer)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	usz n = min(self.count, (usz)buffer.len);
	for (usz i = 0; i < n; i++)
	{
		buffer[i] = self.ring[self.head];
		self.head = (self.head + 1) % (usz)self.ring.len;
	}
	self.count -= n;
	if (self.count == 0)
	{
		// Empty under the lock: nothing can be posted between this drain and the next
		// wait without raising a fresh signal.
		self.wake.drain()!!;
	}
	else
	{
		self.wake.signal()!!;
	}
	return n;
}

<*
 Refuse further posts and wake the consumer, so that it can finish what is queued
 and stop. Idempotent.
*>
fn void Mailbox.close(&self)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	if (self.closed) return;
	self.closed = true;
	self.wake.signal()!!;
}

<* True once `close` has been called. *>
fn bool Mailbox.is_closed(&self)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	return self.closed;
}

<* Number of commands queued right now. A snapshot: others may post at once. *>
fn usz Mailbox.pending(&self)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	return self.count;
}

<* The wake-up a worker's poller should wait on. Valid until `free`. *>
fn Wakeup* Mailbox.wakeup(&self) @inline => &self.wake;

// Double the ring (or grow to max_capacity), keeping the queue order. Internal to
// `post`: entered with the mutex held.
fn void Mailbox.grow(&self)
{
	usz old_len      = (usz)self.ring.len;
	usz new_len      = min(old_len * 2, self.max_capacity);
	Command[] bigger = alloc::new_array(self.allocator, Command, (sz)new_len);
	for (usz i = 0; i < self.count; i++)
	{
		bigger[i] = self.ring[(self.head + i) % old_len];
	}
	alloc::free(self.allocator, self.ring.ptr);
	self.ring = bigger;
	self.head = 0;
}