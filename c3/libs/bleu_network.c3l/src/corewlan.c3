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
import std::io, std::time, std::collections::list, std::collections::maybe, std::os::darwin::objc, bleu::observe, bleu::unit, bleu::availability, bleu::error, bleu::network, bleu::network::corewlan_convert, bleu::network::corewlan_location, bleu::objc, bleu::objc::foundation, bleu::rt::poller, bleu::rt::worker;

<* Commands taken from the mailbox per pass of the loop. *>
const usz COMMAND_BATCH = 16;

<*
 What to do when the names are withheld: the reason a connect fails with PERMISSION_DENIED (kept under the detail
 limit).
*>
const String LOCATION_REMEDY = "Wi-Fi names are withheld: grant Location Services to this app (System Settings > Privacy & Security > Location Services); the app must request it itself";

<* The backend's state. The worker thread owns it. *>
struct Backend
{
	Allocator allocator;
	Duration poll;
	String interface_name;
	objc::Obj client; // CWWiFiClient.sharedWiFiClient, retained
	objc::Obj iface; // the first Wi-Fi CWInterface, retained
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
	objc::Obj client = objc::borrow(objc::class_named("CWWiFiClient").send(ObjId, "sharedWiFiClient"));
	ObjId found      = client.send_id("interface");
	if (found == (ObjId)null)
	{
		client.close();
		return error::raise(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "this Mac has no Wi-Fi interface")~;
	}
	objc::Obj iface = objc::borrow(found);
	String name     = foundation::to_string(iface.send_id("interfaceName"), allocator) ?? "";
	Backend* self = alloc::new(
		allocator,
		Backend,
		{
			.allocator = allocator,
			.poll = options.poll,
			.interface_name = name,
			.client = client,
			.iface = iface,
		}
	);
	fill_capabilities(capabilities);
	return self;
}

// A view of an object that the caller does not own: sends on it take no reference.
fn objc::Obj view(ObjId object) @inline => { .ptr = object };

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
	capabilities.set(
		Cap.SSID_VISIBILITY,
		availability::no(
			availability::Reason.PERMISSION_NEEDED,
			"SSIDs are withheld unless this app is authorized for Location Services (State.location)"
		)
	);
	capabilities.set(
		Cap.WIFI_BSSID,
		availability::no(
			availability::Reason.PERMISSION_NEEDED,
			"BSSIDs are withheld unless this app is authorized for Location Services"
		)
	);
	capabilities.set(
		Cap.WIFI_FORGET,
		availability::no(
			availability::Reason.UNSUPPORTED_OS,
			"CoreWLAN has no saved-profile API; its keychain calls are deprecated"
		)
	);
	capabilities.set(
		Cap.WIFI_AUTOCONNECT,
		availability::no(availability::Reason.UNSUPPORTED_OS, "CoreWLAN has no saved-profile API")
	);
	capabilities.set(
		Cap.WIFI_SECRET_PROMPT,
		availability::no(
			availability::Reason.UNSUPPORTED_OS,
			"the password is given up front (associateToNetwork:password:error:)"
		)
	);
	capabilities.set(
		Cap.INTERFACE_STATE,
		availability::no(
			availability::Reason.UNSUPPORTED_OS,
			"CoreWLAN reports no link state; the power switch is State.wifi.radio_enabled"
		)
	);
	capabilities.set(
		Cap.INTERFACE_SPEED,
		availability::no(
			availability::Reason.UNSUPPORTED_OS,
			"CoreWLAN reports the transmit rate of the association, not the interface speed"
		)
	);
	capabilities.set(
		Cap.INTERFACE_COUNTERS,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "traffic counters (IOKit) are not bound in v1")
	);
	capabilities.set(
		Cap.CONNECTIVITY,
		availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"SystemConfiguration reachability is not bound in v1"
		)
	);
}

fn void destroy(Allocator allocator, void* state)
{
	Backend* b = (Backend*)state;
	b.iface.close();
	b.client.close();
	if (b.interface_name.len > 0) alloc::free(allocator, b.interface_name.ptr);
	alloc::free(allocator, b);
}

<* The loop: wait for the poll interval or a mailbox signal; run the commands; read and publish. *>
fn void run(void* state, NetworkHub* hub, Host{Command}* host)
{
	Backend* b         = (Backend*)state;
	objc::Obj delegate = install_delegate(host.mailbox());
	defer uninstall_delegate(delegate);
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 2))
	{
		network::publish_empty(hub);
		return;
	}
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
				network::wipe_command_secret(&commands[i]);
			}
			refresh(b, hub);
		};
	}
}

