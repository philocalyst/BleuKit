// Unit tests for bleu::dbus::server: routing, argument checks, the standard
// interfaces, deferred replies, error names, validation and introspection. Each
// test drives an ObjectServer through a sink that records what it sends, so no
// bus is needed. The bus itself is exercised by tests/integration.sh.
module bleu::dbus::server_test;
import bleu::error, bleu::dbus::server, bleu::dbus::message, bleu::dbus::marshal, bleu::dbus::value, bleu::dbus::errors, bleu::dbus::testing;

const TEST_PATH = "/org/bleu/test";
const TEST_INTERFACE = "org.bleu.Test";
const ERROR_ACCESS_DENIED = "org.freedesktop.DBus.Error.AccessDenied";
const ERROR_CUSTOM = "org.bleu.Test.Error.Custom";

// What the sink saw: how many messages, and the last one's type, error name, body and signature.
struct Capture
{
	int messages;
	MessageType type;
	DString error_name;
	DString body;
	DString signature;
}

fn void Capture.start(&self)
{
	self.error_name.init(mem);
	self.body.init(mem);
	self.signature.init(mem);
}

fn void Capture.stop(&self)
{
	self.error_name.free();
	self.body.free();
	self.signature.free();
}

// The sink: records the message; the server releases it after this returns.
fn void? record(void* context, Message* m)
{
	Capture* cap = (Capture*)context;
	cap.messages++;
	cap.type = m.type;
	cap.error_name.clear();
	cap.error_name.append_string(m.error_name);
	cap.body.clear();
	cap.body.append_string(m.body_bytes());
	cap.signature.clear();
	cap.signature.append_string(m.has_writer ? m.writer.signature : m.signature);
}

// The state the test handlers read and write.
struct TestState
{
	uint count;
	ReplyToken token;
}

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
	return call.reply_error(ERROR_CUSTOM, "a named failure");
}

// Replies with a string where the method promises a uint: the server must refuse to send it.
fn void? broken(void* context, Call* call)
{
	Value[] out = { value::str(tmem, "not a number")! };
	return call.reply(out);
}

// Returns without answering a method that has a result: the server answers for it.
fn void? silent(void* context, Call* call)
{
	return;
}

fn void? defer_it(void* context, Call* call)
{
	TestState* state = (TestState*)context;
	state.token = call.defer_reply()!;
}

fn Value? get_count(void* context, String path, Allocator allocator)
{
	TestState* state = (TestState*)context;
	return value::u32(state.count);
}

fn void? set_count(void* context, String path, Value v)
{
	TestState* state = (TestState*)context;
	state.count = v.as_u32() ?? 0;
}

fn Value? get_label(void* context, String path, Allocator allocator)
{
	return value::str(allocator, "fixed");
}

fn void? set_secret(void* context, String path, Value v)
{
	TestState* state = (TestState*)context;
	state.count = 77;
}

// A server with the test interface exported at TEST_PATH, and a recording sink.
struct Rig
{
	ObjectServer server;
	Capture cap;
	TestState state;
	String[1] echo_in;
	String[1] echo_out;
	String[2] add_in;
	String[1] add_out;
	String[1] notice_args;
	Method[7] methods;
	Property[3] properties;
	Signal[1] signals;
	Interface[1] interfaces;
}

fn void Rig.start(&self)
{
	self.server.init(mem);
	self.cap.start();
	self.server.use_sink(&record, &self.cap);
	self.echo_in  = { "text" };
	self.echo_out = { "text" };
	self.add_in   = { "a", "b" };
	self.add_out  = { "sum" };
	self.notice_args = { "text" };
	self.methods = {
		{ .name = "Echo", .in_signature = "s", .out_signature = "s", .in_names = self.echo_in[..], .out_names = self.echo_out[..], .handler = &echo },
		{ .name = "Add", .in_signature = "uu", .out_signature = "u", .in_names = self.add_in[..], .out_names = self.add_out[..], .handler = &add },
		{ .name = "Fail", .handler = &fail },
		{ .name = "Named", .handler = &named },
		{ .name = "Broken", .out_signature = "u", .handler = &broken },
		{ .name = "Silent", .out_signature = "u", .handler = &silent },
		{ .name = "Defer", .in_signature = "s", .out_signature = "s", .handler = &defer_it, .context = &self.state },
	};
	self.properties = {
		{ .name = "Count", .signature = "u", .access = READ_WRITE, .changes = EMITS_CHANGED, .get = &get_count, .set = &set_count, .context = &self.state },
		{ .name = "Label", .signature = "s", .access = READ, .changes = CONST, .get = &get_label },
		{ .name = "Secret", .signature = "s", .access = WRITE, .changes = NEVER, .set = &set_secret, .context = &self.state },
	};
	self.signals = { { .name = "Notice", .signature = "s", .arg_names = self.notice_args[..] } };
	self.interfaces[0] = { .name = TEST_INTERFACE, .methods = self.methods[..], .properties = self.properties[..], .signals = self.signals[..] };
}

