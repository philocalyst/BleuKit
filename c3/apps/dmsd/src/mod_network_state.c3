<*
 DMS's `NetworkState` (`core/internal/server/network/types.go:114-160`) and the shapes
 it holds (`WiFiNetwork` 29-45, `WiFiDevice` 47-58, `EthernetDevice` 60-68), written
 from one snapshot of `bleu::network`.

 Field names and their order are the Go `json` tags, one per field in declaration
 order (`tests/golden/network_tags.json`). A field Bleu does not report holds the empty
 value of its type (`""`, `0`, `false`, `[]`); docs/DMSD.md lists them. The values Bleu
 does report are mapped by the functions below. DMS's own derivations of
 `networkStatus` and of the device `state` words were not read, so those are Bleu's.
*>
module dmsd::network_state;
import bleu::network, bleu::json, bleu::error, dmsd::wire;

// DMS's `NetworkStatus` values (types.go:13-17). Bleu reports the interface of the default route.
const String STATUS_DISCONNECTED = "disconnected";
const String STATUS_ETHERNET     = "ethernet";
const String STATUS_WIFI         = "wifi";
// DMS's `ConnectionPhase` default (types.go:23). Bleu cannot set a preference; the OS routes.
const String PREFERENCE_AUTO     = "auto";

// A quality of 0..1 as DMS's 0..100 percentage, rounded. Zero when there is no figure.
fn ulong percent_of(float quality)
{
	float percent = quality * 100.0f + 0.5f;
	if (percent >= 100.0f) return 100;
	if (percent <= 0.0f) return 0;
	return (ulong)percent;
}

// The access point's quality as a percentage (`WiFiNetwork.signal`), or 0 when unknown.
fn ulong ap_percent(network::AccessPoint* ap)
{
	return percent_of(ap.quality.has_value ? (float)ap.quality.value : 0.0f);
}

// The access point's frequency in MHz (`WiFiNetwork.frequency`), or 0 when unknown.
fn ulong ap_frequency(network::AccessPoint* ap)
{
	return ap.frequency.has_value ? (ulong)ap.frequency.value : (ulong)0;
}

<*
 One `WiFiNetwork` (types.go:29-45). Bleu merges access points by SSID, so each entry
 is one network. `mode`, `rate` and `channel` are not reported, and neither is
 `hidden` or `outOfRange`.
 @param ap : "An access point of the last scan"
*>
fn void? write_access_point(json::JsonWriter* w, network::AccessPoint* ap)
{
	w.begin_object()!;
	wire::key_string(w, "ssid", ap.ssid.label)!;
	wire::key_string(w, "bssid", ap.bssid)!;
	wire::key_uint(w, "signal", ap_percent(ap))!;
	wire::key_bool(w, "secured", ap.security != network::Security.OPEN)!;
	wire::key_bool(w, "enterprise", ap.security == network::Security.ENTERPRISE)!;
	wire::key_bool(w, "connected", ap.in_use)!;
	wire::key_bool(w, "saved", ap.known)!;
	wire::key_bool(w, "autoconnect", ap.known && ap.autoconnect)!;
	wire::key_bool(w, "hidden", false)!;
	wire::key_bool(w, "outOfRange", false)!;
	wire::key_uint(w, "frequency", ap_frequency(ap))!;
	wire::key_string(w, "mode", "")!;
	wire::key_uint(w, "rate", 0)!;
	wire::key_uint(w, "channel", 0)!;
	w.end_object()!;
}

<*
 A `[]WiFiNetwork`: every access point of the last scan, or only the saved ones.
 An empty list is `[]`, as DMS writes it.
*>
fn void? write_access_points(json::JsonWriter* w, network::AccessPoint[] aps, bool saved_only)
{
	w.begin_array()!;
	foreach (&ap : aps)
	{
		if (saved_only && !ap.known) continue;
		write_access_point(w, ap)!;
	}
	w.end_array()!;
}

// `"key": []`, an empty list the Bleu state has no source for.
fn void? empty_array(json::JsonWriter* w, String key)
{
	w.key(key)!;
	w.begin_array()!;
	w.end_array()!;
}

