<*
 Publishing a reading from a backend. Every backend ends its refresh here, on the
 worker thread, so that the same rules hold on every platform:
 - a reading that differs from the last one is published, and the transients between
 them (`changes`) are emitted first;
 - a failed read never publishes an empty state: the last good reading is republished
 with its `reading` marked stale, and before any good reading nothing is published.
*>
module bleu::battery;
import std::collections::list, bleu::equal, bleu::observe, bleu::service;

<*
 Publish the reading built in `snapshot` when it differs from the last one, emitting
 the transients between them. Consumes the snapshot.
*>
fn void publish_reading(BatteryHub* hub, Snapshot{State}* snapshot)
{
	if (try previous = hub.latest())
	{
		defer previous.release();
		if (equal::deep(previous.value, snapshot.value))
		{
			snapshot.release();
			return;
		}
		emit_changes(hub, &previous.value, &snapshot.value);
	}
	hub.publish(snapshot);
}

<*
 Record that the read which filled `snapshot` failed. The newest good state is kept and
 republished with its reading marked stale; there is no good state yet, nothing is
 published. Consumes the snapshot.
*>
fn void publish_failure(BatteryHub* hub, Snapshot{State}* snapshot)
{
	snapshot.release();
	if (try last = hub.latest())
	{
		defer last.release();
		Snapshot{State}* stale = hub.begin();
		stale.value = copy_state(&last.value, stale.allocator());
		stale.value.reading = stale_reading();
		hub.publish_if_changed(stale);
	}
}

// Emit the transients between `before` and `after`. Each event's source id is copied into its packet.
fn void emit_changes(BatteryHub* hub, State* before, State* after)
{
	@pool()
	{
		List{Event} events;
		events.init(tmem);
		changes(before, after, &events);
		foreach (&event : events)
		{
			Snapshot{Event}* packet = hub.emit_begin();
			packet.value = { .kind = event.kind, .source_id = copy_text(event.source_id, packet.allocator()) };
			hub.emit(packet);
		}
	};
}