fn void Rig.stop(&self)
{
	self.server.free();
	self.cap.stop();
}

// Exports the test interface at TEST_PATH.
fn void Rig.export_test(&self)
{
	self.server.export(TEST_PATH, self.interfaces[..])!!;
}

// Hands one METHOD_CALL to the server. `args` is the body, written for `sig`.
fn void deliver(ObjectServer* server, String path, String iface, String member, String sig, Value[] args, char flags = 0)
{
	Message* call = message::method_call(mem, "org.bleu.Test", path, iface, member)!!;
	defer call.release();
	call.serial = 7;
	call.flags  = flags;
	Writer* w = call.body_writer(sig)!!;
	foreach (v : args) w.append_value(v)!!;
	w.finish()!!;
	server.handle(call);
}

// Asserts that the last message was an ERROR named `name`.
fn void expect_error(Capture* cap, String name)
{
	assert(cap.type == ERROR, "an error reply was expected");
	assert(cap.error_name.str_view() == name, "wrong error name");
}

fn void introspection_describes_interfaces_and_children() @test
{
	Rig rig;
	rig.start();
	defer rig.stop();
	rig.export_test();
	@pool()
	{
		String xml = rig.server.introspection(TEST_PATH, tmem);
		assert(xml.contains("<interface name=\"org.bleu.Test\">"));
		assert(xml.contains("<method name=\"Echo\">"));
		assert(xml.contains("<arg name=\"text\" type=\"s\" direction=\"in\"/>"));
		assert(xml.contains("<arg name=\"sum\" type=\"u\" direction=\"out\"/>"));
		assert(xml.contains("<signal name=\"Notice\">"));
		assert(xml.contains("<property name=\"Count\" type=\"u\" access=\"readwrite\">"));
		assert(xml.contains("<property name=\"Label\" type=\"s\" access=\"read\">"));
		assert(xml.contains("value=\"const\""));
		assert(xml.contains("value=\"false\""));
		String root = rig.server.introspection("/org", tmem);
		assert(root.contains("<node name=\"bleu\"/>"));
		assert(!root.contains("<interface"));
		assert(rig.server.has_node("/org/bleu"));
		assert(!rig.server.has_node("/org/elsewhere"));
	};
}

fn void unknown_targets_are_named_and_mismatched_arguments_refused() @test
{
	Rig rig;
	rig.start();
	defer rig.stop();
	rig.export_test();
	@pool()
	{
		deliver(&rig.server, TEST_PATH, TEST_INTERFACE, "Echo", "u", { value::u32(1) });
		expect_error(&rig.cap, "org.freedesktop.DBus.Error.InvalidArgs");
		deliver(&rig.server, TEST_PATH, TEST_INTERFACE, "Nope", "", {});
		expect_error(&rig.cap, "org.freedesktop.DBus.Error.UnknownMethod");
		deliver(&rig.server, TEST_PATH, "org.bleu.Missing", "Echo", "", {});
		expect_error(&rig.cap, "org.freedesktop.DBus.Error.UnknownInterface");
		deliver(&rig.server, "/org/bleu/none", TEST_INTERFACE, "Echo", "", {});
		expect_error(&rig.cap, "org.freedesktop.DBus.Error.UnknownObject");
	};
}

