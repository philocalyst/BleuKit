<*
 The DMS `network` methods that have no Bleu equivalent. Each answers
 `not supported: <why>` (docs/DMSD.md, section "network"), so a shell can tell that
 the method exists and cannot work here, instead of getting `unknown method`.

 The table is the whole list: `register_unsupported` registers exactly these names.
 Source of the names: `core/internal/server/network/handlers.go:15-95` at 8be08999.
*>
module dmsd::network_unsupported;
import bleu::ipc;

<* One method that is answered with its reason. *>
struct Unsupported
{
	String method;
	String message;
}

// Bleu has no ethernet profiles or wired configuration API, so no wired method can act.
// Cellular: no ModemManager backend. VPN and hotspot: not in bleu_network v1 (docs/research/network.md section 6).
// The QR codes need a saved passphrase, which Bleu never reads, and bleu has no QR encoder.
const Unsupported[32] UNSUPPORTED = {
	{ .method = "network.ethernet.connect", .message = "not supported: bleu_network cannot activate a wired connection" },
	{ .method = "network.ethernet.connect.config", .message = "not supported: bleu_network cannot activate a wired connection profile" },
	{ .method = "network.ethernet.disconnect", .message = "not supported: bleu_network cannot disconnect a wired interface" },
	{ .method = "network.ethernet.info", .message = "not supported: bleu_network does not report wired profiles, addresses or DNS" },
	{ .method = "network.cellular.connect", .message = "not supported: bleu_network has no cellular service" },
	{ .method = "network.cellular.connect.config", .message = "not supported: bleu_network has no cellular service" },
	{ .method = "network.cellular.disconnect", .message = "not supported: bleu_network has no cellular service" },
	{ .method = "network.cellular.toggle", .message = "not supported: bleu_network has no cellular service" },
	{ .method = "network.cellular.enable", .message = "not supported: bleu_network has no cellular service" },
	{ .method = "network.cellular.disable", .message = "not supported: bleu_network has no cellular service" },
	{ .method = "network.preference.set", .message = "not supported: bleu_network does not choose the route; the OS does" },
	{ .method = "network.qrcode", .message = "not supported: bleu_network does not read saved passphrases, so it cannot make a QR code" },
	{ .method = "network.qrcode-content", .message = "not supported: bleu_network does not read saved passphrases" },
	{ .method = "network.generate-qrcode", .message = "not supported: bleu_network has no QR code encoder" },
	{ .method = "network.delete-qrcode", .message = "not supported: bleu_network writes no QR code files" },
	{ .method = "network.subscribe", .message = "not supported: a streaming method cannot reply in this protocol; subscribe with services [\"network\", \"network.credentials\"] instead" },
	{ .method = "network.vpn.profiles", .message = "not supported: bleu_network has no VPN service" },
	{ .method = "network.vpn.active", .message = "not supported: bleu_network has no VPN service" },
	{ .method = "network.vpn.connect", .message = "not supported: bleu_network has no VPN service" },
	{ .method = "network.vpn.disconnect", .message = "not supported: bleu_network has no VPN service" },
	{ .method = "network.vpn.disconnectAll", .message = "not supported: bleu_network has no VPN service" },
	{ .method = "network.vpn.clearCredentials", .message = "not supported: bleu_network has no VPN service" },
	{ .method = "network.vpn.plugins", .message = "not supported: bleu_network has no VPN service" },
	{ .method = "network.vpn.import", .message = "not supported: bleu_network has no VPN service" },
	{ .method = "network.vpn.getConfig", .message = "not supported: bleu_network has no VPN service" },
	{ .method = "network.vpn.updateConfig", .message = "not supported: bleu_network has no VPN service" },
	{ .method = "network.vpn.delete", .message = "not supported: bleu_network has no VPN service" },
	{ .method = "network.vpn.setCredentials", .message = "not supported: bleu_network has no VPN service" },
	{ .method = "network.hotspot.configure", .message = "not supported: bleu_network has no hotspot" },
	{ .method = "network.hotspot.start", .message = "not supported: bleu_network has no hotspot" },
	{ .method = "network.hotspot.stop", .message = "not supported: bleu_network has no hotspot" },
	{ .method = "network.hotspot.getSecrets", .message = "not supported: bleu_network has no hotspot" },
};

<* Answer `call` with the reason of its method. Registered only for the names of `UNSUPPORTED`. *>
fn void handle_unsupported(void* context, ipc::Call* call)
{
	foreach (&entry : UNSUPPORTED)
	{
		if (entry.method == call.method)
		{
			call.respond_error(entry.message);
			return;
		}
	}
}

<* Register every method of `UNSUPPORTED` on `server`. Called before the server starts. *>
fn void register_unsupported(ipc::Server* server)
{
	foreach (&entry : UNSUPPORTED)
	{
		server.register_method(entry.method, &handle_unsupported, null)!!;
	}
}
