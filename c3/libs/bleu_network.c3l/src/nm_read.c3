// Reading the whole network picture from NetworkManager and sysfs into one
// immutable State. Everything the snapshot refers to is allocated in the
// snapshot's arena; temporaries live in the pool of `read_state`.
module bleu::network::networkmanager @feat(LINUX);
import std::collections::list, std::collections::maybe, bleu::error, bleu::network, bleu::network::nm_convert, bleu::network::sysfs, bleu::dbus::proxy, bleu::dbus::value, bleu::dbus::connection;

<* What one read found that the pending operations and the command handlers need. *>
struct Reading
{
	bool wifi_found;
	String wifi_path;    // object path of the first Wi-Fi device (lives in the snapshot's arena)
	String wifi_name;    // its interface name (lives in the snapshot's arena)
	uint device_state;   // Wi-Fi device State (nm_convert.DEVICE_STATE_*)
	uint device_reason;  // Wi-Fi device StateReason
	long last_scan;      // Wireless.LastScan: changes when a scan finishes
	bool radio_enabled;  // WirelessEnabled
}

<* The Wi-Fi part of one read: the visible networks and the one in use. *>
struct WifiScan
{
	AccessPoint[] networks;
	Ssid connected;
}

<* A device NetworkManager manages, as the device list showed it. *>
struct Device
{
	String path;
	String name;
}

<*
 Read everything once. The state is complete even when some parts are absent
 (no Wi-Fi device, NetworkManager without a primary connection).

 @param out : "Allocator for the snapshot's contents"
 @return? error::DISCONNECTED : "The bus closed during the read"
*>
fn State? read_state(Backend* b, Allocator out, Reading* r)
{
	@pool()
	{
		Value root = b.nm.get_all_properties(tmem)!;
		r.radio_enabled = bool_of(root, "WirelessEnabled");
		String primary = path_of(tmem, root, "PrimaryConnection");
		Value paths = method_value(&b.nm, "GetDevices", tmem)!;
		List{Device} devices;
		devices.init(tmem);
		List{Interface} interfaces;
		interfaces.init(tmem);
		WifiScan wifi_scan;
		for (usz i = 0; i < paths.count(); i++)
		{
			String path = paths.at(i)!.as_object_path()!;
			Proxy device = object_proxy(&b.bus, path, NM_DEVICE_IFACE)!;
			Value props = device.get_all_properties(tmem)!;
			InterfaceKind kind;
			if (try k = nm_convert::kind_from_device_type(uint_of(props, "DeviceType"))) { kind = k; } else { continue; }
			String name = text_of(tmem, props, "Interface");
			if (name.len == 0) continue;
			devices.push({ .path = path, .name = name });
			interfaces.push(sysfs::read_interface(out, b.root, name, kind));
			if (kind == WIFI && !r.wifi_found)
			{
				r.wifi_found = true;
				// The read's pool ends when this function returns: keep the names in the snapshot's arena.
				r.wifi_path = path.copy(out);
				r.wifi_name = name.copy(out);
				r.device_state = uint_of(props, "State");
				r.device_reason = reason_of(props, "StateReason");
				wifi_scan = read_networks(b, path, out, r)!;
			}
		}
		String primary_name = primary_interface(b, primary, devices.array_view(), out)!;
		return {
			.connectivity = nm_convert::connectivity_from(uint_of(root, "Connectivity")),
			.location = NOT_APPLICABLE,
			.primary_interface = primary_name,
			.wifi = wifi_state(b, r, bool_of(root, "WirelessHardwareEnabled"), wifi_scan, out),
			.interfaces = clone_interfaces(out, interfaces.array_view()),
		};
	};
}

<*
 The visible Wi-Fi networks, one per SSID (its strongest access point), with
 saved-profile flags. Hidden networks (empty SSID) are not listed.
