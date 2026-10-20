// Worked example: the server side of org.freedesktop.Notifications, written
// against bleu_dbus's object export. It is not part of the library: tests/integration.sh
// compiles it and runs notifications_client.py against it on a private bus.
// 
// It shows the shape a notification daemon needs: a name owned at start-up, one
// interface with the four specified methods and their signatures, the two
// signals the specification defines, and a method that stands in for the user
// interface (SimulateAction), which in a real daemon is not a D-Bus method at all.
module bleu::dbus::notifications_sketch;
import bleu::error, bleu::dbus::connection, bleu::dbus::marshal, bleu::dbus::ownership, bleu::dbus::server, bleu::dbus::transport, bleu::dbus::value;
import std::io, std::time;

const SERVICE_NAME = "org.freedesktop.Notifications";
const OBJECT_PATH  = "/org/freedesktop/Notifications";
const INTERFACE    = "org.freedesktop.Notifications";

// The reason of NotificationClosed when CloseNotification closed the notification.
const REASON_CLOSED_BY_CALL = 3;

// Longest number of notifications held open at once.
const MAX_OPEN = 16;

// Waiting between two steps of the loop, in milliseconds.
const LOOP_WAIT_MS = 20;

// The daemon's state: the last identifier handed out, and the open notifications.
struct Daemon
{
	uint last_id;
	uint[MAX_OPEN] open;
	int open_count;
	bool running;
	String[1] close_args;
	String[2] closed_args;
	String[2] action_args;
	String[2] simulate_args;
	Method[5] methods;
	Signal[2] signals;
	Interface[1] interfaces;
}

Daemon daemon;

fn void? get_server_information(void* context, Call* call)
{
	Value[] out = {
		value::str(tmem, "bleu")!,
		value::str(tmem, "Bleu")!,
		value::str(tmem, "0.1")!,
		value::str(tmem, "1.2")!,
	};
	return call.reply(out);
}

fn void? get_capabilities(void* context, Call* call)
{
	Value[] capabilities = { value::str(tmem, "body")!, value::str(tmem, "actions")! };
	Value[] out          = { value::array(tmem, "s", capabilities)! };
	return call.reply(out);
}

// Notify(app, replaces_id, icon, summary, body, actions, hints, timeout) -> id.
// The daemon only remembers the notification; a real one would show it here.
fn void? notify(void* context, Call* call)
{
	Reader r = call.reader()!;
	r.read_string()!;
	uint replaces_id = r.read_u32()!;
	r.read_string()!;
	r.read_string()!;
	r.read_string()!;
	Value actions = r.read_value(tmem)!;
	r.read_value(tmem)!;
	r.read_i32()!;
	uint id = replaces_id != 0 ? replaces_id : ++daemon.last_id;
	remember(id);
	Value[] out = { value::u32(id) };
	io::printfn("NOTIFY %d with %d actions", id, actions.count());
	return call.reply(out);
}

// CloseNotification(id): the daemon closes it and announces why. An unknown id is ignored.
fn void? close_notification(void* context, Call* call)
{
	Reader r = call.reader()!;
	uint id  = r.read_u32()!;
	if (forget(id))
	{
		call.server.emit_signal(
			OBJECT_PATH,
			INTERFACE,
			"NotificationClosed",
			{ value::u32(id), value::u32(REASON_CLOSED_BY_CALL) }
		)!;
	}
	return call.reply({ });
}

// The user chose an action on a notification. Not part of the specification: the sketch's stand-in for the UI.
fn void? simulate_action(void* context, Call* call)
{
	Reader r   = call.reader()!;
	uint id    = r.read_u32()!;
	String key = r.read_string()!;
	call.server.emit_signal(OBJECT_PATH, INTERFACE, "ActionInvoked", { value::u32(id), value::str(tmem, key)! })!;
	return call.reply({ });
}

// Keeps the identifier of a notification that is now open, once.
fn void remember(uint id)
{
	for (int k = 0; k < daemon.open_count; k++)
	{
		if (daemon.open[k] == id) return;
	}
	if (daemon.open_count == MAX_OPEN) return;
	daemon.open[daemon.open_count++] = id;
}

// Removes the notification with `id`, and reports whether it was open.
fn bool forget(uint id)
{
	for (int k = 0; k < daemon.open_count; k++)
	{
		if (daemon.open[k] != id) continue;
		for (int j = k; j + 1 < daemon.open_count; j++) daemon.open[j] = daemon.open[j + 1];
		daemon.open_count--;
		return true;
	}
	return false;
}

// Fills the interface description. The name tables are fields, so the slices stay valid.
fn void describe()
{
	daemon.close_args = { "id" };
	daemon.closed_args = { "id", "reason" };
	daemon.action_args = { "id", "action_key" };
	daemon.simulate_args = { "id", "action_key" };
	daemon.methods = {
		{ .name = "GetServerInformation", .out_signature = "ssss", .handler = &get_server_information },
		{ .name = "GetCapabilities", .out_signature = "as", .handler = &get_capabilities },
		{ .name = "Notify", .in_signature = "susssasa{sv}i", .out_signature = "u", .handler = &notify },
		{
			.name = "CloseNotification",
			.in_signature = "u",
			.in_names = daemon.close_args[..],
			.handler = &close_notification
		},
		{
			.name = "SimulateAction",
			.in_signature = "us",
			.in_names = daemon.simulate_args[..],
			.handler = &simulate_action
		},
	};
	daemon.signals = {
		{ .name = "NotificationClosed", .signature = "uu", .arg_names = daemon.closed_args[..] },
		{ .name = "ActionInvoked", .signature = "us", .arg_names = daemon.action_args[..] },
	};
	daemon.interfaces[0] = { .name = INTERFACE, .methods = daemon.methods[..], .signals = daemon.signals[..] };
}

fn void on_acquired(void* context, String name)
{
	io::printfn("READY %s", name);
}

fn int main()
{
	Connection bus;
	bus.init(mem);
	defer bus.free();
	if (catch err = bus.open_session())
	{
		io::printfn("FAIL open %s", err);
		return 1;
	}
	ObjectServer server;
	server.init(mem);
	defer server.free();
	describe();
	server.export(OBJECT_PATH, daemon.interfaces[..])!!;
	server.attach(&bus);
	OwnedName* owned = bus.own_name(SERVICE_NAME, 0, &on_acquired, null, null)!!;
	defer owned.release()!!;
	daemon.running = true;
	while (daemon.running)
	{
		if (catch err = bus.process())
		{
			io::printfn("FAIL process %s", err);
			return 1;
		}
		transport::wait(bus.fd()!!, true, bus.has_pending_output(), time::ms(LOOP_WAIT_MS));
	}
	return 0;
}