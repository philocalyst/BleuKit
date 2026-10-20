<*
 The D-Bus face of the server: the interface description and the four methods of
 org.freedesktop.Notifications. Each handler runs on the worker, inside the bus
 connection's `process`, so it may touch the store directly.
*>
module bleu::notify::fdo @feat(LINUX);
import std::time, bleu::error, bleu::dbus::marshal, bleu::dbus::server, bleu::dbus::value, bleu::notify, bleu::notify::store, bleu::notify::wire;

// The error name a CloseNotification for an unknown id answers with. The spec asks for an error with no text.
const String ERROR_NOT_FOUND = "org.freedesktop.Notifications.Error.NotFound";

<*
 The tables the export refers to. `ObjectServer.export` keeps references, so this
 lives on the worker's stack for as long as the object is exported.
*>
struct Description
{
	server::Method[4] methods;
	server::Signal[2] signals;
	String[8] notify_in;
	String[1] id_in;
	String[1] id_out;
	String[2] closed_names;
	String[2] action_names;
	server::Interface[1] interfaces;
}

<* Fill the description: the methods answer with `session`, the signals are the two the spec defines. *>
fn void describe(Description* d, Session* session)
{
	d.notify_in = { "app_name", "replaces_id", "app_icon", "summary", "body", "actions", "hints", "expire_timeout" };
	d.id_in = { "id" };
	d.id_out = { "id" };
	d.closed_names = { "id", "reason" };
	d.action_names = { "id", "action_key" };
	d.methods = {
		{
			.name = "Notify",
			.in_signature = "susssasa{sv}i",
			.out_signature = "u",
			.in_names = d.notify_in[..],
			.out_names = d.id_out[..],
			.handler = &notify_call,
			.context = session,
		},
		{
			.name = "CloseNotification",
			.in_signature = "u",
			.in_names = d.id_in[..],
			.handler = &close_call,
			.context = session,
		},
		{ .name = "GetCapabilities", .out_signature = "as", .handler = &capabilities_call, .context = session },
		{ .name = "GetServerInformation", .out_signature = "ssss", .handler = &information_call, .context = session },
	};
	d.signals = {
		{ .name = "NotificationClosed", .signature = "uu", .arg_names = d.closed_names[..] },
		{ .name = "ActionInvoked", .signature = "us", .arg_names = d.action_names[..] },
	};
	d.interfaces[0] = { .name = INTERFACE, .methods = d.methods[..], .signals = d.signals[..] };
}

// Notify: read the arguments into a new entry, post it to the store, announce what that changed, reply with the id.
fn void? notify_call(void* context, server::Call* call)
{
	Session* session = (Session*)context;
	store::Entry* e = session.store.new_entry();
	marshal::Reader r = call.reader()!;
	if (catch err = wire::read_notify(&r, (Allocator)&e.arena, &e.incoming))
	{
		store::release_entry(e);
		return err~;
	}
	store::Posted posted = session.store.post(e, time::now());
	cancel(session, posted.id);
	if (posted.evicted)
	{
		cancel(session, posted.evicted_id);
		announce_closed(session, posted.evicted_id, notify::CloseReason.UNDEFINED);
	}
	if (posted.timeout.has_value) session.timers.schedule((usz)posted.id, posted.timeout.value)!!;
	if (posted.shown) emit(session, { .kind = notify::EventKind.POSTED, .id = posted.id, .replaced = posted.replaced });
	publish(session);
	Value[] out = { value::u32(posted.id) };
	return call.reply(out);
}

// CloseNotification(id): close it, announce NotificationClosed(id, CLOSED_BY_CALL); an unknown id is an error.
fn void? close_call(void* context, server::Call* call)
{
	Session* session = (Session*)context;
	marshal::Reader r = call.reader()!;
	notify::NoteId id = r.read_u32()!;
	if (!session.store.close(id)) return call.reply_error(ERROR_NOT_FOUND, "");
	cancel(session, id);
	announce_closed(session, id, notify::CloseReason.CLOSED_BY_CALL);
	publish(session);
	return call.reply({ });
}

fn void? capabilities_call(void* context, server::Call* call)
{
	@pool()
	{
		Value[] names = { value::str(tmem, "actions")!, value::str(tmem, "body")!, value::str(tmem, "body-markup")! };
		Value[] out = { value::array(tmem, "s", names)! };
		return call.reply(out);
	};
}

fn void? information_call(void* context, server::Call* call)
{
	@pool()
	{
		Value[] out = {
			value::str(tmem, SERVER_NAME)!,
			value::str(tmem, SERVER_VENDOR)!,
			value::str(tmem, SERVER_VERSION)!,
			value::str(tmem, SPEC_VERSION)!,
		};
		return call.reply(out);
	};
}
