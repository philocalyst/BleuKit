// The macOS backend: CoreWLAN, the public Wi-Fi framework.
//
// Compiled for macOS; type-checked for every other target. It has not been run
// (no macOS machine is available to the project). The sources of every selector
// and constant are in docs/research/network.md section 2.2.1 and
// src/corewlan_convert.c3.
//
// What macOS hides: SSIDs and BSSIDs are withheld from an app without Location
// authorization (CWInterface.h and CWNetwork.h: "not available unless Location
// Services is enabled and the user has authorized the calling app"). They read
// as empty here, and `State.location` says why.
//
// Threading: CoreWLAN calls run on the worker. The event callbacks (on
// CoreWLAN's threads, in corewlan_events.c3) only post a refresh to the mailbox.
module bleu::network::corewlan @feat(DARWIN) @link("CoreWLAN.framework");
import std::io, std::time, std::collections::maybe, bleu::availability, bleu::error, bleu::network, bleu::network::corewlan_convert, bleu::network::corewlan_location, bleu::objc, bleu::objc::foundation, bleu::rt::poller, bleu::rt::worker;

<* Commands taken from the mailbox per pass of the loop. *>
const usz COMMAND_BATCH = 16;

<* The backend's state. The worker thread owns it. *>
struct Backend
{
	Allocator allocator;
	Duration poll;
	String interface_name;
	objc::Obj client;     // CWWiFiClient.sharedWiFiClient, retained
	objc::Obj interface;  // the first Wi-Fi CWInterface, retained
}

const Driver DRIVER = {
	.info = { "corewlan", "CoreWLAN (CWWiFiClient, public Wi-Fi framework)", 30 },
	.id = COREWLAN,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

fn bool probe(Options* options) => true;

<*
 Find the Wi-Fi interface. A Mac without one reports UNAVAILABLE here.

 @return? error::UNAVAILABLE : "This Mac has no Wi-Fi interface"
*>
fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	objc::Obj client = objc::borrow(objc::class_named("CWWiFiClient").send(objc::ObjId, "sharedWiFiClient"));
	objc::ObjId found = client.send_id("interface");
	if (found == null)
	{
		client.close();
		return error::raise(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "this Mac has no Wi-Fi interface")~;
	}
	objc::Obj iface = objc::borrow(found);
	String name = foundation::to_string(iface.send_id("interfaceName"), allocator) ?? "";
	Backend* self = alloc::new(allocator, Backend, {
		.allocator = allocator,
		.poll = options.poll,
		.interface_name = name,
		.client = client,
		.interface = iface,
	});
	fill_capabilities(capabilities);
	return self;
}

// A view of an object that the caller does not own: sends on it take no reference.
fn objc::Obj view(objc::ObjId object) @inline => { .ptr = object };

// CoreWLAN can do: radio power, scan, open and password joins, disconnect. The rest is listed with its reason.
fn void fill_capabilities(Capabilities* capabilities) @local
{
	capabilities.init(availability::no(availability::Reason.UNSUPPORTED_OS, "not offered by CoreWLAN"));
	capabilities.set(Cap.WIFI_RADIO, availability::YES);
	capabilities.set(Cap.WIFI_SCAN, availability::YES);
	capabilities.set(Cap.WIFI_CONNECT_OPEN, availability::YES);
	capabilities.set(Cap.WIFI_CONNECT_PSK, availability::YES);
	capabilities.set(Cap.WIFI_DISCONNECT, availability::YES);
	capabilities.set(Cap.WIFI_SIGNAL_DBM, availability::YES);
	capabilities.set(Cap.SSID_VISIBILITY, availability::no(availability::Reason.PERMISSION_NEEDED, "SSIDs are withheld unless this app is authorized for Location Services (State.location)"));
	capabilities.set(Cap.WIFI_BSSID, availability::no(availability::Reason.PERMISSION_NEEDED, "BSSIDs are withheld unless this app is authorized for Location Services"));
	capabilities.set(Cap.WIFI_FORGET, availability::no(availability::Reason.UNSUPPORTED_OS, "CoreWLAN has no saved-profile API; its keychain calls are deprecated"));
	capabilities.set(Cap.WIFI_AUTOCONNECT, availability::no(availability::Reason.UNSUPPORTED_OS, "CoreWLAN has no saved-profile API"));
	capabilities.set(Cap.WIFI_SECRET_PROMPT, availability::no(availability::Reason.UNSUPPORTED_OS, "the password is given up front (associateToNetwork:password:error:)"));
	capabilities.set(Cap.INTERFACE_STATE, availability::no(availability::Reason.UNSUPPORTED_OS, "CoreWLAN reports no link state; the power switch is State.wifi.radio_enabled"));
	capabilities.set(Cap.INTERFACE_SPEED, availability::no(availability::Reason.UNSUPPORTED_OS, "CoreWLAN reports the transmit rate of the association, not the interface speed"));
	capabilities.set(Cap.INTERFACE_COUNTERS, availability::no(availability::Reason.UNSUPPORTED_BACKEND, "traffic counters (IOKit) are not bound in v1"));
	capabilities.set(Cap.CONNECTIVITY, availability::no(availability::Reason.UNSUPPORTED_BACKEND, "SystemConfiguration reachability is not bound in v1"));
}