// The first Ethernet interface, or null when there is none.
fn network::Interface* first_ethernet(network::State* state)
{
	foreach (&iface : state.interfaces)
	{
		if (iface.kind == network::InterfaceKind.ETHERNET) return iface;
	}
	return null;
}

// Whether the interface's link is up: DMS's `connected` for a wired device.
fn bool link_up(network::Interface* iface)
{
	return iface.link == network::LinkState.UP;
}

// Bleu's link state as DMS's device state word (`EthernetDevice.state`).
fn String ethernet_state(network::Interface* iface)
{
	switch (iface.link)
	{
		case network::LinkState.UP: return "connected";
		case network::LinkState.DOWN: return "disconnected";
		case network::LinkState.DORMANT: return "disconnected";
		case network::LinkState.UNKNOWN: return "unknown";
	}
}

<*
 One `EthernetDevice` (types.go:60-68). Bleu reports no address, driver or hardware
 address, so those are left out (`ip`, `driver`: omitempty) or empty (`hwAddress`).
*>
fn void? write_ethernet_device(json::JsonWriter* w, network::Interface* iface)
{
	w.begin_object()!;
	wire::key_string(w, "name", iface.name)!;
	wire::key_string(w, "hwAddress", "")!;
	wire::key_string(w, "state", ethernet_state(iface))!;
	wire::key_bool(w, "connected", link_up(iface))!;
	if (iface.speed.has_value && (ulong)iface.speed.value > 0) wire::key_uint(w, "speed", (ulong)iface.speed.value)!;
	w.end_object()!;
}

// The Ethernet block of `NetworkState`: `ethernetIP` through `ethernetDevices`.
fn void? write_ethernet(json::JsonWriter* w, network::State* state)
{
	network::Interface* first = first_ethernet(state);
	wire::key_string(w, "ethernetIP", "")!;
	wire::key_string(w, "ethernetDevice", first != null ? first.name : "")!;
	wire::key_bool(w, "ethernetConnected", first != null && link_up(first))!;
	wire::key_string(w, "ethernetConnectionUuid", "")!;
	w.key("ethernetDevices")!;
	w.begin_array()!;
	foreach (&iface : state.interfaces)
	{
		if (iface.kind == network::InterfaceKind.ETHERNET) write_ethernet_device(w, iface)!;
	}
	w.end_array()!;
}

// The cellular block: Bleu has no cellular service, so every field is its empty value.
fn void? write_cellular(json::JsonWriter* w)
{
	wire::key_string(w, "cellularIP", "")!;
	wire::key_string(w, "cellularDevice", "")!;
	wire::key_bool(w, "cellularConnected", false)!;
	wire::key_bool(w, "cellularEnabled", false)!;
	wire::key_bool(w, "cellularHardwareEnabled", false)!;
	wire::key_string(w, "cellularConnectionUuid", "")!;
	empty_array(w, "cellularDevices")!;
	empty_array(w, "cellularConnections")!;
}

// The access point the Wi-Fi interface is on, or null.
fn network::AccessPoint* connected_ap(network::Wifi* wifi)
{
	foreach (&ap : wifi.networks)
	{
		if (ap.in_use) return ap;
	}
	return null;
}

// DMS's Wi-Fi device state word, from Bleu's connection phase and radio.
fn String wifi_state(network::Wifi* wifi)
{
	if (!wifi.present || !wifi.radio_enabled || wifi.hardware_blocked) return "unavailable";
	switch (wifi.phase)
	{
		case network::ConnectionPhase.CONNECTED: return "connected";
		case network::ConnectionPhase.CONNECTING: return "connecting";
		case network::ConnectionPhase.OBTAINING_ADDRESS: return "connecting";
		case network::ConnectionPhase.DISCONNECTING: return "disconnecting";
		case network::ConnectionPhase.IDLE: return "disconnected";
		case network::ConnectionPhase.AUTH_REQUIRED: return "disconnected";
		case network::ConnectionPhase.FAILED: return "disconnected";
		case network::ConnectionPhase.UNAVAILABLE: return "unavailable";
	}
}

<*
 One `WiFiDevice` (types.go:47-58): the Wi-Fi interface Bleu manages. `bssid` and `ip`
 are omitted (omitempty) because Bleu does not report them for the device.