fn void methods_answer_and_handler_faults_become_names() @test
{
	Rig rig;
	rig.start();
	defer rig.stop();
	rig.export_test();
	@pool()
	{
		deliver(&rig.server, TEST_PATH, TEST_INTERFACE, "Add", "uu", { value::u32(1), value::u32(2) });
		assert(rig.cap.type == METHOD_RETURN && rig.cap.signature.str_view() == "u");
		Reader r;
		r.init(rig.cap.body.str_view(), "u")!!;
		assert(r.read_u32()!! == 3);
		deliver(&rig.server, TEST_PATH, TEST_INTERFACE, "Fail", "", {});
		expect_error(&rig.cap, ERROR_ACCESS_DENIED);
		deliver(&rig.server, TEST_PATH, TEST_INTERFACE, "Named", "", {});
		expect_error(&rig.cap, ERROR_CUSTOM);
	};
}

fn void a_reply_that_breaks_its_signature_is_failed() @test
{
	Rig rig;
	rig.start();
	defer rig.stop();
	rig.export_test();
	@pool()
	{
		deliver(&rig.server, TEST_PATH, TEST_INTERFACE, "Broken", "", {});
		expect_error(&rig.cap, "org.freedesktop.DBus.Error.Failed");
		deliver(&rig.server, TEST_PATH, TEST_INTERFACE, "Silent", "", {});
		expect_error(&rig.cap, "org.freedesktop.DBus.Error.Failed");
	};
}

fn void properties_read_write_and_refuse_by_access_and_type() @test
{
	Rig rig;
	rig.start();
	defer rig.stop();
	rig.export_test();
	rig.state.count = 5;
	@pool()
	{
		deliver(&rig.server, TEST_PATH, "org.freedesktop.DBus.Properties", "Get", "ss", {
			value::str(tmem, TEST_INTERFACE)!!, value::str(tmem, "Count")!!,
		});
		assert(rig.cap.type == METHOD_RETURN && rig.cap.signature.str_view() == "v");
		Reader r;
		r.init(rig.cap.body.str_view(), "v")!!;
		assert(r.read_value(tmem)!!.as_u32()!! == 5);

		rig.cap.messages = 0;
		deliver(&rig.server, TEST_PATH, "org.freedesktop.DBus.Properties", "Set", "ssv", {
			value::str(tmem, TEST_INTERFACE)!!, value::str(tmem, "Count")!!, value::variant(tmem, value::u32(9)),
		});
		assert(rig.cap.messages == 2, "a set of an EMITS_CHANGED property announces it, then answers");
		assert(rig.cap.type == METHOD_RETURN && rig.state.count == 9);

		deliver(&rig.server, TEST_PATH, "org.freedesktop.DBus.Properties", "Set", "ssv", {
			value::str(tmem, TEST_INTERFACE)!!, value::str(tmem, "Label")!!, value::variant(tmem, value::str(tmem, "x")!!),
		});
		expect_error(&rig.cap, "org.freedesktop.DBus.Error.PropertyReadOnly");

		deliver(&rig.server, TEST_PATH, "org.freedesktop.DBus.Properties", "Set", "ssv", {
			value::str(tmem, TEST_INTERFACE)!!, value::str(tmem, "Count")!!, value::variant(tmem, value::str(tmem, "x")!!),
		});
		expect_error(&rig.cap, "org.freedesktop.DBus.Error.InvalidArgs");

		deliver(&rig.server, TEST_PATH, "org.freedesktop.DBus.Properties", "Get", "ss", {
			value::str(tmem, TEST_INTERFACE)!!, value::str(tmem, "Secret")!!,
		});
		expect_error(&rig.cap, "org.freedesktop.DBus.Error.UnknownProperty");

		deliver(&rig.server, TEST_PATH, "org.freedesktop.DBus.Properties", "GetAll", "s", {
			value::str(tmem, TEST_INTERFACE)!!,
		});
		assert(rig.cap.type == METHOD_RETURN && rig.cap.signature.str_view() == "a{sv}");
		Reader all;
		all.init(rig.cap.body.str_view(), "a{sv}")!!;
		Value dict = all.read_value(tmem)!!;
		assert(dict.count() == 2, "GetAll lists the readable properties only");
		assert(dict.dict_get("Count")!!.as_u32()!! == 9);
		assert(dict.dict_get("Label")!!.as_string()!! == "fixed");
	};
}

