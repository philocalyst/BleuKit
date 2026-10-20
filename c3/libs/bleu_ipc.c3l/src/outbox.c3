<*
 The frames waiting to be written to one client, in order, with the rules that
 keep a slow client from growing memory without bound.

 Two kinds of frame share the queue:

 * state frames carry a coalescing key (the topic, or the `server` service).
   A new state frame for the same subscription and key replaces the queued one,
   so a client that falls behind receives only the latest value of each state.
 * every other frame (replies, events) has `NO_KEY` and is never replaced.

 The frame the socket is part-way through is never replaced: its bytes are
 already on the wire. The total of unsent bytes is bounded by `max_pending`,
 except that one frame is always accepted into an empty queue.

 Not thread-safe: the I/O thread owns every outbox.
*>
module bleu::ipc::outbox @feat(POSIX);
import std::collections::list, bleu::error;

<* Coalescing key of a frame that is never replaced by a later one. *>
const usz NO_KEY = usz::max;

<* One complete line waiting to be written. *>
struct Frame
{
	// The line, newline included. The outbox owns the bytes.
	String bytes;
	// Bytes the socket has already accepted.
	usz sent;
	// The subscription (or request) id the frame belongs to.
	long request_id;
	// Frames with equal request id and key coalesce; `NO_KEY` never coalesces.
	usz key;
}

<* The queue of frames for one connection. *>
struct Outbox
{
	Allocator allocator;
	List{Frame} frames;
	usz pending;
	usz max_pending;
}

<*
 Create an empty outbox.

 @param allocator : "Allocator for the frame bytes"
 @param max_pending : "Most unsent bytes the queue holds before refusing a frame"
*>
fn void Outbox.init(&self, Allocator allocator, usz max_pending)
{
	self.allocator = allocator;
	self.max_pending = max_pending;
	self.frames.init(allocator, 8);
	self.pending = 0;
}

<* Release every queued frame and the queue. *>
fn void Outbox.free(&self)
{
	for (sz i = 0; i < self.frames.len(); i++)
	{
		alloc::free(self.allocator, self.frames.get_ref(i).bytes.ptr);
	}
	self.frames.free();
	self.pending = 0;
}

<* True when nothing is waiting to be written. *>
fn bool Outbox.is_empty(&self) @inline => self.frames.is_empty();

<*
 The frame to write next. Only valid when the outbox is not empty.
*>
fn Frame* Outbox.front(&self) @inline => self.frames.get_ref(0);

<*
 Queue a frame. The outbox takes ownership of `bytes` in every case: when the
 frame is refused, the bytes are released here.

 A state frame replaces the newest queued frame with the same request id and
 key, unless that frame has already started to go out.

 @param bytes : "One complete line, newline included, from `alloc` of this outbox's allocator"
 @return? error::OUT_OF_RANGE : "Queueing the frame would exceed `max_pending`"
*>
fn void? Outbox.put(&self, String bytes, long request_id, usz key) @maydiscard
{
	if (key != NO_KEY)
	{
		sz index = find_coalescible(self, request_id, key);
		if (index >= 0)
		{
			Frame* old = self.frames.get_ref(index);
			usz next_pending = self.pending - (usz)old.bytes.len + (usz)bytes.len;
			if (next_pending > self.max_pending)
			{
				alloc::free(self.allocator, bytes.ptr);
				return error::raise(error::OUT_OF_RANGE, error::Domain.INTERNAL, 0, "outbox would exceed %d bytes", self.max_pending)~;
			}
			self.pending = next_pending;
			alloc::free(self.allocator, old.bytes.ptr);
			old.bytes = bytes;
			return;
		}
	}
	if (!self.frames.is_empty() && self.pending + (usz)bytes.len > self.max_pending)
	{
		alloc::free(self.allocator, bytes.ptr);
		return error::raise(error::OUT_OF_RANGE, error::Domain.INTERNAL, 0, "outbox would exceed %d bytes", self.max_pending)~;
	}
	self.frames.push({ .bytes = bytes, .sent = 0, .request_id = request_id, .key = key });
	self.pending += (usz)bytes.len;
}

<*
 Record that the socket accepted `count` bytes of the front frame. A frame that
 is complete is removed and its bytes released.

 @require !self.is_empty() : "Only the front frame of a non-empty outbox has bytes accepted"
*>
fn void Outbox.advance(&self, usz count)
{
	Frame* front = self.frames.get_ref(0);
	front.sent += count;
	self.pending -= count;
	if (front.sent < (usz)front.bytes.len) return;
	alloc::free(self.allocator, front.bytes.ptr);
	self.frames.remove_at(0);
}

// Index of the newest frame with this request id and key that has not started
// to go out, or -1.
fn sz find_coalescible(Outbox* outbox, long request_id, usz key) @private
{
	for (sz i = outbox.frames.len() - 1; i >= 0; i--)
	{
		Frame* frame = outbox.frames.get_ref(i);
		if (frame.request_id != request_id || frame.key != key) continue;
		return frame.sent == 0 ? i : -1;
	}
	return -1;
}
