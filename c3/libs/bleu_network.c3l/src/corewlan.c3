// The macOS backend: CoreWLAN, the public Wi-Fi framework.
//
// Everything here is compiled for macOS and type-checked on the other
// platforms' targets; it has not been run (no macOS machine is available to
// the project). docs/research/network.md section 2.2.1 gives the sources.
//
// What macOS hides: SSIDs and BSSIDs are withheld from an app without Location
// authorization (CWInterface.h, CWNetwork.h: "not available unless Location
// Services is enabled and the user has authorized the calling app"). They show
// as empty SSIDs and empty BSSIDs, and `State.location` says why.
//
// Threading: every CoreWLAN call runs on the worker. The delegate's callbacks
// (on CoreWLAN's threads) only post a refresh to the mailbox.
module bleu::network::corewlan @feat(DARWIN) @link("CoreWLAN.framework");
import std::io, std::time, std::collections::maybe, bleu::availability, bleu::error, bleu::network, bleu::network::corewlan_convert, bleu::network::corewlan_location, bleu::objc, bleu::objc::foundation, bleu::rt::poller, bleu::rt::worker;

<* CWEventType values (CoreWLANTypes.rs 613-636): the events the backend listens to. *>
const long CW_EVENT_POWER_DID_CHANGE      = 1;
const long CW_EVENT_SSID_DID_CHANGE       = 2;
const long CW_EVENT_BSSID_DID_CHANGE      = 3;
const long CW_EVENT_LINK_DID_CHANGE       = 5;
const long CW_EVENT_LINK_QUALITY_CHANGE   = 6;
const long CW_EVENT_MODE_DID_CHANGE       = 7;
const long CW_EVENT_SCAN_CACHE_UPDATED    = 8;

<* The ObjC class of the event delegate this backend registers at run time. *>
const ZString DELEGATE_CLASS = "BleuCoreWLANEvents";

<* Commands taken from the mailbox per pass of the loop. *>
const usz COMMAND_BATCH = 16;

<* The backend's state. The worker thread owns it. *>
struct Backend
{
	Allocator allocator;
	Duration poll;
	String interface_name;
	Obj client;     // CWWiFiClient.sharedWiFiClient
	Obj interface;  // CWInterface of the first Wi-Fi interface, retained
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
 Find the Wi-Fi interface. The real check needs the framework, so `create`
 makes it; a Mac without a Wi-Fi interface reports UNAVAILABLE here.

 @return? error::UNAVAILABLE : "This Mac has no Wi-Fi interface"
*>
fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	Backend* self = alloc::new(allocator, Backend, { .allocator = allocator, .poll = options.poll });
	self.client = objc::borrow(objc::class_named("CWWiFiClient").send(ObjId, "sharedWiFiClient"));
	ObjId found = self.client.send_id("interface");
	if (found == null)
	{
		self.client.close();
		alloc::free(allocator, self);
		return error::raise(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "this Mac has no Wi-Fi interface")~;
	}
	self.interface = objc::borrow(found);
	self.interface_name = foundation::to_string(self.interface.send_id("interfaceName"), allocator)!!;
	fill_capabilities(capabilities);
	return self;
}

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
	alloc::free(allocator, b.interface_name.ptr);
	alloc::free(allocator, b);
}

<* The loop: wait for the poll interval or a mailbox signal; run the commands; read and publish. *>
fn void run(void* state, NetworkHub* hub, Host{Command}* host)
{
	Backend* b = (Backend*)state;
	Obj delegate = install_delegate(b, host.mailbox());
	defer uninstall_delegate(b, delegate);
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
		usz count = host.mailbox().take_all(commands[..]);
		for (usz i = 0; i < count; i++)
		{
			execute(b, &commands[i]);
		}
		refresh(b, hub);
	}
}

fn void refresh(Backend* b, NetworkHub* hub)
{
	Snapshot{State}* snapshot = hub.begin();
	snapshot.value = read_state(b, snapshot.allocator());
	publish_snapshot(hub, snapshot);
}

