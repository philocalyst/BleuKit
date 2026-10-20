<*
 Publishing state and events to a topic. Both are callable from any thread.

 Publications keep their order: a publication that returns before another one
 starts is seen before it by every subscriber. `publish` also replaces the
 snapshot that a new subscriber receives first.
*>
module bleu::ipc @feat(POSIX);
import bleu::error, bleu::ipc::wire, std::atomic;

<*
 Publish the topic's state. Every subscriber receives it, and a subscriber that
 is behind receives only the newest state (state frames are coalesced). The
 value is copied before this returns.

 @param json_data : "One JSON value on one line"
 @return? error::INVALID_ARGUMENT : "The value is empty or spans lines; nothing is published"
 @return? error::UNAVAILABLE : "The server has been freed"
 @return? error::BUSY : "The I/O queue is full; the state was not published"
*>
fn void? Topic.publish(&self, String json_data) @maydiscard
{
	if (!wire::is_single_line(json_data))
	{
		return error::raise(
			error::INVALID_ARGUMENT,
			error::Domain.INTERNAL,
			0,
			"state must be one non-empty line of JSON"
		)~;
	}
	Allocator allocator = self.server.allocator;
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	// The snapshot is replaced only when the fan-out was queued, so the two cannot disagree.
	String kept = json_data.copy(allocator);
	if (catch err = self.server.post_io({ .kind = PUBLISH, .topic = self, .bytes = json_data.copy(allocator) }))
	{
		alloc::free(allocator, kept.ptr);
		return err~;
	}
	if (self.has_snapshot) alloc::free(allocator, self.snapshot.ptr);
	self.snapshot = kept;
	self.has_snapshot = true;
}

<*
 Send one occurrence to the subscribers connected now. Nothing is kept: a client
 that subscribes later does not receive it. Occurrences are never coalesced.

 @param json_data : "One JSON value on one line"
 @return? error::INVALID_ARGUMENT : "The value is empty or spans lines"
 @return? error::UNAVAILABLE : "The server has been freed"
 @return? error::BUSY : "The I/O queue is full"
*>
fn void? Topic.publish_event(&self, String json_data) @maydiscard
{
	if (!wire::is_single_line(json_data))
	{
		return error::raise(
			error::INVALID_ARGUMENT,
			error::Domain.INTERNAL,
			0,
			"event must be one non-empty line of JSON"
		)~;
	}
	return self.server.post_io(
		{ .kind = PUBLISH_EVENT, .topic = self, .bytes = json_data.copy(self.server.allocator) }
	);
}