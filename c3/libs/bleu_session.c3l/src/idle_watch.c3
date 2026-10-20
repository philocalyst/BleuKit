<*
 One idle threshold, as a handle: the IDLE and RESUMED edges of one `Session.watch_idle`.

 IdleWatch* watch = session.watch_idle((Duration)300_000_000)!;
 defer watch.close();
 while (try edge = watch.next())
 {
 // edge == IDLE or RESUMED
 }

 Each watch has its own reader on the shared event stream and keeps only its own edges. A
 watch must be closed before the session that made it.
*>
module bleu::session;
import std::time, bleu::deadline, bleu::error, bleu::observe, bleu::stream;

struct IdleWatch
{
	Session* session;
	ulong id;
	stream::Reader{Event}* reader;
}

<*
 Wait for the next edge of this watch: IDLE or RESUMED. Edges of other watches are skipped.

 @param timeout : "How long to wait for the edge; `time::FOREVER` blocks"
 @return "IDLE or RESUMED"
 @return? TIMEOUT : "No edge arrived in time"
 @return? error::DISCONNECTED : "The session was closed"
*>
fn EventKind? IdleWatch.next(&self, Duration timeout = time::FOREVER)
{
	Deadline deadline = deadline::after(timeout);
	while (true)
	{
		Duration left           = timeout == time::FOREVER ? time::FOREVER : deadline.remaining();
		Snapshot{Event}* packet = self.reader.next(left)!;
		defer packet.release();
		if (packet.value.watch != self.id) continue;
		return packet.value.kind;
	}
}

<*
 Stop reporting edges and free the watch. The handle is invalid afterwards.
*>
fn void IdleWatch.close(&self)
{
	// If the worker is already stopping, it drops every watch with it. A full queue (BUSY) is not retried:
	// the worker then keeps this watch's slot, and reports its edges, until the session closes. Nothing
	// else receives them, because watch ids are never reused. The cost is one idle slot per such close.
	if (catch err = self.session.hub.post({ .kind = CommandKind.UNWATCH_IDLE, .watch = self.id }))
	{
		// Discarded on purpose: see above.
	}
	self.reader.release();
	Session* session = self.session;
	alloc::free(session.allocator, self);
}