fn void refresh(Backend* b, NetworkHub* hub)
{
	Snapshot{State}* snapshot = hub.begin();
	snapshot.value = read_state(b, snapshot.allocator());
	network::publish_snapshot(hub, snapshot);
}

<* Route one command. Every CoreWLAN request completes synchronously on the worker. *>
fn void execute(Backend* b, Command* c)
{
	switch (c.kind)
	{
		case REFRESH:
		case SCAN_FINISHED: return;
		case SCAN:
			if (catch err = scan(b, c.settle)) fail_settle(c.settle, err);
		case CONNECT: finish_connect(c.connect, b, c);
		case DISCONNECT: disconnect(b, c.settle);
		case SET_RADIO:
			if (catch err = set_radio(b, c.settle, c.flag)) fail_settle(c.settle, err);
		case FORGET:
		case SET_AUTOCONNECT:
		case SUPPLY_CREDENTIALS:
		case CANCEL_CREDENTIALS:
			// The capability check refuses these before they are posted; reaching here is a bug.
			c.settle.fail(error::UNSUPPORTED);
			c.settle.release();
	}
}

fn void fail_settle(SettleOp* op, fault err)
{
	op.fail(err);
	op.release();
}

fn void settle_now(SettleOp* op, Settled value)
{
	op.succeed(value);
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
fn fault ns_error(ObjId failure, String what) @local
{
	long code = view(failure).send_long("code");
	return error::raise(corewlan_convert::fault_from_cw_error(code), error::Domain.NS_ERROR, (int)code, "%s", what);
}

fn void? scan(Backend* b, SettleOp* op)
{
	ObjId err     = (ObjId)null;
	ObjId results = b.iface.send_id("scanForNetworksWithName:includeHidden:error:", (ObjId)null, false, &err);
	if (results == (ObjId)null) return ns_error(err, "the scan failed")~;
	settle_now(op, Settled.CHANGED);
}

<* Join a network from the last scan, found by its octets. Withheld names cannot be matched. *>
fn Connected? connect(Backend* b, Command* c, Allocator out)
{
	char[] ssid   = c.ssid.bytes[0:c.ssid.len];
	ObjId network = find_scanned(b, ssid);
	if (network == (ObjId)null)
	{
		fault failure = corewlan_convert::missing_network_fault(corewlan_location::authorization(), has_withheld(b));
		if (failure == error::PERMISSION_DENIED) return error::raise(
			failure,
			error::Domain.INTERNAL,
			0,
			"%s",
			LOCATION_REMEDY
		)~;
		return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "that network is not in the last scan")~;
	}
	ObjId password = (ObjId)null;
	if (c.secret.len > 0) password = foundation::from_string((String)c.secret.bytes[0:c.secret.len]).ptr;
	ObjId err   = (ObjId)null;
	bool joined = b.iface.send_bool("associateToNetwork:password:error:", network, password, &err);
	if (!joined) return ns_error(err, "the network refused the join")~;
	return { .ssid = network::make_ssid(out, ssid), .interface_name = b.interface_name.copy(out) };
}

// The scanned network whose SSID octets equal `ssid`, or nil.
fn ObjId find_scanned(Backend* b, char[] ssid) @local
{
	ObjId list = scan_list(b);
	usz count  = foundation::array_count(list);
	for (usz i = 0; i < count; i++)
	{
		ObjId network = foundation::array_at(list, i);
		char[] octets = data_or_empty(view(network).send_id("ssidData"), tmem);
		if (octets.len > 0 && network::same_ssid(octets, ssid)) return network;
	}
	return (ObjId)null;
}

// Whether the last scan has a network whose name CoreWLAN withholds (no SSID data).
fn bool has_withheld(Backend* b) @local
{
	ObjId list = scan_list(b);
	usz count  = foundation::array_count(list);
	for (usz i = 0; i < count; i++)
	{
		ObjId network = foundation::array_at(list, i);
		if (data_or_empty(view(network).send_id("ssidData"), tmem).len == 0) return true;
	}
	return false;
}

// Whether this Mac is associated (see corewlan_convert.is_associated).
fn bool associated(Backend* b) @local
{
	objc::Obj iface = b.iface;
	return corewlan_convert::is_associated(
		iface.send_id("ssid") != (ObjId)null,
		iface.send_id("bssid") != (ObjId)null,
		iface.send_long("rssiValue"),
		iface.send_double("transmitRate")
	);
}