<* Route one command. Every CoreWLAN request here completes synchronously. *>
fn void execute(Backend* b, Command* c)
{
	switch (c.kind)
	{
		case REFRESH: return;
		case SCAN: finish_settle(c.settle, scan(b));
		case CONNECT: finish_connect(c.connect, connect(b, c));
		case DISCONNECT: finish_settle(c.settle, disconnect(b));
		case SET_RADIO: finish_settle(c.settle, set_radio(b, c.flag));
		case FORGET:
		case SET_AUTOCONNECT:
			// Refused by the capability check before the command was posted; reaching here is a bug.
			finish_settle(c.settle, error::UNSUPPORTED~);
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

fn void finish_connect(ConnectOp* op, Connected? outcome)
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

<* The error an NSError from CoreWLAN stands for, as a Bleu excuse with its code in the detail. *>
fn fault ns_error(ObjId error, String what) @local
{
	long code = objc::Obj.borrow(error).send_long("code");
	return error::raise(fault_from_cw_error(code), error::Domain.NS_ERROR, (int)code, "%s", what);
}

fn Settled? scan(Backend* b)
{
	ObjId err = null;
	ObjId results = b.interface.send_id("scanForNetworksWithName:includeHidden:error:", (ObjId)null, false, &err);
	if (results == null) return ns_error(err, "the scan failed")~;
	return Settled.CHANGED;
}

<* Join a network from the last scan: by its octets, when they are not withheld. *>
fn Connected? connect(Backend* b, Command* c)
{
	char[] ssid = c.ssid.bytes[0 : c.ssid.len];
	ObjId network = find_scanned(b, ssid);
	if (network == null) return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "that network is not in the last scan (or its name is withheld)")~;
	ObjId password = null;
	if (c.secret.len > 0) password = foundation::from_string((String)c.secret.bytes[0 : c.secret.len]).ptr;
	ObjId err = null;
	bool joined = b.interface.send_bool("associateToNetwork:password:error:", network, password, &err);
	if (!joined) return ns_error(err, "the network refused the join")~;
	return { .ssid = network::make_ssid(tmem, ssid), .interface_name = b.interface_name.copy(tmem) };
}

// The scanned network whose SSID octets equal `ssid`, or nil.
fn ObjId find_scanned(Backend* b, char[] ssid) @local
{
	ObjId set = b.interface.send_id("cachedScanResults");
	if (set == null) return null;
	ObjId[] members = foundation::set_members(set);
	foreach (network : members)
	{
		ObjId data = objc::Obj.borrow(network).send_id("ssidData");
		if (data == null) continue;
		if (try octets = foundation::data_bytes(data, tmem))
		{
			if (network::same_ssid(octets, ssid)) return network;
		}
	}
	return null;
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
	ObjId err = null;
	if (!b.interface.send_bool("setPower:error:", on, &err)) return ns_error(err, "the radio did not change")~;
	return Settled.CHANGED;
}

<* The state as CoreWLAN shows it right now. Withheld names are empty; the location says why. *>
fn State read_state(Backend* b, Allocator out)
{
	Wifi wifi = { .present = true, .interface_name = b.interface_name.copy(out) };
	wifi.radio_enabled = b.interface.send_bool("powerOn");
	wifi.ssid_visible = false;
	ObjId ssid = b.interface.send_id("ssid");
	ObjId bssid = b.interface.send_id("bssid");
	if (ssid != null)
	{
		if (try octets = foundation::data_bytes(b.interface.send_id("ssidData"), out))
		{
			wifi.connected_ssid = network::make_ssid(out, octets);
			wifi.ssid_visible = true;
		}
	}
	bool associated = ssid != null || bssid != null;
	wifi.phase = associated ? CONNECTED : IDLE;
	wifi.networks = scanned_networks(b, out, bssid);
	foreach (&network : wifi.networks)
	{
		if (network.in_use) wifi.signal = network.signal;
	}
	return {
		.connectivity = UNKNOWN,
		.location = corewlan_location::authorization(),
		.primary_interface = associated ? b.interface_name.copy(out) : "",
		.wifi = wifi,
		.interfaces = alloc::clone_slice(out, { { .name = b.interface_name.copy(out), .kind = WIFI, .link = UNKNOWN } }),
	};
}

<* One entry per scanned access point. CoreWLAN gives no saved-profile information, so `known` stays false. *>
fn AccessPoint[] scanned_networks(Backend* b, Allocator out, ObjId current_bssid) @local
{
	ObjId set = b.interface.send_id("cachedScanResults");
	if (set == null) return {};
	ObjId[] members = foundation::set_members(set);
	AccessPoint[] found = alloc::new_array(out, AccessPoint, members.len);
	foreach (i, network : members)
	{
		Obj object = objc::Obj.borrow(network);
		long rssi = object.send_long("rssiValue");
		ObjId channel = object.send_id("wlanChannel");
		long number = channel == null ? 0 : objc::Obj.borrow(channel).send_long("channelNumber");
		long band = channel == null ? 0 : objc::Obj.borrow(channel).send_long("channelBand");
		AccessPoint entry = {
			.ssid = network::make_ssid(out, data_or_empty(object.send_id("ssidData"), out)),
			.bssid = bssid_text(object.send_id("bssid"), out),
			.band = corewlan_convert::band_from_cw(band),
			.security = security_of(object),
			.signal = maybe::value((Dbm)rssi),
			.quality = maybe::value(((Dbm)rssi).quality()),
		};
		if (try mhz = corewlan_convert::frequency_from_channel(band, number)) entry.frequency = maybe::value(mhz);
		entry.in_use = current_bssid != null && entry.bssid == bssid_text(current_bssid, out);
		found[i] = entry;
	}
	return found;
}

// The octets of an NSData, or an empty slice when it is nil (withheld).
fn char[] data_or_empty(ObjId data, Allocator out) @local
{
	if (data == null) return {};
	return foundation::data_bytes(data, out) ?? {};
}

fn String bssid_text(ObjId text, Allocator out) @local
{
	if (text == null) return "";
	return foundation::to_string(text, out) ?? "";
}

// The strongest security class the network supports, probed in PROBE_ORDER.
fn Security security_of(Obj network) @local
{
	foreach (candidate : corewlan_convert::probe_order())
	{
		if (network.send_bool("supportsSecurity:", candidate)) return corewlan_convert::security_from_cw(candidate);
	}
	return UNKNOWN;
}
