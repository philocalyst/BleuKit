// Unit tests for bleu::dbus::connection that need no bus. Each test connects a
// Connection to one end of a socketpair and plays the bus through the other end:
// it writes the frames a bus would send, and reads what the connection sent. They
// cover the receive path (a failing read, descriptor attribution, the read budget
// of one process() call), the answers a blocking call gives to incoming calls,
// failed sends, and re-entry from a handler.
module bleu::dbus::connection_test;
import bleu::error, bleu::dbus::connection, bleu::dbus::message, bleu::dbus::server, bleu::dbus::testing, bleu::dbus::transport;
import std::time;

extern fn int socketpair(int domain, int type, int protocol, int* fds) @cname("socketpair");
extern fn int pipe(int* fds);
extern fn sz read(int fd, void* buffer, usz count) @cname("read");

<* Linux SOCK_NONBLOCK: both ends of the test pair are non-blocking, as the connection expects. *>
const int SOCK_NONBLOCK = 0x800;

<* Size of one read from the peer end while the test collects what the connection sent. *>
const READ_CHUNK = 4096;

<* Messages the burst test sends in one go: more than one process() call can read. *>
const BURST_MESSAGES = 200;

<*
 A connection whose socket is one end of a socketpair. `peer` is the other end:
 the test writes the bus's side of the conversation there, and reads back what
 the connection sent.
*>
struct Rig
{
	Connection c;
	int peer;
}

// Creates the pair, and opens the connection on one end of it.
fn void Rig.start(&self)
{
	int[2] pair;
	assert(socketpair(transport::AF_UNIX, transport::SOCK_STREAM | SOCK_NONBLOCK, 0, &pair[0]) == 0, "socketpair failed");
	self.peer = pair[0];
	self.c.init(mem);
	self.c.socket_fd = pair[1];
	self.c.is_open = true;
}

// Frees the connection, and closes the peer end unless the test has closed it.
fn void Rig.stop(&self)
{
	self.c.free();
	if (self.peer >= 0) transport::close_fd(self.peer);
}

// Writes `bytes` to `fd`, with `fds` travelling with the first byte, as a bus would send them.
fn void send_bytes(int fd, String bytes, int[] fds)
{
	usz sent = 0;
	int[] pending = fds;
	while (sent < bytes.len)
	{
		usz written = transport::send_some(fd, bytes, sent, pending)!!;
		if (written > 0) pending = fds[0:0];
		sent += written;
	}
}

// Encodes `m` and writes it to `fd`, with `fds` on its first byte.
fn void send_frame(int fd, Message* m, int[] fds)
{
	DString out;
	out.init(mem);
	defer out.free();
	m.encode(&out)!!;
	send_bytes(fd, out.str_view(), fds);
}

// Everything the connection has written to the peer end so far.
fn DString drain(int fd)
{
	DString out;
	out.init(mem);
	char[READ_CHUNK] buffer;
	while (true)
	{
		sz got = read(fd, &buffer[0], READ_CHUNK);
		if (got <= 0) return out;
		out.append_bytes(buffer[0:(usz)got]);
	}
}

// True when `bytes` holds a METHOD_RETURN that answers the call with serial `serial`.
fn bool answers(String bytes, uint serial)
{
	usz at = 0;
	while (at + (usz)message::FIXED_HEADER_LENGTH <= bytes.len)
	{
		usz total  = message::frame_length(bytes[at:(usz)message::FIXED_HEADER_LENGTH])!!;
		Message* m = message::parse(mem, bytes[at:total])!!;
		bool hit   = m.type == message::MessageType.METHOD_RETURN && m.reply_serial == serial;
		m.release();
		if (hit) return true;
		at += total;
	}
	return false;
}

// A read that fails for a reason other than "no data yet" ends the connection with that
// fault. It must not abort the process.
fn void a_failed_read_closes_the_connection() @test
{
	int[2] pipe_fds;
	assert(pipe(&pipe_fds[0]) == 0, "pipe failed");
	Connection c;
	c.init(mem);
	defer c.free();
	c.socket_fd = pipe_fds[0];
	c.is_open = true;
	// recvmsg on a pipe fails with ENOTSOCK.
	testing::@expect_fault(c.process(), error::BACKEND_FAILURE);
	assert(!c.is_open, "the failed read must close the connection");
	transport::close_fd(pipe_fds[1]);
}

struct Outcome
{
	int calls;
	error::Status status;
}

fn void record_outcome(void* context, Message* reply, error::Status status)
{
	Outcome* o = (Outcome*)context;
	o.calls++;
	o.status = status;
}

// A send that fails hands the failure to the handler, once, and the call itself returns
// success: the caller must not see the failure twice.
fn void a_failed_send_is_reported_once() @test
{
	Rig rig;
	rig.start();
	transport::close_fd(rig.peer);
	rig.peer = -1;
	Message* m = message::method_call(mem, "org.example.Peer", "/p", "org.example.I", "M")!!;
	defer m.release();
	Outcome o;
	if (catch rig.c.call_async(m, &record_outcome, &o, time::ms(1000)))
	{
		assert(false, "call_async returned an error the handler has already reported");
	}
	assert(o.calls == 1, "the handler must run exactly once");
	assert(o.status == error::Status.DISCONNECTED, "the handler must see DISCONNECTED");
	rig.stop();
}

// What the Ping handler saw: whether it ran before the blocking call returned.
struct Served
{
	bool ran;
	bool returned;
	bool while_waiting;
}