*>
fn void? write_wifi_device(json::JsonWriter* w, network::State* state)
{
	network::Wifi* wifi      = &state.wifi;
	network::AccessPoint* on = connected_ap(wifi);
	bool connected           = wifi.phase == network::ConnectionPhase.CONNECTED;
	w.begin_object()!;
	wire::key_string(w, "name", wifi.interface_name)!;
	wire::key_string(w, "hwAddress", "")!;
	wire::key_string(w, "state", wifi_state(wifi))!;
	wire::key_bool(w, "connected", connected)!;
	wire::key_bool(w, "apCapable", false)!;
	if (connected && wifi.connected_ssid.label.len > 0) wire::key_string(w, "ssid", wifi.connected_ssid.label)!;
	if (on != null && ap_percent(on) > 0) wire::key_uint(w, "signal", ap_percent(on))!;
	w.key("networks")!;
	write_access_points(w, wifi.networks, false)!;
	w.end_object()!;
}

// The Wi-Fi block of `NetworkState`: `wifiIP` through `wifiDevices`.
fn void? write_wifi(json::JsonWriter* w, network::State* state)
{
	network::Wifi* wifi      = &state.wifi;
	network::AccessPoint* on = connected_ap(wifi);
	wire::key_string(w, "wifiIP", "")!;
	wire::key_string(w, "wifiDevice", wifi.interface_name)!;
	wire::key_bool(w, "wifiConnected", wifi.phase == network::ConnectionPhase.CONNECTED)!;
	wire::key_bool(w, "wifiEnabled", wifi.radio_enabled)!;
	wire::key_string(w, "wifiSSID", wifi.connected_ssid.label)!;
	wire::key_string(w, "wifiBSSID", "")!;
	wire::key_uint(w, "wifiSignal", on != null ? ap_percent(on) : (ulong)0)!;
	w.key("wifiNetworks")!;
	write_access_points(w, wifi.networks, false)!;
	w.key("savedWifiNetworks")!;
	write_access_points(w, wifi.networks, true)!;
	w.key("wifiDevices")!;
	w.begin_array()!;
	if (wifi.present) write_wifi_device(w, state)!;
	w.end_array()!;
}

// The hotspot block: Bleu has no hotspot, so every field is its empty value.
fn void? write_hotspot(json::JsonWriter* w)
{
	wire::key_bool(w, "hotspotSupported", false)!;
	wire::key_bool(w, "hotspotAvailable", false)!;
	wire::key_bool(w, "hotspotConfigured", false)!;
	wire::key_bool(w, "hotspotEnabled", false)!;
	wire::key_bool(w, "hotspotActivating", false)!;
	wire::key_bool(w, "hotspotSecured", false)!;
	wire::key_string(w, "hotspotSSID", "")!;
	wire::key_string(w, "hotspotDevice", "")!;
	wire::key_string(w, "hotspotBand", "")!;
	wire::key_string(w, "hotspotLastError", "")!;
}

// Wired profiles and VPNs: Bleu reports neither, so both lists are empty.
fn void? write_wired_and_vpn(json::JsonWriter* w)
{
	empty_array(w, "wiredConnections")!;
	empty_array(w, "vpnProfiles")!;
	empty_array(w, "vpnActive")!;
}

// Bleu's `FailureReason` as a sentence for the shell. DMS's `lastError` is NetworkManager's
// text, which Bleu does not have, so these sentences are Bleu's own.
fn String failure_sentence(network::FailureReason reason)
{
	switch (reason)
	{
		case network::FailureReason.NONE: return "";
		case network::FailureReason.UNKNOWN: return "The connection failed";
		case network::FailureReason.AUTH_REQUIRED: return "A password is required";
		case network::FailureReason.NO_SECRETS: return "The network did not get its password";
		case network::FailureReason.AUTH_REJECTED: return "The password was rejected";
		case network::FailureReason.SUPPLICANT_FAILED: return "The Wi-Fi supplicant failed";
		case network::FailureReason.SUPPLICANT_TIMEOUT: return "The Wi-Fi supplicant timed out";
		case network::FailureReason.SSID_NOT_FOUND: return "The network was not found";
		case network::FailureReason.CONFIG_FAILED: return "The connection could not be configured";
		case network::FailureReason.IP_CONFIG_FAILED: return "The network gave no IP configuration";
		case network::FailureReason.DHCP_FAILED: return "Getting an address failed";
		case network::FailureReason.CARRIER_LOST: return "The link lost its carrier";
		case network::FailureReason.DEVICE_UNAVAILABLE: return "The Wi-Fi device is unavailable";
		case network::FailureReason.DEPENDENCY_FAILED: return "A required service failed";
		case network::FailureReason.NETWORKING_OFF: return "Networking is off";
		case network::FailureReason.CANCELLED: return "The connection was cancelled";
		case network::FailureReason.TIMEOUT: return "The connection timed out";
	}
}

