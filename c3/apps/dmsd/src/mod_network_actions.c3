<*
 The `network` methods that act or answer a question: the Wi-Fi actions, `network.info`,
 `network.wifi.networks` and the answers to a passphrase prompt
 (`network.credentials.submit` and `cancel`). Each handler's context is the Bleu service.

 Source: DMS `core/internal/server/network/handlers.go` at 8be08999; each handler cites
 its lines. DMS answers a connection as soon as it is queued, and so does this module:
 the outcome is in the `network` state. The other actions wait for their operation,
 bounded by WRITE_TIMEOUT, so a refusal reaches the caller as an error.
*>
module dmsd::network_actions;
import std::collections::object, std::time, bleu::network, bleu::observe, bleu::ipc, bleu::error, bleu::json, bleu::deadline, dmsd::contract, dmsd::wire, dmsd::params, dmsd::network_state;

// How long a request waits for its operation to finish.
const Duration WRITE_TIMEOUT      = (Duration)5_000_000;
// How long a request waits for the state a re-read publishes (brightness waits as long for its write's state).
const Duration SETTLE_TIMEOUT     = (Duration)500_000;
// The 802.1X fields of DMS's `wifi.connect` (handlers.go:208-214). Bleu refuses enterprise networks.
const String[8] ENTERPRISE_FIELDS = {
	"username",
	"anonymousIdentity",
	"domainSuffixMatch",
	"eapMethod",
	"phase2Auth",
	"caCertPath",
	"clientCertPath",
	"privateKeyPath",
};
// The secret of a Wi-Fi passphrase prompt: the field name DMS uses for it (agent_networkmanager.go buildFieldsInfo).
const String PSK_FIELD            = "psk";

// An optional string member: `fallback` when absent or not a string (params.StringOpt).
fn String opt_text(Object* params, String key, String fallback) @private
{
	if (try value = json::read::get_string(params, key)) return value;
	return fallback;
}

// A required object member, with the error text of the other required members (dankgo's `params` package).
fn Object*? param_object(Object* params, String key) @private
{
	if (try value = json::read::get_object(params, key)) return value;
	return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "missing or invalid '%s' parameter", key)~;
}

// Raise `err` with a message of this request. Bleu's faults often carry no text of their own, and
// the thread's last failure may belong to an earlier request, so the message is always the caller's.
fn fault refused(fault err, String text) @private
{
	return error::raise_text(err, error::Domain.INTERNAL, 0, text);
}

// Wait for a settle operation. A NOT_FOUND is raised with `missing` (what was looked for). Any other failure
// is raised with `text`, followed by the backend's own message when it gave one.
fn void? await_settle(network::SettleOp* op, String text, String missing) @private
{
	if (catch err = op.wait(WRITE_TIMEOUT))
	{
		String what   = err == NOT_FOUND && missing.len > 0 ? missing : text;
		String reason = op.detail().message();
		if (reason.len == 0) return refused(err, what)~;
		return error::raise(err, error::Domain.INTERNAL, 0, "%s: %s", what, reason)~;
	}
}

// `{"enabled": bool}`, the reply of the radio methods (handlers.go:265-281).
fn String? enabled_reply(Allocator allocator, bool enabled) @private
{
	wire::Line line;
	line.begin(allocator);
	line.writer.begin_object()!;
	wire::key_bool(&line.writer, "enabled", enabled)!;
	line.writer.end_object()!;
	return line.finish();
}

// bleu::network manages one Wi-Fi interface, the first one. DMS names an interface with `device`:
// the name of that interface is accepted, any other name is refused.
fn void? check_device(network::Network* service, Object* params) @private
{
	String device = opt_text(params, "device", "");
	if (device.len == 0) return;
	observe::Snapshot{network::State}*? now = service.latest();
	if (catch err = now) return refused(err, "cannot read the Wi-Fi interface")~;
	defer now.release();
	if (device == now.value.wifi.interface_name) return;
	return error::raise(
		error::UNSUPPORTED,
		error::Domain.INTERNAL,
		0,
		"not supported: bleu_network manages only the Wi-Fi interface '%s'",
		now.value.wifi.interface_name
	)~;
}