fn void? ping(void* context, Call* call)
{
	Served* s = (Served*)context;
	s.ran = true;
	s.while_waiting = !s.returned;
	return call.reply({ });
}

// A call from the peer that arrives while this connection waits for its own reply is
// answered at once, by the server, inside the wait. The peer waits for that answer, so
// answering only after our call returns would stall both sides until their timeouts.
fn void answers_incoming_calls_while_it_waits() @test
{
	Rig rig;
	rig.start();
	Served served;
	Method[1] methods        = { { .name = "Ping", .handler = &ping, .context = &served } };
	Interface[1] interfaces  = { { .name = "org.bleu.Test", .methods = methods[..] } };
	ObjectServer server;
	server.init(mem);
	server.attach(&rig.c);
	server.export("/org/bleu/Test", interfaces[..])!!;

	Message* theirs = message::method_call(mem, "org.example.Peer", "/org/bleu/Test", "org.bleu.Test", "Ping")!!;
	theirs.serial = 100;
	send_frame(rig.peer, theirs, { });
	theirs.release();

	// The peer never answers this one, so the call times out, but it must answer ours first.
	Message* ours = message::method_call(mem, "org.example.Peer", "/org/bleu/Other", "org.bleu.Other", "Never")!!;
	defer ours.release();
	testing::@expect_fault(rig.c.call(ours, time::ms(50)), TIMEOUT);
	served.returned = true;

	DString sent = drain(rig.peer);
	defer sent.free();
	assert(served.ran, "the incoming call was never answered");
	assert(served.while_waiting, "the incoming call was answered only after the blocking call returned");
	assert(answers(sent.str_view(), 100), "the answer to the incoming call was not sent");
	server.free();
	rig.stop();
}

// A descriptor belongs to the message whose first byte it arrived with. A message that
// declares none must not carry one, or the next message's declaration takes it.
fn void descriptors_belong_to_their_own_frame() @test
{
	Rig rig;
	rig.start();
	int[2] pipe_fds;
	assert(pipe(&pipe_fds[0]) == 0, "pipe failed");
	int[1] carried = { pipe_fds[0] };
	Message* plain = message::method_call(mem, "org.example.Peer", "/a", "org.example.A", "One")!!;
	plain.serial = 201;
	send_frame(rig.peer, plain, carried[..]);
	plain.release();
	// This message declares one descriptor, and is sent without one.
	Message* declares = message::method_call(mem, "org.example.Peer", "/b", "org.example.B", "Two")!!;
	declares.serial = 202;
	declares.attach_fd(pipe_fds[1]);
	send_frame(rig.peer, declares, { });
	declares.release();
	testing::@expect_fault(rig.c.process(), error::PROTOCOL);
	transport::close_fd(pipe_fds[0]);
	transport::close_fd(pipe_fds[1]);
	rig.stop();
}

// One process() call reads a bounded amount. A peer that writes faster than the
// connection reads must not keep one call going: the rest waits for the next call.
fn void one_process_call_reads_a_bounded_amount() @test
{
	Rig rig;
	rig.start();
	DString burst;
	burst.init(mem);
	defer burst.free();
	for (uint serial = 1; serial <= BURST_MESSAGES; serial++)
	{
		Message* tick = message::signal(mem, "/org/bleu/Burst", "org.bleu.Burst", "Tick")!!;
		tick.serial = serial;
		tick.encode(&burst)!!;
		tick.release();
	}
	send_bytes(rig.peer, burst.str_view(), { });
	rig.c.process()!!;
	assert(transport::wait(rig.c.socket_fd, true, false, time::ms(0)), "one process() call read the whole burst");
	rig.stop();
}

struct Reentry
{
	Connection* c;
	bool called;
	bool refused;
}

fn void reenter(void* context, Message* reply, error::Status status)
{
	Reentry* r = (Reentry*)context;
	r.called = true;
	if (catch err = r.c.process()) r.refused = err == error::INVALID_STATE;
}

// process() called from a handler is refused. The handler already runs inside the outer
// process(), and a nested one would dispatch the queue again underneath it.
fn void process_is_refused_inside_a_handler() @test
{
	Rig rig;
	rig.start();
	Reentry r = { .c = &rig.c };
	Message* call = message::method_call(mem, "org.example.Peer", "/p", "org.example.I", "M")!!;
	defer call.release();
	rig.c.call_async(call, &reenter, &r, time::ms(1000))!!;
	Message* reply = message::reply_to(mem, "", call.serial)!!;
	reply.serial = 300;
	send_frame(rig.peer, reply, { });
	reply.release();
	rig.c.process()!!;
	assert(r.called, "the reply handler did not run");
	assert(r.refused, "process() ran inside a handler");
	rig.stop();
}

// When a malformed frame follows the reply to a blocking call, the call fails and the
// reply it already found is released, not leaked.
fn void a_malformed_frame_after_the_reply_releases_it() @test
{
	Rig rig;
	rig.start();
	Message* call = message::method_call(mem, "org.example.Peer", "/p", "org.example.I", "M")!!;
	defer call.release();
	call.serial = 1;
	Message* reply = message::reply_to(mem, "", 1)!!;
	reply.serial = 301;
	send_frame(rig.peer, reply, { });
	reply.release();
	// A header whose protocol version is 2.
	char[16] junk = { 'l', 1, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
	send_bytes(rig.peer, (String)junk[..], { });
	testing::@expect_fault(rig.c.call(call, time::ms(1000)), error::PROTOCOL);
	rig.stop();
}
