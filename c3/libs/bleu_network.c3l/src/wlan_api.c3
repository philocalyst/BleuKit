// The Windows backend: the Native Wifi (WLAN) API, wlanapi.dll.
// 
// Compiled for Windows; type-checked for every other target. It has not been
// run (no Windows machine is available to the project). The bindings and the
// sources of every constant and layout are in wlan_native.c3.
// 
// What it does not do in v1 (listed in README.md): it does not switch the radio
// (that needs the Windows.Devices.Radios consent path), it does not change
// autoconnect (a profile element written at connect time), it does not decode
// the WLAN failure reason of a failed connection (the notification payload),
// and it reads no Ethernet state (IP Helper is not bound).
// 
// Threading: WLAN calls run on the worker. The WLAN notification callback runs
// on a WLAN thread and only posts a refresh to the mailbox.
module bleu::network::wlan_api @feat(WIN32);
import std::time, std::collections::maybe, bleu::availability, bleu::observe, bleu::deadline, bleu::error, bleu::network, bleu::network::nm_convert, bleu::network::wlan_native, bleu::network::wlan_profile, bleu::rt::mailbox, bleu::rt::poller, bleu::rt::worker, bleu::unit, bleu::win::errors, bleu::win::guid, bleu::win::text;

<* Longest wait for a connection to finish, from the request. *>
const Duration CONNECT_TIMEOUT = (Duration)60_000_000;
<* Longest wait for a scan to report completion (its ACM notification), from the request. *>
const Duration SCAN_TIMEOUT = (Duration)20_000_000;
<* Longest wait for the interface to leave the network, from the request. *>
const Duration DISCONNECT_TIMEOUT = (Duration)15_000_000;

<* Commands taken from the mailbox per pass of the loop. *>
const usz COMMAND_BATCH = 16;

const String HEX_DIGITS = "0123456789abcdef";

<* The backend's state. The worker thread owns it. *>
struct Backend
{
	Allocator allocator;
	Duration poll;
	Guid interface_guid;
	String interface_name;
	void* handle;
	int interface_state; // WLAN_INTERFACE_STATE of the last read
	ConnectOp* connect; // the connection in progress, or null
	char[32] connect_ssid;
	usz connect_ssid_len;
	Deadline connect_deadline;
	bool connect_saw_busy; // the interface has left DISCONNECTED for the attempt
	SettleOp* scan; // the scan waiting for its completion notification, or null
	Deadline scan_deadline;
	SettleOp* disconnect; // the disconnect waiting for the interface to leave the network, or null
	Deadline disconnect_deadline;
}

const Driver DRIVER = {
	.info = { "wlanapi", "Native Wifi (WLAN API, wlanapi.dll)", 30 },
	.id = WLAN_API,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

fn bool probe(Options* options) => true;

<*
 Check that the WLAN service answers and that a Wi-Fi interface exists. The
 check runs on the caller's thread, with its own client handle.

 @return? error::UNAVAILABLE : "The WLAN service is not running, or there is no Wi-Fi interface"
*>
fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	void* handle = open_handle()!;
	defer wlan_native::wlan_close_handle(handle, null);
	WlanInterfaceInfo info;
	if (!first_interface(
		handle,
		&info
	)!) return error::raise(error::UNAVAILABLE, error::Domain.WIN32, 0, "there is no Wi-Fi interface")~;
	Backend* self = alloc::new(allocator, Backend, { .allocator = allocator, .poll = options.poll });
	fill_capabilities(capabilities);
	return self;
}

