<* The `network` entry of the registry: open adapter, commands and `Spec`. *>
module bleu::registry::svc_network;
import bleu::network, bleu::registry, bleu::registry::live, bleu::json, bleu::registry::tap;

<* Open the network service. Its root and bus address options point tests at fakes. *>
fn void*? open(Allocator allocator, registry::OpenOptions options)
{
	network::Options opened = { .root = options.root };
	network::Network* service = network::open(allocator, opened)!;
	return (void*)service;
}

<* `network.scan`: ask the backend for a fresh list of access points. *>
fn void? scan(registry::Request* request)
{
	network::Network* service = (network::Network*)request.handle;
	network::SettleOp* operation = service.scan()!;
	defer operation.release();
	network::Settled outcome = registry::await{network::Settled}(operation, request.timeout)!;
	return registry::write_value(request.out, "outcome", outcome);
}

<*
 `network.connect {ssid, passphrase?, autoconnect?}`: join a network. The
 passphrase is only read from the request; it is never echoed back.
*>
fn void? connect(registry::Request* request)
{
	network::Network* service = (network::Network*)request.handle;
	String ssid = request.params.string("ssid")!;
	network::ConnectRequest connect = {
		.ssid = (char[])ssid,
		.passphrase = registry::string_or(request.params, "passphrase", "")!,
		.autoconnect = request.params.boolean("autoconnect") ?? true,
	};
	network::ConnectOp* operation = service.connect(connect)!;
	defer operation.release();
	network::Connected joined = registry::await{network::Connected}(operation, request.timeout)!;
	out_connected(request.out, joined)!;
	return;
}

<* Write `{"ok": true, "ssid": ..., "interface": ...}` for a finished join. *>
fn void? out_connected(json::JsonWriter* out, network::Connected joined) @private
{
	out.begin_object()!;
	out.key("ok")!;
	out.put_bool(true)!;
	out.key("ssid")!;
	out.put_string(joined.ssid.label)!;
	out.key("interface")!;
	out.put_string(joined.interface_name)!;
	return out.end_object();
}

<* `network.disconnect`: leave the current network. *>
fn void? disconnect(registry::Request* request)
{
	network::Network* service = (network::Network*)request.handle;
	network::SettleOp* operation = service.disconnect()!;
	defer operation.release();
	network::Settled outcome = registry::await{network::Settled}(operation, request.timeout)!;
	return registry::write_value(request.out, "outcome", outcome);
}

<* `network.forget {ssid}`: remove the saved profile of a network. *>
fn void? forget(registry::Request* request)
{
	network::Network* service = (network::Network*)request.handle;
	String ssid = request.params.string("ssid")!;
	network::SettleOp* operation = service.forget((char[])ssid)!;
	defer operation.release();
	network::Settled outcome = registry::await{network::Settled}(operation, request.timeout)!;
	return registry::write_value(request.out, "outcome", outcome);
}

<* `network.set_radio {enabled}`: turn the Wi-Fi radio on or off. *>
fn void? set_radio(registry::Request* request)
{
	network::Network* service = (network::Network*)request.handle;
	bool enabled = request.params.boolean("enabled")!;
	network::SettleOp* operation = service.set_radio(enabled)!;
	defer operation.release();
	network::Settled outcome = registry::await{network::Settled}(operation, request.timeout)!;
	return registry::write_value(request.out, "outcome", outcome);
}

<* `network.credentials.submit {request, secret}`: answer a request for a passphrase. *>
fn void? credentials_submit(registry::Request* request)
{
	network::Network* service = (network::Network*)request.handle;
	long id = request.params.integer("request")!;
	String secret = request.params.string("secret")!;
	network::SettleOp* operation = service.supply_credentials((ulong)id, secret)!;
	defer operation.release();
	network::Settled outcome = registry::await{network::Settled}(operation, request.timeout)!;
	return registry::write_value(request.out, "outcome", outcome);
}

<* `network.credentials.cancel {request}`: refuse a request for a passphrase. *>
fn void? credentials_cancel(registry::Request* request)
{
	network::Network* service = (network::Network*)request.handle;
	long id = request.params.integer("request")!;
	network::SettleOp* operation = service.cancel_credentials((ulong)id)!;
	defer operation.release();
	network::Settled outcome = registry::await{network::Settled}(operation, request.timeout)!;
	return registry::write_value(request.out, "outcome", outcome);
}

const registry::Command[7] COMMANDS = {
	{ .name = "network.scan", .summary = "Scan for Wi-Fi networks.", .run = &scan },
	{ .name = "network.connect", .summary = "Join a network: {ssid, passphrase?, autoconnect?}.", .run = &connect },
	{ .name = "network.disconnect", .summary = "Leave the current network.", .run = &disconnect },
	{ .name = "network.forget", .summary = "Remove a saved network: {ssid}.", .run = &forget },
	{ .name = "network.set_radio", .summary = "Turn the Wi-Fi radio on or off: {enabled}.", .run = &set_radio },
	{ .name = "network.credentials.submit", .summary = "Answer a passphrase request: {request, secret}.", .run = &credentials_submit },
	{ .name = "network.credentials.cancel", .summary = "Refuse a passphrase request: {request}.", .run = &credentials_cancel },
};

const registry::Spec NETWORK = {
	.name = "network",
	.summary = "Wi-Fi, Ethernet and connectivity (NetworkManager, iwd, CoreWLAN, WLAN API)",
	.open = &open,
	.close = &live::close{network::Network, network::State, network::Cap},
	.state = &live::state{network::Network, network::State, network::Cap},
	.state_after = &live::state_after{network::Network, network::State, network::Cap},
	.capabilities = &live::capabilities{network::Network, network::State, network::Cap},
	.backend = &live::backend{network::Network, network::State, network::Cap},
	.watch = &tap::watch{network::Network, network::State},
	.commands = COMMANDS[..],
};