fn void destroy(Allocator allocator, void* state)
{
	Backend* b = (Backend*)state;
	b.interface.close();
	b.client.close();
	if (b.interface_name.len > 0) alloc::free(allocator, b.interface_name.ptr);
	alloc::free(allocator, b);
}

<* The loop: wait for the poll interval or a mailbox signal; run the commands; read and publish. *>
fn void run(void* state, NetworkHub* hub, Host{Command}* host)
{
	Backend* b = (Backend*)state;
	objc::Obj delegate = install_delegate(host.mailbox());
	defer uninstall_delegate(delegate);
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 2)) return;
	defer poller.free();
	Command[COMMAND_BATCH] commands;
	refresh(b, hub);
	while (!host.stopping())
	{
		// The poll tick keeps the picture fresh where an event is missing; events make it prompt.
		if (catch poller.wait(b.poll))
		{
			// TIMEOUT is the normal tick.
		}
		objc::@autorelease_pool()
		{
			usz count = host.mailbox().take_all(commands[..]);
			for (usz i = 0; i < count; i++)
			{
				execute(b, &commands[i]);
			}
			refresh(b, hub);
		};
	}
}

fn void refresh(Backend* b, NetworkHub* hub)
{
	Snapshot{State}* snapshot = hub.begin();
	snapshot.value = read_state(b, snapshot.allocator());
	publish_snapshot(hub, snapshot);
}

<* Route one command. Every CoreWLAN request completes synchronously on the worker. *>
fn void execute(Backend* b, Command* c)
{
	switch (c.kind)
	{
		case REFRESH: return;
		case SCAN: finish_settle(c.settle, scan(b));
		case CONNECT: finish_connect(c.connect, b, c);
		case DISCONNECT: finish_settle(c.settle, disconnect(b));
		case SET_RADIO: finish_settle(c.settle, set_radio(b, c.flag));
		case FORGET:
		case SET_AUTOCONNECT:
			// The capability check refuses these before they are posted; reaching here is a bug.
			c.settle.fail(error::UNSUPPORTED);
			c.settle.release();
	}
}

fn void finish_settle(SettleOp* op, Settled? outcome)
{
	if (catch err = outcome)
	{
		op.fail(err);
	}
	else
	{
		op.succeed(outcome);
	}
	op.release();
}

fn void finish_connect(ConnectOp* op, Backend* b, Command* c)
{
	Connected? joined = connect(b, c, op.allocator());
	if (catch err = joined)
	{
		op.fail(err);
	}
	else
	{
		op.succeed(joined);
	}
	op.release();
}

<* The error an NSError from CoreWLAN stands for: a Bleu excuse, with its code in the detail. *>
fn fault ns_error(objc::ObjId failure, String what) @local
{
	long code = view(failure).send_long("code");
	return error::raise(corewlan_convert::fault_from_cw_error(code), error::Domain.NS_ERROR, (int)code, "%s", what);
}

fn Settled? scan(Backend* b)
{
	objc::ObjId err = null;
	objc::ObjId results = b.interface.send_id("scanForNetworksWithName:includeHidden:error:", (objc::ObjId)null, false, &err);
	if (results == null) return ns_error(err, "the scan failed")~;
	return Settled.CHANGED;
}

<* Join a network from the last scan, found by its octets. Withheld names cannot be matched. *>
fn Connected? connect(Backend* b, Command* c, Allocator out)
{
	char[] ssid = c.ssid.bytes[0 : c.ssid.len];
	objc::ObjId network = find_scanned(b, ssid);
	if (network == null) return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "that network is not in the last scan (or its name is withheld)")~;
	objc::ObjId password = null;
	if (c.secret.len > 0) password = foundation::from_string((String)c.secret.bytes[0 : c.secret.len]).ptr;
	objc::ObjId err = null;
	bool joined = b.interface.send_bool("associateToNetwork:password:error:", network, password, &err);
	if (!joined) return ns_error(err, "the network refused the join")~;
	return { .ssid = network::make_ssid(out, ssid), .interface_name = b.interface_name.copy(out) };
}

// The scanned network whose SSID octets equal `ssid`, or nil.
fn objc::ObjId find_scanned(Backend* b, char[] ssid) @local
{
	objc::ObjId list = scan_list(b);
	usz count = foundation::array_count(list);
	for (usz i = 0; i < count; i++)
	{
		objc::ObjId network = foundation::array_at(list, i);
		char[] octets = data_or_empty(view(network).send_id("ssidData"), tmem);
		if (octets.len > 0 && network::same_ssid(octets, ssid)) return network;
	}
	return null;
}

