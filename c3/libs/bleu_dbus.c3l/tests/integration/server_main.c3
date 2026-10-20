// Live integration test, server side: this library's ObjectServer exports
// org.bleu.Test at /org/bleu/ServerTest on a private bus, owns the name, and
// serves whatever server_client.py and server_client.c3 call. Run by
// ../integration.sh, which sets DBUS_SESSION_BUS_ADDRESS. It prints READY once it
// owns the name, and exits 0 when the C3 client calls Quit.
module bleu::dbus::server_integration_test;
import bleu::error, bleu::dbus::connection, bleu::dbus::marshal, bleu::dbus::message, bleu::dbus::ownership, bleu::dbus::server, bleu::dbus::transport, bleu::dbus::value;
import std::io, std::time;

extern fn int pipe(int* fds);
extern fn sz write(int fd, void* buf, usz count);
extern fn sz read(int fd, void* buf, usz count);
extern fn int close(int fd);

const SERVICE_NAME = "org.bleu.ServerTest";
const OBJECT_PATH = "/org/bleu/ServerTest";
const TEST_INTERFACE = "org.bleu.Test";
const ITEM_INTERFACE = "org.bleu.Item";
const ERROR_NAMED = "org.bleu.ServerTest.Error.Named";

// Longest wait for the bus between two steps of the loop, in milliseconds.
const LOOP_WAIT_MS = 20;

// The state the handlers share.
struct Service
{
	uint count;
	ReplyToken pending;
	bool quit;
	ObjectServer* server;
	String[1] echo_in;
	String[1] echo_out;
	String[2] add_in;
	String[1] add_out;
	String[1] text_args;
	Method[11] methods;
	Property[2] properties;
	Signal[1] signals;
	Interface[1] interfaces;
	Method[1] item_methods;
	Property[1] item_properties;
	Interface[1] item_interfaces;
}

Service service;

fn void? echo(void* context, Call* call)
{
	Reader r = call.reader()!;
	String text = r.read_string()!;
	Value[] out = { value::str(tmem, text)! };
	return call.reply(out);
}

fn void? add(void* context, Call* call)
{
	Reader r = call.reader()!;
	uint a = r.read_u32()!;
	uint b = r.read_u32()!;
	Value[] out = { value::u32(a + b) };
	return call.reply(out);
}

fn void? fail(void* context, Call* call)
{
	return error::PERMISSION_DENIED~;
}

fn void? named(void* context, Call* call)
{
	return call.reply_error(ERROR_NAMED, "the named failure");
}

// Keeps the call open; `complete` answers it.
fn void? defer_it(void* context, Call* call)
{
	service.pending = call.defer_reply()!;
}

// Answers the deferred call with the text it was given.
fn void? complete(void* context, Call* call)
{
	Reader r = call.reader()!;
	String text = r.read_string()!;
	Value[] out = { value::str(tmem, text)! };
	call.server.reply(service.pending, out)!;
	return call.reply({});
}

// Emits the Notice signal with the text it was given.
fn void? emit(void* context, Call* call)
{
	Reader r = call.reader()!;
	String text = r.read_string()!;
	Value[] body = { value::str(tmem, text)! };
	call.server.emit_signal(OBJECT_PATH, TEST_INTERFACE, "Notice", body)!;
	return call.reply({});
}

// Announces Label as changed without its value.
fn void? touch(void* context, Call* call)
{
	String[1] changed = { "Label" };
	call.server.emit_properties_changed(OBJECT_PATH, TEST_INTERFACE, changed[..])!;
	return call.reply({});
}

// Returns a pipe whose read end carries "from-server", passed as a descriptor.
fn void? make_fd(void* context, Call* call)
{
	int[2] fds;
	if (pipe(&fds[0]) != 0) return error::BACKEND_FAILURE~;
	write(fds[1], "from-server", 11);
	close(fds[1]);
	int[] passed = fds[0:1];
	Value[] out = { value::unix_fd(0) };
	return call.reply(out, passed);
}

// Reads what the caller sent as a descriptor, and returns it as a string.
fn void? read_fd(void* context, Call* call)
{
	Reader r = call.reader()!;
	uint index = r.read_unix_fd()!;
	int fd = call.message.unix_fd(index)!;
	char[64] buffer;
	sz n = read(fd, &buffer, 64);
	if (n < 0) return error::BACKEND_FAILURE~;
	Value[] out = { value::str(tmem, (String)buffer[0:(usz)n])! };
	return call.reply(out);
}

fn void? quit(void* context, Call* call)
{
	service.quit = true;
	return call.reply({});
}

