<*
 A stand-in for a compositor, for tests: the server side of the Wayland wire protocol on
 one end of a socket pair. It receives the client's requests and sends the events a test
 scenario calls for. It uses the same `wire` encoder and decoder as the client, so a
 mismatch between them shows up as a failure of the scenario, not as a silent pass.

 A MockServer belongs to one thread: the scenario thread. The client runs on the test's
 main thread, which is how a real compositor and client run in two processes.
*>
module bleu::wl::testing @feat(POSIX);
import bleu::rt, bleu::rt::unix, bleu::wl::wire, bleu::wl::display, bleu::error, std::core::mem;

<* Receive buffer: room for a few messages at once. *>
const usz MOCK_INBOX_CAPACITY = 4 * wire::MAX_MESSAGE_SIZE;

<*
 One message from the client. `payload` is the argument bytes; it is valid until the
 next call to `receive`.
*>
struct Message
{
	uint object;
	ushort opcode;
	char[] payload;
}

<* The server end of a connection, with its own receive buffer and descriptor queue. *>
struct MockServer
{
	unix::UnixSocket peer;
	char[MOCK_INBOX_CAPACITY] inbox;
	usz inbox_len;
	char[wire::MAX_MESSAGE_SIZE] last;
	wire::FdQueue fds;
}

<* Take ownership of the server end of a socket pair. *>
fn void MockServer.attach(&self, unix::UnixSocket peer)
{
	self.peer = peer;
	self.inbox_len = 0;
	self.fds = { };
}

<* Close the connection. *>
fn void MockServer.close(&self)
{
	(void)self.peer.close();
	while (self.fds.count > 0) display::native_close(self.fds.pop()!!);
}

<*
 Block until one complete message from the client has arrived. Descriptors that came
 with it are queued in `fds`, in order, and the message's reader uses them.

 @return? error::PROTOCOL : "The client sent a malformed message header"
 @return? error::DISCONNECTED : "The client closed its end"
*>
fn Message? MockServer.receive(&self)
{
	while (true)
	{
		wire::Frame frame = wire::read_frame(self.inbox[0:self.inbox_len])!;
		if (frame.complete)
		{
			usz payload_len = frame.size - wire::HEADER_SIZE;
			mem::copy(&self.last[0], &self.inbox[wire::HEADER_SIZE], (sz)payload_len);
			usz rest = self.inbox_len - frame.size;
			mem::move(&self.inbox[0], &self.inbox[frame.size], (sz)rest);
			self.inbox_len = rest;
			return { .object = frame.object, .opcode = frame.opcode, .payload = self.last[0:payload_len] };
		}
		self.fill()!;
	}
}

<* A reader over a received message's arguments, with this server's descriptor queue. *>
fn wire::Reader MockServer.reader(&self, Message message) => { .data = message.payload, .pos = 0, .fds = &self.fds };

<*
 Send one event or reply. The writer's descriptors are passed with it.

 @return? error::DISCONNECTED, error::BACKEND_FAILURE : "The client end is gone"
*>
fn void? MockServer.send(&self, wire::Writer* writer)
{
	unix::Fd[wire::MAX_FDS_PER_MESSAGE] wrapped;
	rt::Native[] fds = writer.descriptors();
	for (usz i = 0; i < fds.len; i++) wrapped[i] = { .value = fds[i] };
	self.peer.send_all(writer.finish(), wrapped[0:fds.len])!;
}

<*
 Send two messages in one write, so they reach the client in one read and are handled by the
 same dispatch. Messages with no descriptors only.

 @return? error::DISCONNECTED, error::BACKEND_FAILURE : "The client end is gone"
*>
fn void? MockServer.send_pair(&self, wire::Writer* first, wire::Writer* second)
{
	char[] a = first.finish();
	char[] b = second.finish();
	char[2 * wire::MAX_MESSAGE_SIZE] both;
	mem::copy(&both[0], a.ptr, a.len);
	mem::copy(&both[a.len], b.ptr, b.len);
	self.peer.send_all(both[0:a.len + b.len])!;
}

// Read whatever the client has sent so far and queue its descriptors.
fn void? MockServer.fill(&self)
{
	unix::Fd[wire::MAX_FDS_PER_MESSAGE] arrived;
	usz room             = MOCK_INBOX_CAPACITY - self.inbox_len;
	unix::RecvResult got = self.peer.recv(self.inbox[self.inbox_len:room], arrived[..])!;
	for (usz i = 0; i < got.fds; i++) self.fds.push(arrived[i].value)!;
	self.inbox_len += got.bytes;
}