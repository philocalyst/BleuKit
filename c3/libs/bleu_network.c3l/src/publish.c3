module bleu::network;
import bleu::equal, bleu::observe;

<*
 Publish an empty picture: the backend cannot read anything. Used by every
 backend when its platform cannot be read.
*>
fn void publish_empty(NetworkHub* hub)
{
	Snapshot{State}* snapshot = hub.begin();
	snapshot.value = { };
	hub.publish_if_changed(snapshot);
}

<*
 Publish `snapshot` if it differs from the last one, and emit the transients
 for what changed. Consumes the snapshot's reference.
*>
fn void publish_snapshot(NetworkHub* hub, Snapshot{State}* snapshot)
{
	if (try previous = hub.latest())
	{
		defer previous.release();
		if (!equal::deep(previous.value, snapshot.value)) emit_changes(hub, &previous.value, &snapshot.value);
	}
	hub.publish_if_changed(snapshot);
}

fn void emit_changes(NetworkHub* hub, State* before, State* after) @local
{
	Ssid none = { };
	if (!equal::deep(before.wifi.networks, after.wifi.networks)) emit(hub, NETWORKS_CHANGED, none);
	bool connection_moved = before.wifi.phase != after.wifi.phase || !same_ssid(
		before.wifi.connected_ssid.bytes,
		after.wifi.connected_ssid.bytes
	);
	if (connection_moved) emit(hub, CONNECTION_CHANGED, after.wifi.connected_ssid);
	if (!equal::deep(before.interfaces, after.interfaces)) emit(hub, INTERFACES_CHANGED, none);
}

fn void emit(NetworkHub* hub, EventKind kind, Ssid ssid) @local
{
	emit_event(hub, { .kind = kind, .ssid = ssid });
}

<*
 Deliver an event to every reader. Its SSID is copied into the event packet, so
 the caller's octets may be temporary.
*>
fn void emit_event(NetworkHub* hub, Event event)
{
	Snapshot{Event}* packet = hub.emit_begin();
	event.ssid = make_ssid(packet.allocator(), event.ssid.bytes);
	packet.value = event;
	hub.emit(packet);
}

<* The security the last published scan saw for this SSID; UNKNOWN when the network has not been seen. *>
fn Security security_on_air(NetworkHub* hub, char[] ssid)
{
	if (try snapshot = hub.latest())
	{
		defer snapshot.release();
		foreach (network : snapshot.value.wifi.networks)
		{
			if (same_ssid(network.ssid.bytes, ssid)) return network.security;
		}
	}
	return UNKNOWN;
}