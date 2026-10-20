// Unit tests for the answers of bleu::dbus::server that must always reach the caller:
// an error text that is not UTF-8 must still be sent, and a body with bytes after its
// last argument is refused. Each test drives an ObjectServer through a sink that counts
// what it sends, so no bus is needed.
module bleu::dbus::server_reply_test;
import bleu::error, bleu::dbus::server, bleu::dbus::message, bleu::dbus::marshal;

const TEST_PATH      = "/org/bleu/Reply";
const TEST_INTERFACE = "org.bleu.Reply";
const BAD_NAME       = "org.bleu.Reply.Error.Bad";

// What the sink saw: how many messages were sent, and the type of the last one.
struct Sent
{
	int messages;
	MessageType type;
}

fn void? count_sent(void* context, Message* m)
{
	Sent* s = (Sent*)context;
	s.messages++;
	s.type = m.type;
}

// Raises a fault whose text names a file that is not valid UTF-8.
fn void? fails_with_a_bad_text(void* context, Call* call)
{
	return error::raise(error::INVALID_ARGUMENT, error::Domain.DBUS, 0, "cannot open %s", "\xff.txt")~;
}

// Answers with an error whose text is not valid UTF-8.
fn void? refuses_with_a_bad_text(void* context, Call* call)
{
	return call.reply_error(BAD_NAME, "bad \xff text");
}

// Delivers a call to `member` of the test interface, as a bus would, and lets the server answer it.
fn void deliver(ObjectServer* server, String member)
{
	Message* call = message::method_call(mem, "org.example.Peer", TEST_PATH, TEST_INTERFACE, member)!!;
	defer call.release();
	call.serial = 5;
	server.handle(call);
}

// A handler's failure whose text is not UTF-8 is still answered, with an error.
fn void a_bad_fault_text_still_gets_an_answer() @test
{
	Method[2] methods = {
		{ .name = "Fail", .handler = &fails_with_a_bad_text },
		{ .name = "Refuse", .handler = &refuses_with_a_bad_text },
	};
	Interface[1] interfaces = { { .name = TEST_INTERFACE, .methods = methods[..] } };
	ObjectServer server;
	server.init(mem);
	defer server.free();
	server.export(TEST_PATH, interfaces[..])!!;
	Sent sent;
	server.use_sink(&count_sent, &sent);

	deliver(&server, "Fail");
	assert(sent.messages == 1, "a failed call got no answer");
	assert(sent.type == message::MessageType.ERROR, "the answer to a failed call is not an error");

	deliver(&server, "Refuse");
	assert(sent.messages == 2, "a refused call got no answer");
	assert(sent.type == message::MessageType.ERROR, "the answer to a refused call is not an error");
}

// A body with bytes after its last argument is refused, not accepted: the handler reads one
// string, and the second one is trailing data.
fn void trailing_bytes_after_the_arguments_are_refused() @test
{
	ObjectServer server;
	server.init(mem);
	defer server.free();
	Interface[1] interfaces = { { .name = TEST_INTERFACE } };
	server.export(TEST_PATH, interfaces[..])!!;
	Sent sent;
	server.use_sink(&count_sent, &sent);

	// GetAll takes one string; the body below carries two.
	Message* call = message::method_call(
		mem,
		"org.example.Peer",
		TEST_PATH,
		"org.freedesktop.DBus.Properties",
		"GetAll"
	)!!;
	defer call.release();
	call.serial = 6;
	Writer* w = call.body_writer("ss")!!;
	w.append_string(TEST_INTERFACE)!!;
	w.append_string("trailing")!!;
	call.writer.signature = "s";
	server.handle(call);
	assert(sent.messages == 1, "the call got no answer");
	assert(sent.type == message::MessageType.ERROR, "a body with trailing bytes was accepted");
}
