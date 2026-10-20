<* The `bluetooth` entry of the registry: open adapter, commands and `Spec`. *>
module bleu::registry::svc_bluetooth;
import bleu::bluetooth, bleu::registry, bleu::registry::live, bleu::json, bleu::registry::tap;

<* Open the Bluetooth service. Its root and bus address options point tests at fakes. *>
fn void*? open(Allocator allocator, registry::OpenOptions options)
{
	bluetooth::Options opened = { .root = options.root };
	bluetooth::Bluetooth* service = bluetooth::open(allocator, opened)!;
	return (void*)service;
}

<* Wait for a task and write the success object. *>
fn void? finish(registry::Request* request, bluetooth::Task task) @private
{
	defer task.release();
	registry::await{bluetooth::Done}(task, request.timeout)!;
	return registry::write_ok(request.out);
}

<* `bluetooth.power {adapter, on}`: power an adapter on or off. *>
fn void? power(registry::Request* request)
{
	bluetooth::Bluetooth* service = (bluetooth::Bluetooth*)request.handle;
	String adapter = request.params.string("adapter")!;
	bool on = request.params.boolean("on")!;
	return finish(request, service.set_powered(adapter, on)!);
}

<* `bluetooth.discovery {adapter, on}`: start or stop device discovery. *>
fn void? discovery(registry::Request* request)
{
	bluetooth::Bluetooth* service = (bluetooth::Bluetooth*)request.handle;
	String adapter = request.params.string("adapter")!;
	bool on = request.params.boolean("on")!;
	if (on) return finish(request, service.start_discovery(adapter)!);
	return finish(request, service.stop_discovery(adapter)!);
}

<* `bluetooth.pair {device}`: start pairing with a device. *>
fn void? pair(registry::Request* request)
{
	bluetooth::Bluetooth* service = (bluetooth::Bluetooth*)request.handle;
	return finish(request, service.pair(request.params.string("device")!)!);
}

<* `bluetooth.connect {device}`: connect a paired device. *>
fn void? connect(registry::Request* request)
{
	bluetooth::Bluetooth* service = (bluetooth::Bluetooth*)request.handle;
	return finish(request, service.connect(request.params.string("device")!)!);
}

<* `bluetooth.disconnect {device}`: disconnect a device. *>
fn void? disconnect(registry::Request* request)
{
	bluetooth::Bluetooth* service = (bluetooth::Bluetooth*)request.handle;
	return finish(request, service.disconnect(request.params.string("device")!)!);
}

<* `bluetooth.remove {device}`: forget a device. *>
fn void? remove(registry::Request* request)
{
	bluetooth::Bluetooth* service = (bluetooth::Bluetooth*)request.handle;
	return finish(request, service.remove(request.params.string("device")!)!);
}

<*
 `bluetooth.pairing.reply {request, accept, secret?}`: answer a pairing prompt.
 The secret is a PIN or passkey, used only for this reply.
*>
fn void? pairing_reply(registry::Request* request)
{
	bluetooth::Bluetooth* service = (bluetooth::Bluetooth*)request.handle;
	long id = request.params.integer("request")!;
	bool accept = request.params.boolean("accept")!;
	String secret = registry::string_or(request.params, "secret", "")!;
	return finish(request, service.reply_pairing((ulong)id, accept, secret)!);
}

const registry::Command[8] COMMANDS = {
	{ .name = "bluetooth.power", .summary = "Power an adapter: {adapter, on}.", .run = &power },
	{ .name = "bluetooth.discovery", .summary = "Start or stop discovery: {adapter, on}.", .run = &discovery },
	{ .name = "bluetooth.pair", .summary = "Pair with a device: {device}.", .run = &pair },
	{ .name = "bluetooth.connect", .summary = "Connect a device: {device}.", .run = &connect },
	{ .name = "bluetooth.disconnect", .summary = "Disconnect a device: {device}.", .run = &disconnect },
	{ .name = "bluetooth.remove", .summary = "Forget a device: {device}.", .run = &remove },
	{ .name = "bluetooth.pairing.reply", .summary = "Answer a pairing prompt: {request, accept, secret?}.", .run = &pairing_reply },
	{ .name = "bluetooth.refresh", .summary = "Read the adapters and devices now.", .run = &refresh },
};

<* `bluetooth.refresh`: re-read the adapters and devices now. *>
fn void? refresh(registry::Request* request)
{
	bluetooth::Bluetooth* service = (bluetooth::Bluetooth*)request.handle;
	return finish(request, service.refresh()!);
}

const registry::Spec BLUETOOTH = {
	.name = "bluetooth",
	.summary = "Adapters, devices and pairing (BlueZ, IOBluetooth, Windows)",
	.open = &open,
	.close = &live::close{bluetooth::Bluetooth, bluetooth::State, bluetooth::Cap},
	.state = &live::state{bluetooth::Bluetooth, bluetooth::State, bluetooth::Cap},
	.state_after = &live::state_after{bluetooth::Bluetooth, bluetooth::State, bluetooth::Cap},
	.capabilities = &live::capabilities{bluetooth::Bluetooth, bluetooth::State, bluetooth::Cap},
	.backend = &live::backend{bluetooth::Bluetooth, bluetooth::State, bluetooth::Cap},
	.watch = &tap::watch{bluetooth::Bluetooth, bluetooth::State},
	.commands = COMMANDS[..],
};
