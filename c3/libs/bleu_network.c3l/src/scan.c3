// What the last published scan says about a network: its security class, whether
// a new connection may be made to it, and how the access points of one network
// are merged into one entry. Pure: the callers pass the networks in.
module bleu::network;
import std::collections::list, bleu::error;

<*
 The security class of the network with this SSID in `networks`.

 @return? NOT_FOUND : "No network in the list has these octets"
*>
fn Security? security_in(AccessPoint[] networks, char[] ssid)
{
	foreach (entry : networks)
	{
		if (same_ssid(entry.ssid.bytes, ssid)) return entry.security;
	}
	return NOT_FOUND~;
}

<*
 The security class a new connection to this network needs, from `networks`.
 A network whose class is UNKNOWN is refused: nothing is joined or saved for it,
 because the profile would be written with the wrong key management.

 @return? NOT_FOUND : "The network is not in the list (not in the last scan)"
 @return? error::UNSUPPORTED : "The network is in the list, but its security class is not known"
*>
fn Security? joinable_in(AccessPoint[] networks, char[] ssid)
{
	Security security = security_in(networks, ssid)!;
	if (security == UNKNOWN) return error::raise(
		error::UNSUPPORTED,
		error::Domain.INTERNAL,
		0,
		"the security of this network is not known; it cannot be joined"
	)~;
	return security;
}

<*
 Whether a new connection may be made to the network with this SSID, judged by the last
 published scan (see `joinable_in`).

 @return? NOT_FOUND : "The network is not in the last scan"
 @return? error::UNSUPPORTED : "The network is in the last scan, but its security class is not known"
*>
fn Security? joinable_security(NetworkHub* hub, char[] ssid)
{
	if (try snapshot = hub.latest())
	{
		defer snapshot.release();
		return joinable_in(snapshot.value.wifi.networks, ssid);
	}
	return NOT_FOUND~;
}

<*
 Add a scanned access point to `networks`, which holds one entry per SSID. An access
 point of a network already listed is merged into its entry: the entry keeps the
 stronger access point's signal, quality and BSSID, and the network is in use when any
 of its access points is. A withheld name (empty SSID) cannot be matched to another
 access point, so it is always added as its own entry.
*>
fn void merge_access_point(List{AccessPoint}* networks, AccessPoint entry)
{
	if (entry.ssid.bytes.len > 0)
	{
		foreach (&known : networks.array_view())
		{
			if (!same_ssid(known.ssid.bytes, entry.ssid.bytes)) continue;
			bool in_use = known.in_use || entry.in_use;
			if (stronger(&entry, known)) *known = entry;
			known.in_use = in_use;
			return;
		}
	}
	networks.push(entry);
}

// Whether access point `a` has a better quality than `b`; an access point with a known quality beats one without.
fn bool stronger(AccessPoint* a, AccessPoint* b) @local
{
	if (!a.quality.has_value) return false;
	if (!b.quality.has_value) return true;
	return (float)a.quality.value > (float)b.quality.value;
}