// The last scan's networks as an NSArray (possibly empty; never nil).
fn ObjId scan_list(Backend* b) @local
{
	ObjId set = b.iface.send_id("cachedScanResults");
	if (set == (ObjId)null) return objc::class_named("NSArray").send(ObjId, "array");
	return foundation::set_members(set);
}

// Disconnect needs no name: an association with withheld names is still one. Completes ALREADY when there is none.
fn void disconnect(Backend* b, SettleOp* op)
{
	if (!associated(b))
	{
		settle_now(op, Settled.ALREADY);
		return;
	}
	b.iface.send_void("disassociate");
	settle_now(op, Settled.CHANGED);
}

fn void? set_radio(Backend* b, SettleOp* op, bool on)
{
	if (b.iface.send_bool("powerOn") == on)
	{
		settle_now(op, Settled.ALREADY);
		return;
	}
	ObjId err = (ObjId)null;
	if (!b.iface.send_bool("setPower:error:", on, &err)) return ns_error(err, "the radio did not change")~;
	settle_now(op, Settled.CHANGED);
}

<*
 The state as CoreWLAN shows it right now. Withheld names are empty and `ssid_visible` is
 false while associated; `location` says why (the permission). An association is never
 reported as "not associated" because its name is withheld.
*>
fn State read_state(Backend* b, Allocator out)
{
	Wifi wifi = { .present = true, .interface_name = b.interface_name.copy(out) };
	wifi.radio_enabled = b.iface.send_bool("powerOn");
	ObjId ssid    = b.iface.send_id("ssid");
	ObjId bssid   = b.iface.send_id("bssid");
	bool linked   = associated(b);
	char[] octets = data_or_empty(b.iface.send_id("ssidData"), out);
	bool named    = ssid != (ObjId)null && octets.len > 0;
	if (named) wifi.connected_ssid = network::make_ssid(out, octets);
	wifi.ssid_visible = !linked || named;
	wifi.phase = linked ? CONNECTED : IDLE;
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
		.primary_interface = linked ? b.interface_name.copy(out) : "",
		.wifi = wifi,
		.interfaces = interfaces,
	};
}

<*
 One entry per network: the scanned access points are merged by SSID (`network::merge_access_point`),
 so a network seen on several bands or BSSIDs is listed once. Withheld names stay one entry per access point.
*>
fn AccessPoint[] scanned_networks(Backend* b, Allocator out, ObjId current_bssid) @local
{
	ObjId list = scan_list(b);
	usz count  = foundation::array_count(list);
	List{AccessPoint} merged;
	merged.init(tmem);
	for (usz i = 0; i < count; i++)
	{
		ObjId network    = foundation::array_at(list, i);
		objc::Obj object = view(network);
		long rssi        = object.send_long("rssiValue");
		ObjId channel    = object.send_id("wlanChannel");
		long number      = channel == (ObjId)null ? 0 : view(channel).send_long("channelNumber");
		long band        = channel == (ObjId)null ? 0 : view(channel).send_long("channelBand");
		String bssid     = bssid_text(object.send_id("bssid"), out);
		AccessPoint entry = {
			.ssid = network::make_ssid(out, data_or_empty(object.send_id("ssidData"), out)),
			.bssid = bssid,
			.band = corewlan_convert::band_from_cw(band),
			.security = security_of(object),
			.signal = maybe::value((Dbm)rssi),
			.quality = maybe::value(((Dbm)rssi).quality()),
			.in_use = current_bssid != (ObjId)null && bssid_text(current_bssid, tmem) == bssid && bssid.len > 0,
		};
		if (try mhz = corewlan_convert::frequency_from_channel(band, number)) entry.frequency = maybe::value(mhz);
		network::merge_access_point(&merged, entry);
	}
	return network::clone_access_points(out, merged.array_view());
}

// The octets of an NSData, or an empty slice when it is nil (withheld).
fn char[] data_or_empty(ObjId data, Allocator out) @local
{
	if (data == (ObjId)null) return { };
	if (try octets = foundation::data_bytes(data, out)) return octets;
	return { };
}

// The text of an NSString, or "" when it is nil (withheld).
fn String bssid_text(ObjId text, Allocator out) @local
{
	if (text == (ObjId)null) return "";
	if (try s = foundation::to_string(text, out)) return s;
	return "";
}

// The strongest security class the network supports, probed in PROBE_ORDER.
fn Security security_of(objc::Obj network) @local
{
	foreach (candidate : corewlan_convert::PROBE_ORDER)
	{
		if (network.send_bool("supportsSecurity:", candidate)) return corewlan_convert::security_from_cw(candidate);
	}
	return Security.UNKNOWN;
}