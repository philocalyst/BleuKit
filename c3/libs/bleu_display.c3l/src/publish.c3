<*
 Publishing a state and the events that describe it, shared by every backend. A backend builds a
 snapshot with `hub.begin()`, fills it, and hands it here; the events are the difference from the
 last published state, and a state equal to the last one is dropped.
*>
module bleu::display;
import std::collections::maybe, bleu::equal, bleu::observe, bleu::stream, bleu::service;

<*
 Publish `snapshot` (from `hub.begin()`, consumed here) and emit one event per output that was
 added, removed or changed since the last published state.
*>
fn void publish_snapshot(DisplayHub* hub, Snapshot{State}* snapshot)
{
	if (try old = hub.latest())
	{
		defer old.release();
		emit_changes(hub, old.value, snapshot.value);
	}
	hub.publish_if_changed(snapshot);
}

// Emit one event per output that appeared, disappeared or changed between two states.
fn void emit_changes(DisplayHub* hub, State before, State after)
{
	foreach (output : after.outputs)
	{
		Maybe{sz} previous = index_of_output(before.outputs, output.id);
		if (!previous.has_value)
		{
			emit(hub, OUTPUT_ADDED, output.id);
		}
		else if (!equal::deep(before.outputs[previous.value], output))
		{
			emit(hub, OUTPUT_CHANGED, output.id);
		}
	}
	foreach (output : before.outputs)
	{
		if (!index_of_output(after.outputs, output.id).has_value)
		{
			emit(hub, OUTPUT_REMOVED, output.id);
		}
	}
}

<*
 Deliver one event with its own copy of the output id. Without a hub (a session driven directly, as
 the tests do) there is no one to tell.
*>
fn void emit(DisplayHub* hub, EventKind kind, String output_id)
{
	if (!hub) return;
	Snapshot{Event}* packet = hub.emit_begin();
	packet.value = { .kind = kind, .output_id = output_id.copy(packet.allocator()) };
	hub.emit(packet);
}