<* The `tray` entry of the registry: open adapter, commands and `Spec`. *>
module bleu::registry::svc_tray;
import bleu::tray, bleu::registry, bleu::registry::live, bleu::json, bleu::registry::tap;

<* Open the tray service. Its root and bus options are not used; the bus is the session bus. *>
fn void*? open(Allocator allocator, registry::OpenOptions options)
{
	tray::Tray* service = tray::open(allocator)!;
	return (void*)service;
}

<* Wait for a tray command and write the success object. *>
fn void? finish(registry::Request* request, tray::CommandOp* operation) @private
{
	defer operation.release();
	registry::await{bool}(operation, request.timeout)!;
	return registry::write_ok(request.out);
}

<* `tray.activate {item, x?, y?}`: the item's primary action, at a screen point. *>
fn void? activate(registry::Request* request)
{
	tray::Tray* service = (tray::Tray*)request.handle;
	String item = request.params.string("item")!;
	int x = (int)request.params.int_or("x", 0)!;
	int y = (int)request.params.int_or("y", 0)!;
	return finish(request, service.activate(item, x, y)!);
}

<* `tray.secondary_activate {item, x?, y?}`: the item's secondary action (middle click). *>
fn void? secondary_activate(registry::Request* request)
{
	tray::Tray* service = (tray::Tray*)request.handle;
	String item = request.params.string("item")!;
	int x = (int)request.params.int_or("x", 0)!;
	int y = (int)request.params.int_or("y", 0)!;
	return finish(request, service.secondary_activate(item, x, y)!);
}

<* `tray.context_menu {item, x?, y?}`: open the item's menu at a screen point. *>
fn void? context_menu(registry::Request* request)
{
	tray::Tray* service = (tray::Tray*)request.handle;
	String item = request.params.string("item")!;
	int x = (int)request.params.int_or("x", 0)!;
	int y = (int)request.params.int_or("y", 0)!;
	return finish(request, service.context_menu(item, x, y)!);
}

<* `tray.scroll {item, delta, horizontal?}`: scroll over the item. *>
fn void? scroll(registry::Request* request)
{
	tray::Tray* service = (tray::Tray*)request.handle;
	String item = request.params.string("item")!;
	int delta = (int)request.params.integer("delta")!;
	bool horizontal = request.params.boolean("horizontal") ?? false;
	return finish(request, service.scroll(item, delta, horizontal)!);
}

const registry::Command[4] COMMANDS = {
	{ .name = "tray.activate", .summary = "Primary action of an item: {item, x?, y?}.", .run = &activate },
	{ .name = "tray.secondary_activate", .summary = "Secondary action of an item: {item, x?, y?}.", .run = &secondary_activate },
	{ .name = "tray.context_menu", .summary = "Open an item's menu: {item, x?, y?}.", .run = &context_menu },
	{ .name = "tray.scroll", .summary = "Scroll over an item: {item, delta, horizontal?}.", .run = &scroll },
};

const registry::Spec TRAY = {
	.name = "tray",
	.summary = "Status notifier items: the system tray (SNI, Win32 notification area)",
	.open = &open,
	.close = &live::close{tray::Tray, tray::State, tray::Cap},
	.state = &live::state{tray::Tray, tray::State, tray::Cap},
	.state_after = &live::state_after{tray::Tray, tray::State, tray::Cap},
	.capabilities = &live::capabilities{tray::Tray, tray::State, tray::Cap},
	.backend = &live::backend{tray::Tray, tray::State, tray::Cap},
	.watch = &tap::watch{tray::Tray, tray::State},
	.commands = COMMANDS[..],
};
