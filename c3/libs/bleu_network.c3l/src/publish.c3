// Publishing a picture, and copying the parts of an earlier one.
//
// A read that fails for one part keeps that part's value from the previous
// picture (`Stale`), so the copies here must be deep: the previous snapshot is
// released as soon as the new one is built.
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

<*
 A copy of `text` in `out`; the empty string is never allocated.

 @param out : "Allocator for the copy"
*>
fn String copy_text(Allocator out, String text)
{
	return text.len == 0 ? "" : text.copy(out);
}

<*
 A copy of `source` in `out`. Its bytes are copied and its label derived again,
 which gives the same label the original had.
*>
fn Ssid clone_ssid(Allocator out, Ssid source)
{
	return make_ssid(out, source.bytes);
}

<* A deep copy of every access point, in `out`. *>
fn AccessPoint[] clone_access_points(Allocator out, AccessPoint[] source)
{
	if (source.len == 0) return { };
	AccessPoint[] found = alloc::new_array(out, AccessPoint, source.len);
	foreach (i, entry : source)
	{
		found[i]       = entry;
		found[i].ssid  = clone_ssid(out, entry.ssid);
		found[i].bssid = copy_text(out, entry.bssid);
	}
	return found;
}

<* A deep copy of every interface, in `out`. *>
fn Interface[] clone_interfaces(Allocator out, Interface[] source)
{
	if (source.len == 0) return { };
	Interface[] found = alloc::new_array(out, Interface, source.len);
	foreach (i, iface : source)
	{
		found[i]      = iface;
		found[i].name = copy_text(out, iface.name);
	}
	return found;
}

<* A deep copy of the Wi-Fi block, in `out`. *>
fn Wifi clone_wifi(Allocator out, Wifi* source)
{
	Wifi copy = *source;
	copy.interface_name = copy_text(out, source.interface_name);
	copy.connected_ssid = clone_ssid(out, source.connected_ssid);
	copy.networks       = clone_access_points(out, source.networks);
	return copy;
}

<*
 The picture a read that could not run at all falls back to: every part of
 `previous`, copied into `out` and flagged stale.
*>
fn State stale_picture(Allocator out, State* previous)
{
	return {
		.connectivity = previous.connectivity,
		.location = previous.location,
		.primary_interface = copy_text(out, previous.primary_interface),
		.wifi = clone_wifi(out, &previous.wifi),
		.interfaces = clone_interfaces(out, previous.interfaces),
		.stale = { .connectivity = true, .interfaces = true, .wifi = true },
	};
}