// The last scan's networks as an NSArray (possibly empty; never nil).
fn objc::ObjId scan_list(Backend* b) @local
{
	objc::ObjId set = b.interface.send_id("cachedScanResults");
	if (set == null) return objc::class_named("NSArray").send(objc::ObjId, "array");
	return foundation::set_members(set);
}

fn Settled? disconnect(Backend* b)
{
	if (b.interface.send_id("ssid") == null && b.interface.send_id("bssid") == null) return Settled.ALREADY;
	b.interface.send_void("disassociate");
	return Settled.CHANGED;
}

fn Settled? set_radio(Backend* b, bool on)
{
	if (b.interface.send_bool("powerOn") == on) return Settled.ALREADY;
	objc::ObjId err = null;
	if (!b.interface.send_bool("setPower:error:", on, &err)) return ns_error(err, "the radio did not change")~;
	return Settled.CHANGED;
}

<* The state as CoreWLAN shows it right now. Withheld names are empty; `location` says why. *>
fn State read_state(Backend* b, Allocator out)
{
	Wifi wifi = { .present = true, .interface_name = b.interface_name.copy(out) };
	wifi.radio_enabled = b.interface.send_bool("powerOn");
	objc::ObjId ssid = b.interface.send_id("ssid");
	objc::ObjId bssid = b.interface.send_id("bssid");
	char[] octets = data_or_empty(b.interface.send_id("ssidData"), out);
	if (ssid != null && octets.len > 0)
	{
		wifi.connected_ssid = network::make_ssid(out, octets);
		wifi.ssid_visible = true;
	}
	bool associated = ssid != null || bssid != null;
	wifi.phase = associated ? CONNECTED : IDLE;
	wifi.networks = scanned_networks(b, out, bssid);
	foreach (&network : wifi.networks)
	{
		if (network.in_use) wifi.signal = network.signal;
	}
	Interface[] interfaces = alloc::new_array(out, Interface, 1);
	interfaces[0] = { .name = b.interface_name.copy(out), .kind = WIFI, .link = UNKNOWN };
	return {
		.connectivity = UNKNOWN,
		.location = corewlan_location::authorization(),
		.primary_interface = associated ? b.interface_name.copy(out) : "",
		.wifi = wifi,
		.interfaces = interfaces,
	};
}

<* One entry per scanned access point. CoreWLAN has no saved-profile information, so `known` stays false. *>
fn AccessPoint[] scanned_networks(Backend* b, Allocator out, objc::ObjId current_bssid) @local
{
	objc::ObjId list = scan_list(b);
	usz count = foundation::array_count(list);
	AccessPoint[] found = alloc::new_array(out, AccessPoint, count);
	for (usz i = 0; i < count; i++)
	{
		objc::ObjId network = foundation::array_at(list, i);
		objc::Obj object = view(network);
		long rssi = object.send_long("rssiValue");
		objc::ObjId channel = object.send_id("wlanChannel");
		long number = channel == null ? 0 : view(channel).send_long("channelNumber");
		long band = channel == null ? 0 : view(channel).send_long("channelBand");
		String bssid = bssid_text(object.send_id("bssid"), out);
		AccessPoint entry = {
			.ssid = network::make_ssid(out, data_or_empty(object.send_id("ssidData"), out)),
			.bssid = bssid,
			.band = corewlan_convert::band_from_cw(band),
			.security = security_of(object),
			.signal = maybe::value((Dbm)rssi),
			.quality = maybe::value(((Dbm)rssi).quality()),
			.in_use = current_bssid != null && bssid_text(current_bssid, tmem) == bssid && bssid.len > 0,
		};
		if (try mhz = corewlan_convert::frequency_from_channel(band, number)) entry.frequency = maybe::value(mhz);
		found[i] = entry;
	}
	return found;
}

// The octets of an NSData, or an empty slice when it is nil (withheld).
fn char[] data_or_empty(objc::ObjId data, Allocator out) @local
{
	if (data == null) return {};
	if (try octets = foundation::data_bytes(data, out)) return octets;
	return {};
}

// The text of an NSString, or "" when it is nil (withheld).
fn String bssid_text(objc::ObjId text, Allocator out) @local
{
	if (text == null) return "";
	if (try s = foundation::to_string(text, out)) return s;
	return "";
}

// The strongest security class the network supports, probed in PROBE_ORDER.
fn Security security_of(objc::Obj network) @local
{
	foreach (candidate : corewlan_convert::probe_order())
	{
		if (network.send_bool("supportsSecurity:", candidate)) return corewlan_convert::security_from_cw(candidate);
	}
	return Security.UNKNOWN;
}