// bleu::network refuses an enterprise (802.1X) network, so a request that names one is refused here, and
// the field is named. DMS's `useSystemCACerts` is refused as well when it is present.
fn void? refuse_enterprise(Object* params) @private
{
	foreach (field : ENTERPRISE_FIELDS)
	{
		String value = opt_text(params, field, "");
		if (value.len == 0) continue;
		return error::raise(
			error::UNSUPPORTED,
			error::Domain.INTERNAL,
			0,
			"not supported: 802.1X sign-in ('%s') is not available in bleu_network",
			field
		)~;
	}
	if (try found = json::read::present(params, "useSystemCACerts"))
	{
		if (found != null) return error::raise(
			error::UNSUPPORTED,
			error::Domain.INTERNAL,
			0,
			"not supported: 802.1X certificates ('useSystemCACerts') are not available in bleu_network"
		)~;
	}
}

// The credentials token is the prompt's request id, in decimal.
fn ulong? parse_token(String token) @private
{
	if (try request = token.to_ulong()) return request;
	return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "unknown credentials token '%s'", token)~;
}

// The passphrase of a prompt answer: the `psk` member of `secrets`.
fn String? passphrase_of(Object* secrets) @private
{
	if (try psk = json::read::get_string(secrets, PSK_FIELD)) return psk;
	return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "missing or invalid 'psk' secret")~;
}

// `network.wifi.scan` (handlers.go:156-169). The scan is queued and answered "scanning".
fn void handle_wifi_scan(void* context, ipc::Call* call)
{
	network::Network* service = (network::Network*)context;
	@pool()
	{
		if (catch scan_wifi(service, call))
		{
			call.respond_error(contract::failure_text("cannot scan for networks"));
		}
	};
}

fn void? scan_wifi(network::Network* service, ipc::Call* call) @private
{
	check_device(service, call.params)!;
	network::SettleOp*? result = service.scan();
	if (catch err = result) return refused(err, "cannot scan for networks")~;
	result.release();
	wire::respond_success(call, "scanning")!;
}

// `network.wifi.connect` (handlers.go:175-226). Queued and answered "connecting". A network that needs
// a passphrase and was given none is asked for through the prompt stream (`network.credentials`): NetworkManager
// asks the agent, and the agent parks the request until a passphrase is answered.
fn void handle_wifi_connect(void* context, ipc::Call* call)
{
	network::Network* service = (network::Network*)context;
	@pool()
	{
		if (catch connect_wifi(service, call))
		{
			call.respond_error(contract::failure_text("cannot connect to the network"));
		}
	};
}

// bleu::network judges a connection by the last scan, but it does so on its worker, after the request was
// answered. The same test is made here, so a network that cannot be joined is refused in the reply.
fn void? check_joinable(network::Network* service, String ssid) @private
{
	observe::Snapshot{network::State}*? now = service.latest();
	if (catch err = now) return refused(err, "cannot read the networks")~;
	defer now.release();
	foreach (&ap : now.value.wifi.networks)
	{
		if ((String)ap.ssid.bytes != ssid) continue;
		if (ap.security == network::Security.UNKNOWN) return error::raise(
			error::UNSUPPORTED,
			error::Domain.INTERNAL,
			0,
			"not supported: the security of network '%s' is not known, so it cannot be joined",
			ssid
		)~;
		return;
	}
	return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "network not found: %s", ssid)~;
}

fn void? connect_wifi(network::Network* service, ipc::Call* call) @private
{
	String ssid     = params::param_string(call.params, "ssid")!;
	String password = opt_text(call.params, "password", "");
	refuse_enterprise(call.params)!;
	check_device(service, call.params)!;
	check_joinable(service, ssid)!;
	network::ConnectOp*? result = service.connect({ .ssid = ssid, .passphrase = password, .autoconnect = true });
	if (catch err = result) return refused(err, "cannot connect to the network")~;
	result.release();
	wire::respond_success(call, "connecting")!;
}

// `network.wifi.disconnect` (handlers.go:228-241).
fn void handle_wifi_disconnect(void* context, ipc::Call* call)
{
	network::Network* service = (network::Network*)context;
	@pool()
	{
		if (catch disconnect_wifi(service, call))
		{
			call.respond_error(contract::failure_text("cannot disconnect"));
		}
	};
}

fn void? disconnect_wifi(network::Network* service, ipc::Call* call) @private
{
	check_device(service, call.params)!;
	network::SettleOp*? result = service.disconnect();
	if (catch err = result) return refused(err, "cannot disconnect")~;
	defer result.release();
	await_settle(result, "failed to disconnect", "")!;
	wire::respond_success(call, "disconnected")!;
}

// `network.wifi.forget` (handlers.go:243-256). NOT_FOUND when no saved network has the name.
fn void handle_wifi_forget(void* context, ipc::Call* call)
{
	network::Network* service = (network::Network*)context;
	@pool()
	{
		if (catch forget_wifi(service, call))
		{
			call.respond_error(contract::failure_text("cannot forget the network"));
		}
	};
}

