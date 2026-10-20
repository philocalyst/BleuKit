<*
 Wait for readiness of several native sources and a wake-up, all at once.

 A worker owns one `Poller`. It registers its native sources (sockets, pipes,
 timers, events) with a tag each, and calls `wait`. The wake-up is always part
 of the wait; when it fires, `wait` drains it, so callers never see it
 remain set. Ready sources are reported as `Ready` values carrying the tag
 they were registered with.

 Not thread-safe: `add`, `remove` and `wait` belong to the owning worker thread.
 Other threads reach the worker through the mailbox, which signals the wake-up.

 Backends: POSIX uses poll(2); Windows uses WaitForMultipleObjects, or
 MsgWaitForMultipleObjects when window messages must be pumped (UI threads).
*>
module bleu::rt::poller;
import std::time, bleu::error, bleu::deadline, bleu::rt, bleu::rt::wakeup;

<*
 What a source is waited for. On POSIX `readable`, `writable` select the events
 requested; `hangup` and `failed` are always reported when they happen. On
 Windows a waitable object carries no direction, so a signalled object is always
 reported as `readable` and `interest` is ignored.
*>
bitstruct Interest : char
{
	bool readable;
	bool writable;
	bool hangup;
	bool failed;
}

<*
 A native object to wait on, with the tag the owner recognises it by. `handle`
 is a file descriptor (POSIX) or a HANDLE (Windows) that the poller does not own.
*>
struct Source
{
	Native handle;
	Interest interest;
	usz tag;
}

<*
 One source that became ready. `events` says which conditions were seen.
*>
struct Ready
{
	usz tag;
	Interest events;
}

<* Tag reported when the wake-up fired. The poller drains it before returning. *>
const usz WAKEUP_TAG = usz::max;

<* Tag reported when window messages are waiting (Windows message mode only). *>
const usz WINDOW_MESSAGES_TAG = usz::max - 1;

<*
 A set of sources plus the wake-up, with fixed storage.

 `sources` holds the registered sources in the first `count` slots.
 `entries` and `ready` are the scratch arrays of the native wait (the platform
 file defines the native entry type).
*>
struct Poller
{
	Allocator allocator;
	Wakeup* wakeup;
	bool window_messages;
	usz capacity;
	usz count;
	Source[] sources;
	NativeWait[] entries;
	Ready[] ready;
}

<*
 Create a poller for at most `capacity` sources. The wake-up must already be
 open and must outlive the poller.

 @param [&inout] allocator : "Allocator for the fixed storage"
 @param wakeup : "The wake-up that every wait includes"
 @param capacity : "Maximum number of registered sources"
 @param window_messages : "Windows only: also return when window messages are queued"
 @require wakeup != null && wakeup.is_open : "The wake-up must be open"
 @return? error::UNSUPPORTED : "window_messages on a platform without window messages"
 @return? error::OUT_OF_RANGE : "capacity exceeds what one native wait can hold"
*>
fn void? Poller.init(&self, Allocator allocator, Wakeup* wakeup, usz capacity, bool window_messages = false)
{
	native_check_limits(capacity, window_messages)!;
	self.allocator = allocator;
	self.wakeup = wakeup;
	self.window_messages = window_messages;
	self.capacity = capacity;
	self.sources = alloc::new_array(allocator, Source, (sz)capacity);
	self.entries = alloc::new_array(allocator, NativeWait, (sz)(capacity + 1));
	self.ready = alloc::new_array(allocator, Ready, (sz)(capacity + 2));
}

<* Release the fixed storage. The wake-up is not closed. *>
fn void Poller.free(&self)
{
	alloc::free(self.allocator, self.sources.ptr);
	alloc::free(self.allocator, self.entries.ptr);
	alloc::free(self.allocator, self.ready.ptr);
	*self = {};
}

<*
 Register a source. Tags must be unique and must not be `WAKEUP_TAG` or
 `WINDOW_MESSAGES_TAG`.

 @return? error::OUT_OF_RANGE : "The poller is full"
 @return? error::INVALID_ARGUMENT : "The tag is reserved or already registered"
*>
fn void? Poller.add(&self, Source source)
{
	if (self.count == self.capacity)
	{
		return error::raise(error::OUT_OF_RANGE, error::Domain.INTERNAL, 0, "poller already holds %d sources", self.capacity)~;
	}
	if (source.tag == WAKEUP_TAG || source.tag == WINDOW_MESSAGES_TAG)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "tag %d is reserved", source.tag)~;
	}
	foreach (existing : self.sources[:self.count])
	{
		if (existing.tag == source.tag)
		{
			return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "tag %d is already registered", source.tag)~;
		}
	}
	self.sources[self.count++] = source;
}

<*
 Unregister the source with this tag. Order of the remaining sources is kept.

 @return? NOT_FOUND : "No source has this tag"
*>
fn void? Poller.remove(&self, usz tag)
{
	foreach (i, source : self.sources[:self.count])
	{
		if (source.tag != tag) continue;
		for (usz j = (usz)i; j + 1 < self.count; j++) self.sources[j] = self.sources[j + 1];
		self.count--;
		return;
	}
	return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "no source with tag %d", tag)~;
}

<*
 `d` in whole milliseconds, rounded up so that a short wait never becomes a
 busy loop. Zero or less gives zero.
*>
fn long duration_ceil_ms(Duration d) @private
{
	if (d <= time::DURATION_ZERO) return 0;
	return (long)((d - 1) / time::MS) + 1;
}

<*
 Block until a source or the wake-up is ready, or `timeout` passes.

 The returned slice points into the poller's storage and is valid until the
 next `wait`. A wake-up that fired is drained before this returns.

 @param timeout : "How long to wait; `time::FOREVER` blocks until something happens"
 @return "The ready sources, at least one"
 @return? TIMEOUT : "Nothing became ready in time"
 @return? error::BACKEND_FAILURE : "The OS wait failed"
*>
fn Ready[]? Poller.wait(&self, Duration timeout = time::FOREVER)
{
	Deadline deadline = deadline::after(timeout);
	usz n = native_wait(self, deadline)!;
	Ready[] result = self.ready[:n];
	foreach (ready : result)
	{
		if (ready.tag == WAKEUP_TAG) self.wakeup.drain()!;
	}
	return result;
}