*>
fn WifiScan? read_networks(Backend* b, String device, Allocator out, Reading* r)
{
	Proxy wireless = object_proxy(&b.bus, device, NM_WIRELESS_IFACE)!;
	Value wprops = wireless.get_all_properties(tmem)!;
	r.last_scan = long_of(wprops, "LastScan");
	String active = path_of(tmem, wprops, "ActiveAccessPoint");
	Profile[] profiles = load_profiles(&b.bus, tmem)!;
	Value aps = method_value(&wireless, "GetAllAccessPoints", tmem)!;
	List{AccessPoint} networks;
	networks.init(tmem);
	List{uint} strengths;
	strengths.init(tmem);
	WifiScan scan;
	for (usz i = 0; i < aps.count(); i++)
	{
		String ap_path = aps.at(i)!.as_object_path()!;
		Proxy ap = object_proxy(&b.bus, ap_path, NM_AP_IFACE)!;
		Value props = ap.get_all_properties(tmem)!;
		char[] bytes = bytes_of(tmem, props, "Ssid");
		if (bytes.len == 0) continue;
		uint strength = byte_of(props, "Strength");
		uint mhz = uint_of(props, "Frequency");
		bool in_use = active.len > 0 && ap_path == active;
		AccessPoint entry = {
			.ssid = network::make_ssid(out, bytes),
			.bssid = text_of(out, props, "HwAddress"),
			.quality = maybe::value(nm_convert::quality_from_strength(strength)),
			.band = nm_convert::band_from_mhz(mhz),
			.security = nm_convert::security_from_flags(uint_of(props, "Flags"), uint_of(props, "WpaFlags"), uint_of(props, "RsnFlags")),
			.in_use = in_use,
		};
		if (mhz != 0) entry.frequency = maybe::value((MegaHertz)mhz);
		if (try index = find_network(networks.array_view(), entry.ssid.bytes))
		{
			// Keep the strongest access point's identity; a network is in use when any of its access points is.
			bool used = networks.get(index).in_use || in_use;
			if (strength > strengths.get(index))
			{
				networks.set_at(index, entry);
				strengths.set_at(index, strength);
			}
			networks.get_ref(index).in_use = used;
		}
		else
		{
			networks.push(entry);
			strengths.push(strength);
		}
	}
	foreach (&entry : networks.array_view())
	{
		if (entry.in_use) scan.connected = entry.ssid;
		if (try profile = find_profile(profiles, entry.ssid.bytes))
		{
			entry.known = true;
			entry.autoconnect = profile.autoconnect;
		}
	}
	scan.networks = clone_networks(out, networks.array_view());
	return scan;
}

// Index of the entry with this SSID.
fn sz? find_network(AccessPoint[] networks, char[] ssid) @local
{
	foreach (i, network : networks)
	{
		if (network::same_ssid(network.ssid.bytes, ssid)) return i;
	}
	return NOT_FOUND~;
}

<*
 The name of the interface the primary connection uses, "" when there is none.
 `devices` is what the device list showed in this read.
*>
fn String? primary_interface(Backend* b, String primary, Device[] devices, Allocator out)
{
	if (primary.len == 0 || primary == NO_OBJECT) return "";
	Proxy active = object_proxy(&b.bus, primary, NM_ACTIVE_IFACE)!;
	Value used = active.get_property("Devices", tmem)!;
	if (used.count() == 0) return "";
	String first = used.at(0)!.as_object_path()!;
	foreach (device : devices)
	{
		if (device.path == first) return device.name.copy(out);
	}
	return "";
}

<*
 The Wi-Fi block of the state. Phase and failure come from the device's own
 state machine; the one thing NetworkManager cannot say on its own is whether a
 passphrase that was supplied got rejected, which the backend remembers.
*>
fn Wifi wifi_state(Backend* b, Reading* r, bool hardware_enabled, WifiScan scan, Allocator out) @local
{
	Wifi wifi = {
		.present = r.wifi_found,
		.radio_enabled = r.radio_enabled,
		.hardware_blocked = r.wifi_found && !hardware_enabled,
		.scanning = has_pending(b, PendingKind.SCAN),
		.ssid_visible = true,
		.connected_ssid = scan.connected,
		.networks = scan.networks,
	};
	if (!r.wifi_found) return wifi;
	wifi.interface_name = r.wifi_name.copy(out);
	wifi.phase = nm_convert::phase_from_device_state(r.device_state);
	if (r.device_state == nm_convert::DEVICE_STATE_FAILED)
	{
		wifi.phase = FAILED;
		wifi.failure = nm_convert::failure_from_reason(r.device_reason);
		if (wifi.failure == NO_SECRETS && b.last_supplied) wifi.failure = AUTH_REJECTED;
	}
	else if (r.device_state == nm_convert::DEVICE_STATE_NEED_AUTH && b.last_supplied)
	{
		wifi.phase = FAILED;
		wifi.failure = AUTH_REJECTED;
	}
	else if (has_pending(b, PendingKind.CONNECT) && (r.device_state == nm_convert::DEVICE_STATE_DISCONNECTED || r.device_state == nm_convert::DEVICE_STATE_UNAVAILABLE))
	{
		wifi.phase = CONNECTING;
	}
	return wifi;
}

fn Interface[] clone_interfaces(Allocator out, Interface[] source) @local
{
	if (source.len == 0) return {};
	return alloc::clone_slice(out, source);
}

fn AccessPoint[] clone_networks(Allocator out, AccessPoint[] source) @local
{
	if (source.len == 0) return {};
	return alloc::clone_slice(out, source);
}