// Exports a child Item under the object, which the ObjectManager root announces.
fn void? add_child(void* context, Call* call)
{
	Reader r = call.reader()!;
	String name = r.read_string()!;
	String path = string::tformat("%s/%s", OBJECT_PATH, name);
	call.server.export(path, service.item_interfaces[..])!;
	return call.reply({});
}

fn void? remove_child(void* context, Call* call)
{
	Reader r = call.reader()!;
	String name = r.read_string()!;
	call.server.unexport(string::tformat("%s/%s", OBJECT_PATH, name))!;
	return call.reply({});
}

fn void? item_ping(void* context, Call* call)
{
	return call.reply({});
}

fn Value? get_count(void* context, String path, Allocator allocator)
{
	return value::u32(service.count);
}

fn void? set_count(void* context, String path, Value v)
{
	service.count = v.as_u32() ?? 0;
}

fn Value? get_label(void* context, String path, Allocator allocator)
{
	return value::str(allocator, "label");
}

fn Value? get_kind(void* context, String path, Allocator allocator)
{
	return value::str(allocator, "item");
}

// Fills the service description. The tables live in `service`, so they outlive the export.
fn void Service.describe(&self)
{
	self.echo_in  = { "text" };
	self.echo_out = { "text" };
	self.add_in   = { "a", "b" };
	self.add_out  = { "sum" };
	self.text_args = { "text" };
	self.methods = {
		{ .name = "Echo", .in_signature = "s", .out_signature = "s", .in_names = self.echo_in[..], .out_names = self.echo_out[..], .handler = &echo },
		{ .name = "Add", .in_signature = "uu", .out_signature = "u", .in_names = self.add_in[..], .out_names = self.add_out[..], .handler = &add },
		{ .name = "Fail", .handler = &fail },
		{ .name = "Named", .handler = &named },
		{ .name = "Defer", .in_signature = "s", .out_signature = "s", .handler = &defer_it },
		{ .name = "Complete", .in_signature = "s", .in_names = self.text_args[..], .handler = &complete },
		{ .name = "Emit", .in_signature = "s", .in_names = self.text_args[..], .handler = &emit },
		{ .name = "Touch", .handler = &touch },
		{ .name = "MakeFd", .out_signature = "h", .handler = &make_fd },
		{ .name = "ReadFd", .in_signature = "h", .out_signature = "s", .handler = &read_fd },
		{ .name = "Quit", .handler = &quit },
	};
	self.properties = {
		{ .name = "Count", .signature = "u", .access = READ_WRITE, .changes = EMITS_CHANGED, .get = &get_count, .set = &set_count },
		{ .name = "Label", .signature = "s", .access = READ, .changes = INVALIDATES, .get = &get_label },
	};
	self.signals = { { .name = "Notice", .signature = "s", .arg_names = self.text_args[..] } };
	self.interfaces[0] = { .name = TEST_INTERFACE, .methods = self.methods[..], .properties = self.properties[..], .signals = self.signals[..] };
	self.item_methods = { { .name = "Ping", .handler = &item_ping } };
	self.item_properties = { { .name = "Kind", .signature = "s", .access = READ, .changes = CONST, .get = &get_kind } };
	self.item_interfaces[0] = { .name = ITEM_INTERFACE, .methods = self.item_methods[..], .properties = self.item_properties[..] };
}

fn void on_acquired(void* context, String name)
{
	io::printfn("ACQUIRED %s", name);
	io::printn("READY");
}

fn void on_lost(void* context, String name)
{
	io::printfn("LOST %s", name);
}

fn int main()
{
	Connection bus;
	bus.init(mem);
	defer bus.free();
	if (catch err = bus.open_session())
	{
		io::printfn("FAIL open %s: %s", err, error::last().message());
		return 1;
	}
	ObjectServer server;
	server.init(mem);
	defer server.free();
	service.describe();
	service.server = &server;
	server.export(OBJECT_PATH, service.interfaces[..])!!;
	server.make_object_manager(OBJECT_PATH)!!;
	server.attach(&bus);
	OwnedName* owned = bus.own_name(SERVICE_NAME, 0, &on_acquired, &on_lost, null)!!;
	defer owned.release()!!;
	while (!service.quit)
	{
		if (catch err = bus.process())
		{
			io::printfn("FAIL process %s", err);
			return 1;
		}
		transport::wait(bus.fd()!!, true, bus.has_pending_output(), time::ms(LOOP_WAIT_MS));
	}
	// The reply to Quit is still queued: send it before the connection closes.
	for (int i = 0; i < 50 && bus.has_pending_output(); i++)
	{
		if (catch bus.process()) break;
		transport::wait(bus.fd()!!, false, true, time::ms(LOOP_WAIT_MS));
	}
	io::printn("QUIT");
	return 0;
}
