// Executing the commands the service posts. Runs on the worker thread only.
// 
// Ownership: a command carries one reference to its operation. A handler either
// completes the operation at once (and releases that reference), or hands the
// reference to a pending request, which releases it when it completes. A
// handler that returns an error leaves the reference to the caller, which the
// dispatcher then fails and releases. Temporaries live in the pool of the
// worker's loop iteration; anything kept longer is copied into the backend's
// allocator.
module bleu::network::networkmanager @feat(LINUX);
import bleu::error, bleu::network, bleu::network::nm_convert, bleu::network::nm_settings, bleu::dbus::message, bleu::dbus::marshal, bleu::dbus::proxy, bleu::dbus::value, bleu::dbus::names;

<* Name shown for a new profile when the SSID is not text. *>
const String FALLBACK_PROFILE_NAME = "Wi-Fi network";

<* Route one command. Errors are reported on its operation. *>
fn void execute(Backend* b, NetworkHub* hub, Command* c)
{
	switch (c.kind)
	{
		case REFRESH:
			// Every pass of the loop reads the platform; a refresh request needs nothing more.
			return;
		case CONNECT:
			if (catch err = try_connect(b, hub, c))
			{
				c.connect.fail(err);
				c.connect.release();
			}
		case SCAN:
			if (catch err = try_scan(b, c.settle)) fail_settle(c.settle, err);
		case DISCONNECT:
			if (catch err = try_disconnect(b, c.settle)) fail_settle(c.settle, err);
		case FORGET:
			if (catch err = try_forget(b, c)) fail_settle(c.settle, err);
		case SET_RADIO:
			if (catch err = try_radio(b, c)) fail_settle(c.settle, err);
		case SET_AUTOCONNECT:
			if (catch err = try_autoconnect(b, c)) fail_settle(c.settle, err);
		case SUPPLY_CREDENTIALS:
			if (catch err = try_supply(b, c)) fail_settle(c.settle, err);
		case CANCEL_CREDENTIALS:
			if (catch err = try_cancel(b, c)) fail_settle(c.settle, err);
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

// Every request that touches the radio needs the Wi-Fi device.
fn void? need_wifi(Backend* b)
{
	if (b.wifi_path.len == 0) return error::raise(
		error::UNAVAILABLE,
		error::Domain.INTERNAL,
		0,
		"there is no Wi-Fi interface"
	)~;
}

<*
 Connect to a network. Uses the saved profile when there is one and no
 passphrase is given; otherwise writes the profile (with the passphrase) and
 activates it.
*>
fn void? try_connect(Backend* b, NetworkHub* hub, Command* c)
{
	need_wifi(b)!;
	if (!b.radio_enabled) return error::raise(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "the Wi-Fi radio is off")~;
	char[] ssid        = c.ssid.bytes[0:c.ssid.len];
	String secret      = (String)c.secret.bytes[0:c.secret.len];
	Profile[] profiles = load_profiles(&b.bus, tmem)!;
	Security security  = network::security_on_air(hub, ssid);
	Profile saved;
	bool known         = false;
	if (try found = find_profile(profiles, ssid))
	{
		saved = found;
		known = true;
	}
	String active;
	if (secret.len == 0)
	{
		if (known)
		{
			active = activate(b, saved.path)!;
		}
		else if (security == Security.OPEN || security == Security.OWE)
		{
			nm_settings::ProfileSpec open_spec = {
				.ssid = ssid,
				.id = display_id(ssid),
				.uuid = nm_settings::uuid_for_ssid(tmem, ssid),
				.autoconnect = c.flag,
				.key_mgmt = security == Security.OWE ? nm_settings::KeyManagement.OWE
					: nm_settings::KeyManagement.OPEN,
			};
			active = add_and_activate(b, open_spec)!;
		}
		else
		{
			// A secured network with no passphrase: the profile has no psk, so NetworkManager asks the
			// secret agent for it, which publishes CREDENTIALS_WANTED.
			nm_settings::ProfileSpec ask_spec = {
				.ssid = ssid,
				.id = display_id(ssid),
				.uuid = nm_settings::uuid_for_ssid(tmem, ssid),
				.autoconnect = c.flag,
				.key_mgmt = security == Security.WPA3_SAE ? nm_settings::KeyManagement.SAE : nm_settings::KeyManagement.WPA_PSK,
			};
			active = add_and_activate(b, ask_spec)!;
		}
		b.last_supplied = false;
	}
	else
	{
		if (security == Security.OPEN) return error::raise(
			error::INVALID_ARGUMENT,
			error::Domain.INTERNAL,
			0,
			"the network is open: no passphrase applies"
		)~;
		if (security == Security.WEP || security == Security.ENTERPRISE) return error::raise(
			error::UNSUPPORTED,
			error::Domain.INTERNAL,
			0,
			"WEP and 802.1X networks cannot be joined by this backend yet"
		)~;
		nm_settings::ProfileSpec spec = {
			.ssid = ssid,
			.id = display_id(ssid),
			.uuid = known ? saved.uuid : nm_settings::uuid_for_ssid(tmem, ssid),
			.autoconnect = c.flag,
			.key_mgmt = security == Security.WPA3_SAE ? nm_settings::KeyManagement.SAE
				: nm_settings::KeyManagement.WPA_PSK,
			.psk = secret,
		};
		if (known)
		{
			update_profile(b, saved.path, spec)!;
			active = activate(b, saved.path)!;
		}
		else
		{
			active = add_and_activate(b, spec)!;
		}
		b.last_supplied = true;
	}
	add_pending(
		b,
		{
			.kind = CONNECT,
			.connect = c.connect,
			.device = own_text(b.allocator, b.wifi_path),
			.active = own_text(b.allocator, active),
			.interface_name = own_text(b.allocator, b.wifi_name),
			.ssid = alloc::clone_slice(b.allocator, ssid),
			.supplied = secret.len > 0,
		}
	);
	c.connect = null;
}

// The name shown for a new profile: the SSID as text when it is UTF-8, else a fixed name.
fn String display_id(char[] ssid) @local
{
	String text = (String)ssid;
	return names::is_utf8_text(text) ? text : FALLBACK_PROFILE_NAME;
}

<* Start a scan. The request completes when NetworkManager reports a new LastScan. *>
fn void? try_scan(Backend* b, SettleOp* op)
{
	need_wifi(b)!;
	Proxy wireless = object_proxy(&b.bus, b.wifi_path, NM_WIRELESS_IFACE)!;
	Message* call  = wireless.new_call(mem, "RequestScan")!;
	defer call.release();
	Value[] none = { };
	call.body_writer("a{sv}")!.append_value(value::array(tmem, "{sv}", none)!)!;
	Message* reply = b.bus.call(call)!;
	reply.release();
	add_pending(
		b,
		{
			.kind = SCAN,
			.settle = op,
			.device = own_text(b.allocator, b.wifi_path),
			.last_scan = b.last_scan,
		}
	);
}

<* Disconnect the Wi-Fi device. Completes ALREADY when it is neither connected nor connecting. *>
fn void? try_disconnect(Backend* b, SettleOp* op)
{
	if (b.wifi_path.len == 0 || !is_active_state(b.device_state))
	{
		settle_now(op, ALREADY);
		return;
	}
	Proxy device = object_proxy(&b.bus, b.wifi_path, NM_DEVICE_IFACE)!;
	method_void(&device, "Disconnect")!;
	add_pending(
		b,
		{
			.kind = DISCONNECT,
			.settle = op,
			.device = own_text(b.allocator, b.wifi_path),
		}
	);
}

// Whether a device state means it is connected or on its way to being so.
fn bool is_active_state(uint state) @local
{
	return state >= nm_convert::DEVICE_STATE_PREPARE && state != nm_convert::DEVICE_STATE_UNMANAGED;
}

<* Delete the saved profile for this SSID. NOT_FOUND when there is none. *>
fn void? try_forget(Backend* b, Command* c)
{
	Profile[] profiles = load_profiles(&b.bus, tmem)!;
	Profile saved;
	if (try found = find_profile(profiles, c.ssid.bytes[0:c.ssid.len]))
	{
		saved = found;
	}
	else
	{
		return NOT_FOUND~;
	}
	Proxy connection = object_proxy(&b.bus, saved.path, NM_CONNECTION_IFACE)!;
	method_void(&connection, "Delete")!;
	settle_now(c.settle, Settled.CHANGED);
}

<* Switch the radio. Completes when WirelessEnabled reads the wanted value. *>
fn void? try_radio(Backend* b, Command* c)
{
	if (b.radio_enabled == c.flag)
	{
		settle_now(c.settle, Settled.ALREADY);
		return;
	}
	b.nm.set_property("WirelessEnabled", value::boolean(c.flag))!;
	add_pending(b, { .kind = RADIO, .settle = c.settle, .target = c.flag });
}

<* Set `connection.autoconnect` of the saved profile for this SSID. *>
fn void? try_autoconnect(Backend* b, Command* c)
{
	Profile[] profiles = load_profiles(&b.bus, tmem)!;
	Profile saved;
	if (try found = find_profile(profiles, c.ssid.bytes[0:c.ssid.len]))
	{
		saved = found;
	}
	else
	{
		return NOT_FOUND~;
	}
	if (saved.autoconnect == c.flag)
	{
		settle_now(c.settle, Settled.ALREADY);
		return;
	}
	Proxy connection = object_proxy(&b.bus, saved.path, NM_CONNECTION_IFACE)!;
	Value current    = method_value(&connection, "GetSettings", tmem)!;
	Value updated    = nm_settings::with_bool(tmem, current, nm_settings::GROUP_CONNECTION, "autoconnect", c.flag)!;
	update_settings(b, saved.path, updated)!;
	settle_now(c.settle, Settled.CHANGED);
}

<* Activate a saved profile on the Wi-Fi device. Returns the active connection's path (in `tmem`). *>
fn String? activate(Backend* b, String profile)
{
	Message* call = b.nm.new_call(mem, "ActivateConnection")!;
	defer call.release();
	Writer* w = call.body_writer("ooo")!;
	w.append_object_path(profile)!;
	w.append_object_path(b.wifi_path)!;
	w.append_object_path(NO_OBJECT)!;
	Message* reply = b.bus.call(call)!;
	defer reply.release();
	Reader r = reply.reader()!;
	return r.read_object_path()!.copy(tmem);
}

<* Write a new profile and activate it. Returns the active connection's path (in `tmem`). *>
fn String? add_and_activate(Backend* b, nm_settings::ProfileSpec spec)
{
	Value settings = nm_settings::profile_settings(tmem, spec)!;
	Message* call  = b.nm.new_call(mem, "AddAndActivateConnection2")!;
	defer call.release();
	Value[] none = { };
	Writer* w    = call.body_writer("a{sa{sv}}ooa{sv}")!;
	w.append_value(settings)!;
	w.append_object_path(b.wifi_path)!;
	w.append_object_path(NO_OBJECT)!;
	w.append_value(value::array(tmem, "{sv}", none)!)!;
	Message* reply = b.bus.call(call)!;
	defer reply.release();
	Reader r = reply.reader()!;
	r.read_object_path()!;
	return r.read_object_path()!.copy(tmem);
}

<* Replace the settings of a saved profile with `spec`. *>
fn void? update_profile(Backend* b, String profile, nm_settings::ProfileSpec spec)
{
	Value settings = nm_settings::profile_settings(tmem, spec)!;
	update_settings(b, profile, settings)!;
}

<* Replace the settings of a saved profile, persisting them. *>
fn void? update_settings(Backend* b, String profile, Value settings)
{
	Proxy connection = object_proxy(&b.bus, profile, NM_CONNECTION_IFACE)!;
	Message* call    = connection.new_call(mem, "Update2")!;
	defer call.release();
	Value[] none = { };
	Writer* w    = call.body_writer("a{sa{sv}}ua{sv}")!;
	w.append_value(settings)!;
	w.append_u32(0)!;
	w.append_value(value::array(tmem, "{sv}", none)!)!;
	Message* reply = b.bus.call(call)!;
	reply.release();
}

<* Ask NetworkManager to stop the activation `active`. Callers treat failure as best effort. *>
fn void? deactivate(Backend* b, String active)
{
	if (active.len == 0) return;
	Message* call = b.nm.new_call(mem, "DeactivateConnection")!;
	defer call.release();
	call.body_writer("o")!.append_object_path(active)!;
	Message* reply = b.bus.call(call)!;
	reply.release();
}

<*
 Answer the prompt `c.request` with the passphrase: the agent's reply to
 NetworkManager's GetSecrets carries it, and the connection proceeds.
*>
fn void? try_supply(Backend* b, Command* c)
{
	if (try index = find_prompt(b, c.request))
	{
		Prompt* prompt = b.prompts.get_ref(index);
		Value secrets = nm_settings::secrets_settings(tmem, (String)c.secret.bytes[0 : c.secret.len])!;
		Value[] answer = { secrets };
		b.server.reply(prompt.token, answer)!;
		mark_supplied(b, prompt.ssid);
		b.last_supplied = true;
		drop_prompt(b, index);
		settle_now(c.settle, Settled.CHANGED);
		return;
	}
	return NOT_FOUND~;
}

<* Refuse the prompt `c.request`: NetworkManager fails the connection it belongs to. *>
fn void? try_cancel(Backend* b, Command* c)
{
	if (try index = find_prompt(b, c.request))
	{
		Prompt* prompt = b.prompts.get_ref(index);
		b.server.reply_error(prompt.token, ERROR_USER_CANCELED, "the user cancelled the request")!;
		drop_prompt(b, index);
		settle_now(c.settle, Settled.CHANGED);
		return;
	}
	return NOT_FOUND~;
}

// The connections waiting for this SSID's passphrase have it now.
fn void mark_supplied(Backend* b, char[] ssid) @local
{
	foreach (&p : b.pending.array_view())
	{
		if (p.kind == CONNECT && network::same_ssid(p.ssid, ssid)) p.supplied = true;
	}
}
