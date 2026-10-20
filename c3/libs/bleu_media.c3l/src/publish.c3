<*
 Publishing a state built by a backend, and emitting the events of the change.

 Every backend builds a complete state into a snapshot, then calls
 `publish_built`. The state is published only when it differs from the last one
 (`Hub.publish_if_changed`), and the events between the two are emitted. A state
 that did not change emits nothing.
*>
module bleu::media;
import std::collections::list, bleu::observe, bleu::service, bleu::stream;

<* `text`, or a copy of it in `allocator`; the empty string is returned as is, without copying. *>
fn String copy_text(String text, Allocator allocator) => text.len == 0 ? "" : text.copy(allocator);

<*
 Publish `snapshot` (built with `hub.begin()`, its value filled from the
 snapshot's allocator) if it changed, and emit the events of the change.

 @param seeked : "Handles of players that reported a seek since the last publication"
*>
fn void publish_built(MediaHub* hub, Snapshot{State}* snapshot, ulong[] seeked)
{
	Snapshot{State}* before = null;
	if (try latest = hub.latest()) before = latest;
	bool changed = hub.publish_if_changed(snapshot);
	if (changed) emit_changes(hub, before, seeked);
	if (before != null) before.release();
}

// Emit the events between `before` (null: nothing was published yet) and the state just published.
fn void emit_changes(MediaHub* hub, Snapshot{State}* before, ulong[] seeked) @private
{
	@pool()
	{
		State none = {};
		State* previous = before != null ? &before.value : &none;
		Snapshot{State}* after = hub.latest()!!;
		defer after.release();
		List{Event} events;
		events.init(tmem);
		collect_events(previous, &after.value, seeked, &events);
		foreach (e : events.array_view())
		{
			Packet{Event}* packet = hub.emit_begin();
			packet.value = { .kind = e.kind, .player = e.player, .id = copy_text(e.id, packet.allocator()) };
			hub.emit(packet);
		}
	};
}
