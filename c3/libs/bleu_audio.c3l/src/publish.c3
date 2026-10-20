<*
 Publishing a backend's whole state: unchanged states are dropped, a changed
 state is published and the difference is emitted as events.
*>
module bleu::audio;
import bleu::equal, bleu::observe, bleu::service;

<*
 Publish `next` (built from the hub's allocator). Takes the caller's reference.

 The first publication emits no events: a new subscriber reads the state
 itself. Later ones emit what changed since the previous state.
*>
fn void publish_snapshot(AudioHub* hub, Snapshot{State}* next)
{
	Snapshot{State}* previous = null;
	if (try current = hub.latest()) previous = current;
	if (previous && equal::deep(previous.value, next.value))
	{
		previous.release();
		next.release();
		return;
	}
	// Keep `next` alive for the events: the observable drops its reference when superseded.
	next.retain();
	hub.publish(next);
	if (previous)
	{
		report_changes(&previous.value, &next.value, hub, &emit_event);
		previous.release();
	}
	next.release();
}

// Copy an event into a packet: its strings must outlive the state they came from.
fn void emit_event(void* context, Event event)
{
	AudioHub* hub = (AudioHub*)context;
	Snapshot{Event}* packet = hub.emit_begin();
	packet.value = { event.kind, event.flow, event.id.copy(packet.allocator()) };
	hub.emit(packet);
}

<* Publish an empty state: what a client sees while no audio server is reachable. *>
fn void publish_empty(AudioHub* hub)
{
	Snapshot{State}* snapshot = hub.begin();
	publish_snapshot(hub, snapshot);
}