fn void no_reply_expected_sends_nothing() @test
{
	Rig rig;
	rig.start();
	defer rig.stop();
	rig.export_test();
	@pool()
	{
		deliver(&rig.server, TEST_PATH, TEST_INTERFACE, "Echo", "s", { value::str(tmem, "x")!! }, message::FLAG_NO_REPLY_EXPECTED);
		deliver(&rig.server, TEST_PATH, TEST_INTERFACE, "Fail", "", {}, message::FLAG_NO_REPLY_EXPECTED);
		assert(rig.cap.messages == 0, "no reply is sent to a call that expects none");
	};
}

fn void deferred_reply_is_sent_when_completed() @test
{
	Rig rig;
	rig.start();
	defer rig.stop();
	rig.export_test();
	@pool()
	{
		deliver(&rig.server, TEST_PATH, TEST_INTERFACE, "Defer", "s", { value::str(tmem, "hi")!! });
		assert(rig.cap.messages == 0 && rig.state.token != (ReplyToken)0, "a deferred call is not answered yet");
		Value[] out = { value::str(tmem, "late")!! };
		rig.server.reply(rig.state.token, out)!!;
		assert(rig.cap.messages == 1 && rig.cap.type == METHOD_RETURN);
		Reader r;
		r.init(rig.cap.body.str_view(), "s")!!;
		assert(r.read_string()!! == "late");
		testing::@expect_fault(rig.server.reply(rig.state.token, out), NOT_FOUND);
	};
}

fn void peer_answers_on_any_path() @test
{
	Rig rig;
	rig.start();
	defer rig.stop();
	@pool()
	{
		deliver(&rig.server, "/nowhere/at/all", "org.freedesktop.DBus.Peer", "Ping", "", {});
		assert(rig.cap.type == METHOD_RETURN && rig.cap.signature.str_view() == "");
		deliver(&rig.server, "/nowhere/at/all", "org.freedesktop.DBus.Peer", "GetMachineId", "", {});
		// The sandbox may have no machine id file; either answer is the contract.
		assert(rig.cap.type == METHOD_RETURN ? rig.cap.signature.str_view() == "s" : rig.cap.error_name.str_view() == "org.freedesktop.DBus.Error.Failed");
	};
}

fn void invalid_descriptions_are_refused() @test
{
	Rig rig;
	rig.start();
	defer rig.stop();
	Method[2] dup = {
		{ .name = "Same", .handler = &named },
		{ .name = "Same", .handler = &named },
	};
	Method[1] no_handler = { { .name = "Nothing" } };
	Method[1] bad_sig = { { .name = "Bad", .in_signature = "a", .handler = &named } };
	Method[1] bad_names = { { .name = "Count", .in_signature = "ss", .in_names = rig.echo_in[..], .handler = &named } };
	Property[1] write_only = { { .name = "W", .signature = "u", .access = WRITE, .changes = EMITS_CHANGED, .set = &set_count } };
	Property[1] const_rw = { { .name = "C", .signature = "u", .access = READ_WRITE, .changes = CONST, .get = &get_count, .set = &set_count } };
	Interface[1] dup_iface = { { .name = "org.bleu.Dup", .methods = dup[..] } };
	Interface[1] nh = { { .name = "org.bleu.Nh", .methods = no_handler[..] } };
	Interface[1] bs = { { .name = "org.bleu.Bs", .methods = bad_sig[..] } };
	Interface[1] bn = { { .name = "org.bleu.Bn", .methods = bad_names[..] } };
	Interface[1] wo = { { .name = "org.bleu.Wo", .properties = write_only[..] } };
	Interface[1] cr = { { .name = "org.bleu.Cr", .properties = const_rw[..] } };
	Interface[1] bi = { { .name = "bad" } };
	testing::@expect_fault(rig.server.export("/org/bleu/a", dup_iface[..]), error::INVALID_ARGUMENT);
	testing::@expect_fault(rig.server.export("/org/bleu/b", nh[..]), error::INVALID_ARGUMENT);
	testing::@expect_fault(rig.server.export("/org/bleu/c", bs[..]), error::INVALID_ARGUMENT);
	testing::@expect_fault(rig.server.export("/org/bleu/d", bn[..]), error::INVALID_ARGUMENT);
	testing::@expect_fault(rig.server.export("/org/bleu/e", wo[..]), error::INVALID_ARGUMENT);
	testing::@expect_fault(rig.server.export("/org/bleu/f", cr[..]), error::INVALID_ARGUMENT);
	testing::@expect_fault(rig.server.export("/org/bleu/g", bi[..]), error::INVALID_ARGUMENT);
	testing::@expect_fault(rig.server.export("not a path", rig.interfaces[..]), error::INVALID_ARGUMENT);
	rig.export_test();
	testing::@expect_fault(rig.server.export(TEST_PATH, rig.interfaces[..]), error::INVALID_STATE);
}