fn void? forget_wifi(network::Network* service, ipc::Call* call) @private
{
	String ssid                = params::param_string(call.params, "ssid")!;
	network::SettleOp*? result = service.forget(ssid);
	if (catch err = result) return refused(err, "cannot forget the network")~;
	defer result.release();
	await_settle(result, "failed to forget the network", "no saved network has this name")!;
	reread_profile(service, ssid, false, false)!;
	wire::respond_success(call, "forgotten")!;
}

// Switch the radio and answer `{"enabled": <the value now set>}`.
fn void? set_radio(network::Network* service, ipc::Call* call, bool enabled) @private
{
	network::SettleOp*? result = service.set_radio(enabled);
	if (catch err = result) return refused(err, "cannot switch the Wi-Fi radio")~;
	defer result.release();
	await_settle(result, "failed to switch the Wi-Fi radio", "")!;
	settle_radio(service, enabled);
	call.respond_raw(enabled_reply(tmem, enabled)!)!;
}

// `network.wifi.toggle` (handlers.go:258-266): the radio is switched to the opposite of its state now.
fn void handle_wifi_toggle(void* context, ipc::Call* call)
{
	network::Network* service = (network::Network*)context;
	@pool()
	{
		if (catch toggle_wifi(service, call))
		{
			call.respond_error(contract::failure_text("cannot toggle the Wi-Fi radio"));
		}
	};
}

fn void? toggle_wifi(network::Network* service, ipc::Call* call) @private
{
	observe::Snapshot{network::State}*? now = service.latest();
	if (catch err = now) return refused(err, "cannot read the Wi-Fi radio")~;
	defer now.release();
	set_radio(service, call, !now.value.wifi.radio_enabled)!;
}

// `network.wifi.enable` (handlers.go:268-274).
fn void handle_wifi_enable(void* context, ipc::Call* call)
{
	network::Network* service = (network::Network*)context;
	@pool()
	{
		if (catch set_radio(service, call, true))
		{
			call.respond_error(contract::failure_text("cannot enable the Wi-Fi radio"));
		}
	};
}

// `network.wifi.disable` (handlers.go:276-282).
fn void handle_wifi_disable(void* context, ipc::Call* call)
{
	network::Network* service = (network::Network*)context;
	@pool()
	{
		if (catch set_radio(service, call, false))
		{
			call.respond_error(contract::failure_text("cannot disable the Wi-Fi radio"));
		}
	};
}

// `network.wifi.setAutoconnect` (handlers.go:95, manager.go SetWiFiAutoconnect).
fn void handle_wifi_set_autoconnect(void* context, ipc::Call* call)
{
	network::Network* service = (network::Network*)context;
	@pool()
	{
		if (catch set_autoconnect(service, call))
		{
			call.respond_error(contract::failure_text("failed to set autoconnect"));
		}
	};
}

// The saved profile of `ssid` as the published state shows it: not known, or known with this autoconnect.
// A network that is not in the last scan shows nothing, so it counts as settled.
fn bool profile_settled(network::State* state, String ssid, bool known, bool autoconnect) @private
{
	foreach (&ap : state.wifi.networks)
	{
		if ((String)ap.ssid.bytes != ssid) continue;
		return ap.known == known && (!known || ap.autoconnect == autoconnect);
	}
	return true;
}

// Ask for a re-read of the saved profiles (Bleu publishes their flags only on a re-read), then wait for the
// state that shows `ssid` as the change says. A re-read that changes nothing publishes nothing.
fn void? reread_profile(network::Network* service, String ssid, bool known, bool autoconnect) @private
{
	if (catch err = service.refresh()) return refused(err, "cannot re-read the networks")~;
	Deadline deadline = deadline::after(SETTLE_TIMEOUT);
	ulong seen        = 0;
	while (!deadline.expired())
	{
		observe::Snapshot{network::State}*? next = service.wait_after(seen, deadline.remaining());
		if (catch next) return;
		seen = next.generation;
		bool settled = profile_settled(&next.value, ssid, known, autoconnect);
		next.release();
		if (settled) return;
	}
}

// Wait, up to SETTLE_TIMEOUT, for a published state whose radio is `enabled`: the platform reports the
// operation's end before Bleu publishes the state. A state that does not come is not an error; the reply
// then carries the newest one.
fn void settle_radio(network::Network* service, bool enabled) @private
{
	Deadline deadline = deadline::after(SETTLE_TIMEOUT);
	ulong seen        = 0;
	while (!deadline.expired())
	{
		observe::Snapshot{network::State}*? next = service.wait_after(seen, deadline.remaining());
		if (catch next) return;
		seen = next.generation;
		bool settled = next.value.wifi.radio_enabled == enabled;
		next.release();
		if (settled) return;
	}
}

