<* The `notify` entry of the registry: open adapter, commands and `Spec`. *>
module bleu::registry::svc_notify;
import bleu::notify, bleu::registry, bleu::registry::live, bleu::json, bleu::operation, bleu::registry::tap;

<* Open the notification service with its default backend. *>
fn void*? open(Allocator allocator, registry::OpenOptions options)
{
	notify::Options opened = {};
	notify::Notify* service = notify::open(allocator, opened)!;
	return (void*)service;
}

<*
 `notify.close {id, reason?}`: close a notification. `reason` is the code in the
 specification (1 expired, 2 dismissed, 3 closed by a call, 4 undefined); default 2.
*>
fn void? close(registry::Request* request)
{
	notify::Notify* service = (notify::Notify*)request.handle;
	notify::NoteId id = (notify::NoteId)request.params.integer("id")!;
	uint code = (uint)request.params.int_or("reason", (long)(uint)notify::CloseReason.DISMISSED)!;
	notify::CloseReason reason = (notify::CloseReason)code;
	Operation{bool}* operation = service.close_notification(id, reason)!;
	defer operation.release();
	registry::await{bool}(operation, request.timeout)!;
	return registry::write_ok(request.out);
}

<* `notify.invoke {id, key}`: invoke one of a notification's actions. *>
fn void? invoke(registry::Request* request)
{
	notify::Notify* service = (notify::Notify*)request.handle;
	notify::NoteId id = (notify::NoteId)request.params.integer("id")!;
	String key = request.params.string("key")!;
	Operation{bool}* operation = service.invoke_action(id, key)!;
	defer operation.release();
	registry::await{bool}(operation, request.timeout)!;
	return registry::write_ok(request.out);
}

<* `notify.dnd {on}`: turn do-not-disturb on or off. *>
fn void? dnd(registry::Request* request)
{
	notify::Notify* service = (notify::Notify*)request.handle;
	service.set_do_not_disturb(request.params.boolean("on")!)!;
	return registry::write_ok(request.out);
}

<* `notify.clear_history`: forget the notifications that are no longer shown. *>
fn void? clear_history(registry::Request* request)
{
	notify::Notify* service = (notify::Notify*)request.handle;
	service.clear_history()!;
	return registry::write_ok(request.out);
}

const registry::Command[4] COMMANDS = {
	{ .name = "notify.close", .summary = "Close a notification: {id, reason?}.", .run = &close },
	{ .name = "notify.invoke", .summary = "Invoke an action: {id, key}.", .run = &invoke },
	{ .name = "notify.dnd", .summary = "Turn do-not-disturb on or off: {on}.", .run = &dnd },
	{ .name = "notify.clear_history", .summary = "Forget closed notifications.", .run = &clear_history },
};

const registry::Spec NOTIFY = {
	.name = "notify",
	.summary = "Notification server, history and do-not-disturb (freedesktop)",
	.open = &open,
	.close = &live::close{notify::Notify, notify::State, notify::Cap},
	.state = &live::state{notify::Notify, notify::State, notify::Cap},
	.state_after = &live::state_after{notify::Notify, notify::State, notify::Cap},
	.capabilities = &live::capabilities{notify::Notify, notify::State, notify::Cap},
	.backend = &live::backend{notify::Notify, notify::State, notify::Cap},
	.watch = &tap::watch{notify::Notify, notify::State},
	.commands = COMMANDS[..],
};