// `lastError`: the sentence for a failed or refused connection, else "".
fn String last_error(network::Wifi* wifi)
{
	bool refused = wifi.phase == network::ConnectionPhase.FAILED
		|| wifi.phase == network::ConnectionPhase.AUTH_REQUIRED;
	return refused ? failure_sentence(wifi.failure) : "";
}

// The connection block: `isConnecting` through `vpnErrorUuid`. `connectingDevice` is omitted (omitempty).
fn void? write_connecting(json::JsonWriter* w, network::State* state)
{
	network::ConnectionPhase phase = state.wifi.phase;
	bool connecting                = phase == network::ConnectionPhase.CONNECTING
		|| phase == network::ConnectionPhase.OBTAINING_ADDRESS;
	wire::key_bool(w, "isConnecting", connecting)!;
	wire::key_string(w, "connectingSSID", "")!;
	wire::key_string(w, "lastError", last_error(&state.wifi))!;
	wire::key_string(w, "vpnError", "")!;
	wire::key_string(w, "vpnErrorUuid", "")!;
}

// DMS's `networkStatus`: the default route's interface decides, Ethernet first.
fn String status_of(network::State* state)
{
	String primary = state.primary_interface;
	foreach (&iface : state.interfaces)
	{
		if (iface.kind == network::InterfaceKind.ETHERNET && iface.name == primary) return STATUS_ETHERNET;
	}
	if (state.wifi.phase == network::ConnectionPhase.CONNECTED) return STATUS_WIFI;
	return STATUS_DISCONNECTED;
}

<*
 `NetworkState` as one JSON line in `allocator` (types.go:114-160).

 @param backend : "The Bleu backend in use, for `backend` (for example \"networkmanager\")"
 @return "The line, in `allocator`"
*>
fn String? render_state(Allocator allocator, String backend, network::State* state)
{
	wire::Line line;
	line.begin(allocator);
	json::JsonWriter* w = &line.writer;
	w.begin_object()!;
	wire::key_string(w, "backend", backend)!;
	wire::key_string(w, "networkStatus", status_of(state))!;
	wire::key_string(w, "preference", PREFERENCE_AUTO)!;
	write_ethernet(w, state)!;
	write_cellular(w)!;
	write_wifi(w, state)!;
	write_hotspot(w)!;
	write_wired_and_vpn(w)!;
	write_connecting(w, state)!;
	w.end_object()!;
	return line.finish();
}

<*
 The `[]WiFiNetwork` reply of `network.wifi.networks` (handlers.go:172).
 @return "The line, in `allocator`"
*>
fn String? render_networks(Allocator allocator, network::State* state)
{
	wire::Line line;
	line.begin(allocator);
	write_access_points(&line.writer, state.wifi.networks, false)!;
	return line.finish();
}

<*
 The `NetworkInfoResponse` of `network.info` (types.go:269-272): the network with these
 SSID bytes, as the single entry of `bands` (Bleu merges the bands of one SSID).

 @return? NOT_FOUND : "No access point of the last scan has this name"
*>
fn String? render_info(Allocator allocator, String ssid, network::State* state)
{
	foreach (&ap : state.wifi.networks)
	{
		if ((String)ap.ssid.bytes != ssid) continue;
		wire::Line line;
		line.begin(allocator);
		line.writer.begin_object()!;
		wire::key_string(&line.writer, "ssid", ssid)!;
		line.writer.key("bands")!;
		line.writer.begin_array()!;
		write_access_point(&line.writer, ap)!;
		line.writer.end_array()!;
		line.writer.end_object()!;
		return line.finish();
	}
	return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "network not found: %s", ssid)~;
}