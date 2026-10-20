module bleu::apps;
import std::collections::list, bleu::observe, bleu::stream;

<*
 Publish a freshly built catalogue and announce what changed.

 The diff is taken against the latest published catalogue; the snapshot is
 published only if it differs (the hub's rule), and then one event per changed
 app is emitted. The events copy their ids into their own packets, so they
 never outlive the snapshot they describe.
*>
fn void publish_catalogue(AppsHub* hub, CatalogueSnapshot* snapshot)
{
	State empty = { };
	List{Event} changes;
	changes.tinit();
	if (try previous = hub.latest())
	{
		defer previous.release();
		diff_catalogue(&previous.value, &snapshot.value, &changes);
	}
	else
	{
		diff_catalogue(&empty, &snapshot.value, &changes);
	}
	// The events are built from the snapshot's strings, so keep it alive until they are sent.
	CatalogueSnapshot* keep = snapshot.retain();
	defer keep.release();
	hub.publish_if_changed(snapshot);
	foreach (change : changes)
	{
		Packet{Event}* packet = hub.emit_begin();
		packet.value = { .kind = change.kind, .app_id = change.app_id.copy(packet.allocator()) };
		hub.emit(packet);
	}
}