fn void fallbacks_serve_the_paths_below_their_prefix() @test
{
	Rig rig;
	rig.start();
	defer rig.stop();
	testing::@expect_fault(rig.server.register_fallback("/org/bleu/items", rig.interfaces[..]), error::INVALID_ARGUMENT);
	rig.server.register_fallback("/org/bleu/items/", rig.interfaces[..])!!;
	@pool()
	{
		deliver(&rig.server, "/org/bleu/items/7", TEST_INTERFACE, "Echo", "s", { value::str(tmem, "seven")!! });
		assert(rig.cap.type == METHOD_RETURN);
		deliver(&rig.server, "/org/bleu/itemsX", TEST_INTERFACE, "Echo", "s", { value::str(tmem, "x")!! });
		expect_error(&rig.cap, "org.freedesktop.DBus.Error.UnknownObject");
	};
}

fn void object_manager_announces_and_lists_its_objects() @test
{
	Rig rig;
	rig.start();
	defer rig.stop();
	rig.server.make_object_manager("/org/bleu")!!;
	rig.export_test();
	assert(rig.cap.messages == 1 && rig.cap.type == SIGNAL && rig.cap.signature.str_view() == "oa{sa{sv}}");
	@pool()
	{
		deliver(&rig.server, "/org/bleu", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", "", {});
		assert(rig.cap.type == METHOD_RETURN && rig.cap.signature.str_view() == "a{oa{sa{sv}}}");
		assert(rig.cap.body.str_view().contains("/org/bleu/test"));
		rig.server.unexport(TEST_PATH)!!;
		assert(rig.cap.messages == 2 && rig.cap.signature.str_view() == "oas");
		testing::@expect_fault(rig.server.unexport(TEST_PATH), NOT_FOUND);
	};
}

fn void signals_and_changes_follow_their_declarations() @test
{
	Rig rig;
	rig.start();
	defer rig.stop();
	rig.export_test();
	@pool()
	{
		rig.cap.messages = 0;
		rig.server.emit_properties_changed(TEST_PATH, TEST_INTERFACE, { "Count" })!!;
		assert(rig.cap.messages == 1 && rig.cap.signature.str_view() == "sa{sv}as");
		testing::@expect_fault(rig.server.emit_properties_changed(TEST_PATH, TEST_INTERFACE, { "Secret" }), error::INVALID_ARGUMENT);
		rig.server.emit_signal(TEST_PATH, TEST_INTERFACE, "Notice", { value::str(tmem, "hello")!! })!!;
		assert(rig.cap.type == SIGNAL && rig.cap.signature.str_view() == "s");
		testing::@expect_fault(rig.server.emit_signal(TEST_PATH, TEST_INTERFACE, "Notice", { value::u32(1) }), error::INVALID_ARGUMENT);
	};
}

fn void faults_round_trip_through_the_error_names() @test
{
	assert(errors::for_name(server::error_name_for(error::UNAVAILABLE)) == error::UNAVAILABLE);
	assert(errors::for_name(server::error_name_for(error::PERMISSION_DENIED)) == error::PERMISSION_DENIED);
	assert(errors::for_name(server::error_name_for(error::AUTH_REQUIRED)) == error::AUTH_REQUIRED);
	assert(errors::for_name(server::error_name_for(error::INVALID_ARGUMENT)) == error::INVALID_ARGUMENT);
	assert(errors::for_name(server::error_name_for(NOT_FOUND)) == NOT_FOUND);
	assert(errors::for_name(server::error_name_for(TIMEOUT)) == TIMEOUT);
	assert(errors::for_name(server::error_name_for(error::DISCONNECTED)) == error::DISCONNECTED);
	assert(server::error_name_for(error::CANCELLED) == "org.freedesktop.DBus.Error.Failed");
}