// Offer what the WLAN API does in v1; everything else says why it is not offered.
fn void fill_capabilities(Capabilities* capabilities) @local
{
	capabilities.init(availability::no(availability::Reason.UNSUPPORTED_BACKEND, "not offered by the WLAN backend"));
	capabilities.set(Cap.WIFI_SCAN, availability::YES);
	capabilities.set(Cap.WIFI_CONNECT_OPEN, availability::YES);
	capabilities.set(Cap.WIFI_CONNECT_PSK, availability::YES);
	capabilities.set(Cap.WIFI_DISCONNECT, availability::YES);
	capabilities.set(Cap.WIFI_FORGET, availability::YES);
	capabilities.set(Cap.SSID_VISIBILITY, availability::YES);
	capabilities.set(Cap.WIFI_BSSID, availability::YES);
	capabilities.set(Cap.WIFI_SIGNAL_DBM, availability::YES);
	capabilities.set(
		Cap.WIFI_RADIO,
		availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"radio control needs the Windows.Devices.Radios consent path, not bound in v1"
		)
	);
	capabilities.set(
		Cap.WIFI_AUTOCONNECT,
		availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"autoconnect is a profile element written at connect time; not changed in v1"
		)
	);
	capabilities.set(
		Cap.WIFI_SECRET_PROMPT,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "the key is written into the profile up front")
	);
	capabilities.set(
		Cap.INTERFACE_STATE,
		availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"Ethernet state needs IP Helper, not bound in v1; the Wi-Fi state is wifi.phase"
		)
	);
	capabilities.set(
		Cap.INTERFACE_SPEED,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "IP Helper is not bound in v1")
	);
	capabilities.set(
		Cap.INTERFACE_COUNTERS,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "IP Helper is not bound in v1")
	);
	capabilities.set(
		Cap.CONNECTIVITY,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "network list manager is not bound in v1")
	);
}

fn void destroy(Allocator allocator, void* state)
{
	Backend* b = (Backend*)state;
	if (b.interface_name.len > 0) alloc::free(allocator, b.interface_name.ptr);
	alloc::free(allocator, b);
}

// A WLAN client handle. The caller closes it.
fn void*? open_handle() @local
{
	uint negotiated = 0;
	void* handle    = null;
	uint code       = wlan_native::wlan_open_handle(wlan_native::CLIENT_VERSION, null, &negotiated, &handle);
	if (code != 0) return errors::raise_win32(code, "opening the WLAN service")~;
	return handle;
}

// The first Wi-Fi interface. Returns false when there is none.
fn bool? first_interface(void* handle, WlanInterfaceInfo* out) @local
{
	WlanInterfaceInfoList* list = null;
	uint code                   = wlan_native::wlan_enum_interfaces(handle, null, &list);
	if (code != 0) return errors::raise_win32(code, "listing the Wi-Fi interfaces")~;
	defer wlan_native::wlan_free_memory((void*)list);
	if (list.count == 0) return false;
	*out = list.items[0];
	return true;
}

<* The loop: wait for the poll interval or a notification; run the commands; read and publish. *>
fn void run(void* state, NetworkHub* hub, Host{Command}* host)
{
	Backend* b    = (Backend*)state;
	void*? opened = open_handle();
	if (catch err = opened)
	{
		network::publish_empty(hub);
		return;
	}
	b.handle = opened;
	defer wlan_native::wlan_close_handle(b.handle, null);
	if (catch err = register(b, host.mailbox()))
	{
	}
	defer unregister(b);
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
		if (catch poller.wait(b.poll))
		{
			// TIMEOUT is the normal tick.
		}
		usz count = host.mailbox().take_all(commands[..]);
		for (usz i = 0; i < count; i++)
		{
			execute(b, hub, &commands[i]);
			network::wipe_command_secret(&commands[i]);
		}
		refresh(b, hub);
	}
	abandon_connect(b);
	abandon_settles(b);
}

// Ask for ACM notifications; the callback posts a refresh.
fn void? register(Backend* b, Mailbox{Command}* box) @local
{
	uint previous = 0;
	uint code = wlan_native::wlan_register_notification(
		b.handle,
		wlan_native::NOTIFICATION_SOURCE_ACM,
		1,
		&on_notification,
		box,
		null,
		&previous
	);
	if (code != 0) return errors::raise_win32(code, "registering for WLAN notifications")~;
}

// Stop the notifications. Called from the worker, never from a callback.
fn void unregister(Backend* b) @local
{
	uint previous = 0;
	wlan_native::wlan_register_notification(
		b.handle,
		wlan_native::NOTIFICATION_SOURCE_NONE,
		1,
		null,
		null,
		null,
		&previous
	);
}

// WLAN notification callback: runs on a WLAN thread, so it only posts. A finished scan is its own
// command, because the request that started it waits for exactly that.
fn void on_notification(L2NotificationData* data, void* context)
{
	Mailbox{Command}* box = (Mailbox{Command}*)context;
	CommandKind kind = data.source == wlan_native::NOTIFICATION_SOURCE_ACM && data.code == wlan_native::ACM_SCAN_COMPLETE
		? SCAN_FINISHED
		: REFRESH;
	// A full queue already holds a refresh, so a refused post changes nothing.
	if (catch err = box.post({ .kind = kind }))
	{
	}
}

