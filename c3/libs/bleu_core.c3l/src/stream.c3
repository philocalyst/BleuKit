<*
 Edge-triggered events: things that *happened* and have no lasting state
 (a notification arrived, a hotkey fired, a credential is wanted).

 Every `Reader` receives every event published after it subscribed, through its
 own bounded queue. A reader that falls behind loses the *oldest* events and is
 told how many via `Reader.take_dropped()`; the right reaction is to re-read
 the relevant `Observable`, never to assume the event log is complete.
*>
module bleu::stream <Event>;
import std::thread, std::atomic, std::time, std::collections::list, bleu::error, bleu::observe, bleu::deadline;

alias Packet = Snapshot{Event};

const DEFAULT_DEPTH = 64;

struct Reader
{
	Stream* source;
	Mutex mutex;
	ConditionVariable ready;
	Packet*[] ring;
	sz head;
	sz count;
	ulong dropped;
	bool closed;
}

struct Stream
{
	Mutex mutex;
	Allocator allocator;
	List{Reader*} readers;
	bool closed;
}

fn void Stream.init(&self, Allocator allocator)
{
	*self = { .allocator = allocator };
	self.mutex.init()!!;
	self.readers.init(allocator);
}

<*
 Close every reader (their `next` returns `DISCONNECTED` once drained).
 Readers must still be released by their owners.
*>
fn void Stream.close(&self)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	self.closed = true;
	foreach (reader : self.readers) shutdown(reader);
	self.readers.free();
}

<*
 Subscribe. Only events published after this call are delivered.

 @param depth : "Queue capacity; when exceeded the oldest event is dropped"
 @require depth > 0
 @return? error::DISCONNECTED : "The stream is already closed"
*>
fn Reader*? Stream.subscribe(&self, sz depth = DEFAULT_DEPTH)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	if (self.closed) return error::DISCONNECTED~;
	Reader* r = alloc::new(self.allocator, Reader);
	r.source = self;
	r.ring = alloc::new_array(self.allocator, Packet*, depth);
	r.mutex.init()!!;
	r.ready.init()!!;
	self.readers.push(r);
	return r;
}

<*
 Build a packet to publish. See `observe::begin`.
*>
fn Packet* Stream.begin(&self) @inline => observe::begin{Event}(self.allocator);

<*
 Deliver a packet to every reader. Takes ownership of the caller's reference.
*>
fn void Stream.publish(&self, Packet* packet)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	foreach (reader : self.readers) deliver(reader, packet.retain());
	packet.release();
}

fn void deliver(Reader* self, Packet* packet) @private
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	if (self.closed)
	{
		packet.release();
		return;
	}
	if (self.count == self.ring.len)
	{
		self.ring[self.head].release();
		self.head = (self.head + 1) % self.ring.len;
		self.count--;
		self.dropped++;
	}
	self.ring[(self.head + self.count) % self.ring.len] = packet;
	self.count++;
	self.ready.signal()!!;
}

fn void shutdown(Reader* self) @private
{
	self.mutex.lock()!!;
	self.closed = true;
	self.ready.broadcast()!!;
	self.mutex.unlock();
}

<*
 Wait for the next event.

 @param timeout : "How long to wait; `time::FOREVER` blocks"
 @return "The packet, retained for the caller"
 @return? TIMEOUT : "No event arrived in time"
 @return? error::DISCONNECTED : "The stream closed and the queue is empty"
*>
fn Packet*? Reader.next(&self, Duration timeout = time::FOREVER)
{
	Deadline deadline = deadline::after(timeout);
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	while (self.count == 0)
	{
		if (self.closed) return error::DISCONNECTED~;
		if (!deadline.wait(&self.ready, &self.mutex)) return TIMEOUT~;
	}
	Packet* packet = self.ring[self.head];
	self.head = (self.head + 1) % self.ring.len;
	self.count--;
	return packet;
}

<* Number of events lost to overflow since the last call. *>
fn ulong Reader.take_dropped(&self)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	ulong n = self.dropped;
	self.dropped = 0;
	return n;
}

<* Unsubscribe and free the reader, discarding anything still queued. *>
fn void Reader.release(&self)
{
	Stream* source = self.source;
	source.mutex.lock()!!;
	foreach (i, r : source.readers)
	{
		if (r != self) continue;
		source.readers.remove_at(i);
		break;
	}
	source.mutex.unlock();
	for (sz i = 0; i < self.count; i++) self.ring[(self.head + i) % self.ring.len].release();
	Allocator a = source.allocator;
	self.mutex.destroy();
	self.ready.destroy()!!;
	alloc::free(a, self.ring.ptr);
	alloc::free(a, self);
}