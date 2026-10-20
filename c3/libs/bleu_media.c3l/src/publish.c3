<*
 Publishing a state built by a backend, and emitting the events of the change.

 Every backend builds a complete state into a snapshot, then calls
 `publish_built`. The state is published only when it differs from the last one
 (`Hub.publish_if_changed`), and the events between the two are emitted. A state
 that did not change emits nothing.
*>
module bleu::media;
import std::collections::list, bleu::observe, bleu::service, bleu::stream;

// Longest text a peer's string may carry into the state. Longer text is cut on a character boundary.
const usz MAX_TEXT_BYTES = 4096;

<*
 `text`, cut to `MAX_TEXT_BYTES` on a character boundary, copied into `allocator`;
 the empty string is returned as is, without copying.
*>
fn String copy_text(String text, Allocator allocator)
{
	String kept = cut_utf8(text, MAX_TEXT_BYTES);
	return kept.len == 0 ? "" : kept.copy(allocator);
}

// The longest prefix of `text` that is at most `max` bytes and ends on a UTF-8 character boundary.
fn String cut_utf8(String text, usz max)
{
	if ((usz)text.len <= max) return text;
	usz cut = max;
	// A continuation byte is 10xxxxxx: back up to the lead byte of the character the cut would split.
	while (cut > 0 && (text[cut] & 0xC0) == 0x80) cut--;
	return text[0:cut];
}

<* Publish a failure: the backend cannot read the players now. Players stay as they were; `reason` is copied. *>
fn void emit_failure(MediaHub* hub, String reason)
{
	Packet{Event}* packet = hub.emit_begin();
	packet.value = { .kind = BACKEND_FAILED, .id = copy_text(reason, packet.allocator()) };
	hub.emit(packet);
}

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
		State none             = { };
		State* previous        = before != null ? &before.value : &none;
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