fn void? set_autoconnect(network::Network* service, ipc::Call* call) @private
{
	String ssid                = params::param_string(call.params, "ssid")!;
	bool autoconnect           = params::param_bool(call.params, "autoconnect")!;
	network::SettleOp*? result = service.set_autoconnect(ssid, autoconnect);
	if (catch err = result) return refused(err, "cannot change autoconnect")~;
	defer result.release();
	await_settle(result, "failed to set autoconnect", "no saved network has this name")!;
	reread_profile(service, ssid, true, autoconnect)!;
	wire::respond_success(call, "autoconnect updated")!;
}

// `network.wifi.networks` (handlers.go:171-173): the access points of the last scan.
fn void handle_wifi_networks(void* context, ipc::Call* call)
{
	network::Network* service = (network::Network*)context;
	@pool()
	{
		if (catch wifi_networks(service, call))
		{
			call.respond_error(contract::failure_text("cannot read the Wi-Fi networks"));
		}
	};
}

fn void? wifi_networks(network::Network* service, ipc::Call* call) @private
{
	observe::Snapshot{network::State}*? now = service.latest();
	if (catch err = now) return refused(err, "cannot read the Wi-Fi networks")~;
	defer now.release();
	call.respond_raw(network_state::render_networks(tmem, &now.value)!)!;
}

// `network.info` (handlers.go:397-410): one network by name.
fn void handle_info(void* context, ipc::Call* call)
{
	network::Network* service = (network::Network*)context;
	@pool()
	{
		if (catch network_info(service, call))
		{
			call.respond_error(contract::failure_text("cannot describe the network"));
		}
	};
}

fn void? network_info(network::Network* service, ipc::Call* call) @private
{
	String ssid                             = params::param_string(call.params, "ssid")!;
	observe::Snapshot{network::State}*? now = service.latest();
	if (catch err = now) return refused(err, "cannot describe the network")~;
	defer now.release();
	call.respond_raw(network_state::render_info(tmem, ssid, &now.value)!)!;
}

// `network.credentials.submit` (handlers.go:110-135): the passphrase answers the prompt with this token.
// `save` false is refused: bleu_network leaves the passphrase in the saved profile, as NetworkManager keeps it.
fn void handle_credentials_submit(void* context, ipc::Call* call)
{
	network::Network* service = (network::Network*)context;
	@pool()
	{
		if (catch submit_credentials(service, call))
		{
			call.respond_error(contract::failure_text("cannot submit the credentials"));
		}
	};
}

fn void? submit_credentials(network::Network* service, ipc::Call* call) @private
{
	String token      = params::param_string(call.params, "token")!;
	Object* secrets   = param_object(call.params, "secrets")!;
	bool save         = params::opt_bool(call.params, "save", true);
	ulong request     = parse_token(token)!;
	String passphrase = passphrase_of(secrets)!;
	if (!save) return error::raise(
		error::UNSUPPORTED,
		error::Domain.INTERNAL,
		0,
		"not supported: bleu_network always keeps the passphrase in the saved profile"
	)~;
	network::SettleOp*? result = service.supply_credentials(request, passphrase);
	if (catch err = result) return refused(err, "cannot submit the credentials")~;
	defer result.release();
	await_settle(result, "failed to submit the credentials", "no pending prompt has this token")!;
	wire::respond_success(call, "credentials submitted")!;
}

// `network.credentials.cancel` (handlers.go:137-150): the connection that asked for the prompt fails.
fn void handle_credentials_cancel(void* context, ipc::Call* call)
{
	network::Network* service = (network::Network*)context;
	@pool()
	{
		if (catch cancel_credentials(service, call))
		{
			call.respond_error(contract::failure_text("cannot cancel the credentials"));
		}
	};
}

fn void? cancel_credentials(network::Network* service, ipc::Call* call) @private
{
	String token               = params::param_string(call.params, "token")!;
	ulong request              = parse_token(token)!;
	network::SettleOp*? result = service.cancel_credentials(request);
	if (catch err = result) return refused(err, "cannot cancel the credentials")~;
	defer result.release();
	await_settle(result, "failed to cancel the credentials", "no pending prompt has this token")!;
	wire::respond_success(call, "credentials cancelled")!;
}