<* Route one command. Completes synchronously, except connections, which the next reads complete. *>
fn void execute(Backend* b, NetworkHub* hub, Command* c)
{
	switch (c.kind)
	{
		case REFRESH: return;
		case SCAN_FINISHED: finish_scan(b);
		case SCAN:
			if (catch err = scan(b, c.settle)) fail_settle(c.settle, err);
		case CONNECT: start_connect(b, hub, c);
		case DISCONNECT:
			if (catch err = disconnect(b, c.settle)) fail_settle(c.settle, err);
		case FORGET:
			if (catch err = forget(b, c)) fail_settle(c.settle, err);
		case SET_RADIO:
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

// Ask for a scan. The operation completes when the platform's scan-complete notification arrives
// (`finish_scan`), or fails with TIMEOUT (`settle_scan`). One scan at a time.
fn void? scan(Backend* b, SettleOp* op)
{
	if (b.scan != null) return error::raise(error::BUSY, error::Domain.INTERNAL, 0, "a scan is already running")~;
	uint code = wlan_native::wlan_scan(b.handle, &b.interface_guid, null, null, null);
	if (code != 0) return errors::raise_win32(code, "starting a scan")~;
	b.scan          = op;
	b.scan_deadline = deadline::after(SCAN_TIMEOUT);
}

// The scan-complete notification: the scan in progress is done.
fn void finish_scan(Backend* b) @local
{
	if (b.scan == null) return;
	b.scan.succeed(Settled.CHANGED);
	b.scan.release();
	b.scan = null;
}

// Fail the scan in progress when it has run out of time.
fn void settle_scan(Backend* b) @local
{
	if (b.scan == null || !b.scan_deadline.expired()) return;
	b.scan.fail(error::raise(TIMEOUT, error::Domain.WIN32, 0, "the scan did not finish in time"));
	b.scan.release();
	b.scan = null;
}

// Disconnect. Completes ALREADY when the interface is not connected or connecting; otherwise it
// completes CHANGED when the interface reports that it left the network (`settle_disconnect`).
fn void? disconnect(Backend* b, SettleOp* op)
{
	WlanInterfaceInfo info;
	if (!first_interface(b.handle, &info)!)
	{
		settle_now(op, Settled.ALREADY);
		return;
	}
	if (info.state == wlan_native::INTERFACE_STATE_DISCONNECTED || info.state == wlan_native::INTERFACE_STATE_NOT_READY)
	{
		settle_now(op, Settled.ALREADY);
		return;
	}
	if (b.disconnect != null) return error::raise(error::BUSY, error::Domain.INTERNAL, 0, "a disconnect is already running")~;
	uint code = wlan_native::wlan_disconnect(b.handle, &b.interface_guid, null);
	if (code != 0) return errors::raise_win32(code, "disconnecting")~;
	b.disconnect          = op;
	b.disconnect_deadline = deadline::after(DISCONNECT_TIMEOUT);
}

// Complete the disconnect in progress when the interface is out of the network, or fail it when it runs out of time.
fn void settle_disconnect(Backend* b, State* state) @local
{
	if (b.disconnect == null) return;
	if (!state.stale.wifi && state.wifi.phase == IDLE)
	{
		b.disconnect.succeed(Settled.CHANGED);
	}
	else if (b.disconnect_deadline.expired())
	{
		b.disconnect.fail(error::raise(TIMEOUT, error::Domain.WIN32, 0, "the disconnect did not finish in time"));
	}
	else
	{
		return;
	}
	b.disconnect.release();
	b.disconnect = null;
}

// Give up the scan and the disconnect in progress when the service stops.
fn void abandon_settles(Backend* b) @local
{
	if (b.scan != null)
	{
		b.scan.fail(error::CANCELLED);
		b.scan.release();
		b.scan = null;
	}
	if (b.disconnect != null)
	{
		b.disconnect.fail(error::CANCELLED);
		b.disconnect.release();
		b.disconnect = null;
	}
}

// Delete the profile of this SSID. NOT_FOUND when there is none.
fn void? forget(Backend* b, Command* c)
{
	@pool()
	{
		WideZ name = text::to_wide(tmem, profile_name_of(c))!!;
		uint code  = wlan_native::wlan_delete_profile(b.handle, &b.interface_guid, name.as_wstring(), null);
		if (code == wlan_native::ERROR_NOT_FOUND) return NOT_FOUND~;
		if (code != 0) return errors::raise_win32(code, "forgetting the network")~;
		settle_now(c.settle, Settled.CHANGED);
	};
}

fn String profile_name_of(Command* c) @local
{
	return wlan_profile::profile_name(tmem, c.ssid.bytes[0:c.ssid.len]);
}

<*
 Write the profile for the network and ask the interface to join it. The
 operation completes when the interface reports the network connected.
*>
fn void start_connect(Backend* b, NetworkHub* hub, Command* c)
{
	if (b.connect != null)
	{
		c.connect.fail(error::BUSY);
		c.connect.release();
		return;
	}
	if (catch err = join(b, hub, c))
	{
		c.connect.fail(err);
		c.connect.release();
	}
}

fn void? join(Backend* b, NetworkHub* hub, Command* c) @local
{
	char[] ssid       = c.ssid.bytes[0:c.ssid.len];
	String passphrase = (String)c.secret.bytes[0:c.secret.len];
	Security security = network::joinable_security(hub, ssid)!;
	@pool()
	{
		if (wlan_profile::connect_route(security, passphrase.len > 0) == wlan_profile::ConnectRoute.WRITE_PROFILE)
		{
			write_profile(b, ssid, security, passphrase, c.flag)!;
		}
		// Keyed networks without a passphrase connect by the saved profile's name, so nothing is rewritten.
		WideZ name_wide = text::to_wide(tmem, wlan_profile::profile_name(tmem, ssid))!!;
		wlan_native::WlanConnectionParameters parameters = {
			.mode = wlan_native::CONNECTION_MODE_PROFILE,
			.profile = name_wide.as_wstring(),
			.bss_type = wlan_native::BSS_TYPE_ANY,
		};
		uint code = wlan_native::wlan_connect(b.handle, &b.interface_guid, &parameters, null);
		if (code == wlan_native::ERROR_NOT_FOUND) return error::raise(
			error::AUTH_REQUIRED,
			error::Domain.WIN32,
			(int)code,
			"no saved profile for this network: its passphrase is needed"
		)~;
		if (code != 0) return errors::raise_win32(code, "joining the network")~;
	};
	b.connect = c.connect;
	c.connect = null;
	b.connect_ssid_len = ssid.len;
	mem::copy(&b.connect_ssid, ssid.ptr, ssid.len);
	b.connect_deadline = deadline::after(CONNECT_TIMEOUT);
	b.connect_saw_busy = false;
}

<*
 Write bleu's profile for a network: per-user (`profile_scope_flags`), replacing the profile
 of the same name, which only bleu writes (its names carry the "bleu-" prefix).
*>
fn void? write_profile(Backend* b, char[] ssid, Security security, String passphrase, bool autoconnect) @local
{
	String xml      = wlan_profile::profile_xml(tmem, ssid, security, passphrase, autoconnect)!;
	WideZ xml_wide  = text::to_wide(tmem, xml)!!;
	uint reason     = 0;
	uint code = wlan_native::wlan_set_profile(
		b.handle,
		&b.interface_guid,
		wlan_profile::profile_scope_flags(),
		xml_wide.as_wstring(),
		null,
		1,
		null,
		&reason
	);
	if (code == wlan_native::ERROR_ACCESS_DENIED) return error::raise(
		error::PERMISSION_DENIED,
		error::Domain.WIN32,
		(int)code,
		"writing the network profile: this user may not write it"
	)~;
	if (code != 0) return errors::raise_win32(code, "writing the network profile")~;
}

// The security class of the network in the last published scan.
fn Security security_on_air(NetworkHub* hub, char[] ssid) @local
{
	return network::security_on_air(hub, ssid);
}

// Give up a connection that is still in progress when the service stops.
fn void abandon_connect(Backend* b) @local
{
	if (b.connect == null) return;
	b.connect.fail(error::CANCELLED);
	b.connect.release();
	b.connect = null;
}

<*
 Read the interface and the networks, settle what the read decides (the connection,
 the scan, the disconnect) and publish. A read that cannot run keeps the previous picture.
*>
fn void refresh(Backend* b, NetworkHub* hub)
{
	Snapshot{State}* snapshot = hub.begin();
	if (try previous = hub.latest())
	{
		defer previous.release();
		snapshot.value = picture(b, snapshot.allocator(), &previous.value);
	}
	else
	{
		State none;
		snapshot.value = picture(b, snapshot.allocator(), &none);
	}
	settle_connect(b, &snapshot.value);
	settle_scan(b);
	settle_disconnect(b, &snapshot.value);
	network::publish_snapshot(hub, snapshot);
}

// The picture of one read, or the previous one flagged stale when the interface cannot be read.
fn State picture(Backend* b, Allocator out, State* previous) @local
{
	State? state = read_state(b, out, previous);
	if (catch err = state) return network::stale_picture(out, previous);
	return state;
}

// Complete the connection in progress when the network shows connected, fail it when the attempt
// visibly ended, or time it out. A failed attempt's WLAN reason is not decoded in v1.
fn void settle_connect(Backend* b, State* state) @local
{
	if (b.connect == null) return;
	int phase_state = b.interface_state;
	if (phase_state == wlan_native::INTERFACE_STATE_ASSOCIATING
		|| phase_state == wlan_native::INTERFACE_STATE_AUTHENTICATING
		|| phase_state == wlan_native::INTERFACE_STATE_DISCOVERING)
	{
		b.connect_saw_busy = true;
	}
	// A stale Wi-Fi block says nothing about the network now: only a fresh read can join the request.
	bool joined = !state.stale.wifi
		&& phase_state == wlan_native::INTERFACE_STATE_CONNECTED
		&& network::same_ssid(state.wifi.connected_ssid.bytes, b.connect_ssid[0:b.connect_ssid_len]);
	if (joined)
	{
		b.connect.succeed(
			{
				.ssid = network::make_ssid(b.connect.allocator(), state.wifi.connected_ssid.bytes),
				.interface_name = b.interface_name.copy(b.connect.allocator()),
			}
		);
		finish_connect(b);
		return;
	}
	if (b.connect_deadline.expired())
	{
		b.connect.fail(error::raise(TIMEOUT, error::Domain.WIN32, 0, "the connection did not finish in time"));
		finish_connect(b);
		return;
	}
	if (phase_state == wlan_native::INTERFACE_STATE_DISCONNECTED && b.connect_saw_busy)
	{
		b.connect.fail(
			error::raise(
				error::BACKEND_FAILURE,
				error::Domain.WIN32,
				0,
				"the connection attempt failed (the WLAN reason is not decoded in v1)"
			)
		);
		finish_connect(b);
	}
}

fn void finish_connect(Backend* b) @local
{
	b.connect.release();
	b.connect = null;
}

<*
 The Wi-Fi interface's view: its networks from the last scan, and the connection. When the
 networks cannot be listed, the Wi-Fi block is the previous one, flagged stale.
*>
fn State? read_state(Backend* b, Allocator out, State* previous)
{
	@pool()
	{
		WlanInterfaceInfo info;
		if (!first_interface(b.handle, &info)!) return { };
		b.interface_guid = info.guid;
		b.interface_state = info.state;
		String name = text::from_wide_units(out, info.description[..]) ?? "";
		Interface[] interfaces = alloc::new_array(out, Interface, 1);
		interfaces[0] = { .name = name.copy(out), .kind = WIFI, .link = UNKNOWN };
		Wifi wifi = {
			.present = true,
			.interface_name = name,
			.radio_enabled = info.state != wlan_native::INTERFACE_STATE_NOT_READY,
			.ssid_visible = true,
			.phase = phase_of(info.state),
		};
		if (try networks = read_networks(b, out))
		{
			wifi.networks = networks;
			foreach (&network : networks)
			{
				if (network.in_use) wifi.connected_ssid = network.ssid;
			}
		}
		else
		{
			return {
				.connectivity = UNKNOWN,
				.location = NOT_APPLICABLE,
				.wifi = network::clone_wifi(out, &previous.wifi),
				.interfaces = interfaces,
				.stale = { .wifi = true },
			};
		}
		return {
			.connectivity = UNKNOWN,
			.location = NOT_APPLICABLE,
			.wifi = wifi,
			.interfaces = interfaces,
		};
	};
}

// ConnectionPhase of an interface state.
fn ConnectionPhase phase_of(int state) @local
{
	switch (state)
	{
		case wlan_native::INTERFACE_STATE_CONNECTED: return CONNECTED;
		case wlan_native::INTERFACE_STATE_ASSOCIATING:
		case wlan_native::INTERFACE_STATE_AUTHENTICATING:
		case wlan_native::INTERFACE_STATE_DISCOVERING: return CONNECTING;
		case wlan_native::INTERFACE_STATE_DISCONNECTING: return DISCONNECTING;
		default: return IDLE;
	}
}

<* The networks of the last scan, one per SSID, with the strongest BSSID's signal and address. *>
fn AccessPoint[]? read_networks(Backend* b, Allocator out) @local
{
	WlanAvailableNetworkList* list = null;
	uint code = wlan_native::wlan_get_available_network_list(b.handle, &b.interface_guid, 0, null, &list);
	if (code != 0) return errors::raise_win32(code, "reading the visible networks")~;
	defer wlan_native::wlan_free_memory((void*)list);
	WlanBssList* bss            = read_bss(b);
	AccessPoint[] found         = alloc::new_array(out, AccessPoint, list.count);
	WlanAvailableNetwork* items = &list.items[0];
	for (uint i = 0; i < list.count; i++)
	{
		found[i] = access_point(out, &items[i], bss);
	}
	if (bss != null) wlan_native::wlan_free_memory((void*)bss);
	return found;
}

// Every BSS the driver knows, or null when none could be read (the networks are still listed).
fn WlanBssList* read_bss(Backend* b) @local
{
	WlanBssList* bss = null;
	uint code = wlan_native::wlan_get_network_bss_list(
		b.handle,
		&b.interface_guid,
		null,
		wlan_native::BSS_TYPE_ANY,
		0,
		null,
		&bss
	);
	if (code != 0) return null;
	return bss;
}

fn AccessPoint access_point(Allocator out, WlanAvailableNetwork* network, WlanBssList* bss) @local
{
	usz length  = min(network.ssid.length, wlan_native::SSID_OCTETS);
	char[] ssid = network.ssid.bytes[0:length];
	AccessPoint entry = {
		.ssid = network::make_ssid(out, ssid),
		.quality = maybe::value(unit::from_percent((float)network.signal_quality)),
		.security = security_of(network),
		.in_use = (network.flags & wlan_native::AVAILABLE_NETWORK_CONNECTED) != 0,
	};
	if (bss == null) return entry;
	WlanBssEntry* entries = &bss.entries[0];
	int best              = 0;
	bool found            = false;
	for (uint i = 0; i < bss.count; i++)
	{
		WlanBssEntry* candidate = &entries[i];
		if (candidate.ssid.length != length) continue;
		if (!mem::equals(candidate.ssid.bytes[..].ptr, ssid.ptr, (sz)length)) continue;
		if (found && candidate.rssi <= best) continue;
		found = true;
		best = candidate.rssi;
		entry.bssid = bssid_text(out, candidate.bssid);
		entry.signal = maybe::value((Dbm)candidate.rssi);
		uint mhz = candidate.center_frequency_khz / 1000;
		entry.frequency = maybe::value((MegaHertz)mhz);
		entry.band = nm_convert::band_from_mhz(mhz);
	}
	return entry;
}

// Six octets as "aa:bb:cc:dd:ee:ff".
fn String bssid_text(Allocator out, char[6] octets) @local
{
	DString text;
	text.init(tmem);
	for (usz i = 0; i < 6; i++)
	{
		if (i > 0) text.append_char(':');
		text.append_char(HEX_DIGITS[((char)octets[i] >> 4) & 0xF]);
		text.append_char(HEX_DIGITS[(char)octets[i] & 0xF]);
	}
	return text.copy_str(out);
}

// The strongest security class the network advertises, from its default authentication algorithm.
fn Security security_of(WlanAvailableNetwork* network) @local
{
	if (network.security_enabled == 0) return OPEN;
	switch (network.auth_algorithm)
	{
		case wlan_native::AUTH_OPEN: return WEP;
		case wlan_native::AUTH_SHARED_KEY: return WEP;
		case wlan_native::AUTH_WPA_PSK: return WPA_PSK;
		case wlan_native::AUTH_RSNA_PSK: return WPA2_PSK;
		case wlan_native::AUTH_WPA3_SAE: return WPA3_SAE;
		case wlan_native::AUTH_OWE: return OWE;
		case wlan_native::AUTH_WPA:
		case wlan_native::AUTH_RSNA:
		case wlan_native::AUTH_WPA3:
		case wlan_native::AUTH_WPA3_ENT: return ENTERPRISE;
		default: return UNKNOWN;
	}
}