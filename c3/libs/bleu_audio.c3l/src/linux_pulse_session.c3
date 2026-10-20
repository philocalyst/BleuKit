<*
 One connection to a PulseAudio native-protocol server: the handshake, framed
 reads and writes, and request/reply matching.

 The worker is the only user of a session, so nothing here is locked. Replies
 are matched by tag. Events (command SUBSCRIBE_EVENT, tag 0xFFFFFFFF) met while
 waiting for a reply are recorded in `events_seen`; the worker refreshes the
 state when it sees that flag.

 Handshake (research 2.1.2; pulsecore/protocol-native.c and pulse/context.c):
 AUTH, SET_CLIENT_NAME, SUBSCRIBE. Records are decoded with
 min(PROTOCOL_VERSION, the version in the AUTH reply): the server writes the
 fields it knows for the version the client asked for, so the decoder must
 stop at the server's own version (research note A6).
*>
module bleu::audio::linux_pulse @feat(LINUX);
import bleu::error, bleu::rt, bleu::rt::unix, bleu::rt::poller, bleu::rt::wakeup, bleu::audio::pulse, bleu::unit, std::time;

const usz SOCKET_TAG             = 1;               // poller tag of the socket
const Duration REPLY_TIMEOUT     = (Duration)5_000_000; // 5 s: a server that does not answer is failing
const uint SUBSCRIBED_FACILITIES = pulse::MASK_SINK | pulse::MASK_SOURCE | pulse::MASK_SINK_INPUT
	| pulse::MASK_SOURCE_OUTPUT
	| pulse::MASK_CARD
	| pulse::MASK_SERVER;

<*
 A live connection. Heap-allocated: the poller points at its wake-up, which
 must not move.
*>
struct Session
{
	Allocator allocator;
	UnixSocket socket;
	Wakeup idle; // never signalled, so the reply poller watches only the socket
	Poller waiter;
	uint version; // protocol version used for decoding replies
	uint next_tag;
	bool events_seen; // a subscription event arrived and has not been acted on yet
}

<*
 Connect and complete the handshake: authenticate, name the client, subscribe.

 @param allocator : "Allocator for the session (released by `Session.close`)"
 @param cookie : "The 256-byte authentication cookie"
 @return? error::PERMISSION_DENIED, error::UNAVAILABLE, error::DISCONNECTED, error::PROTOCOL : "the server refused, is gone or speaks another protocol"
*>
fn Session*? open_session(Allocator allocator, String socket_path, char[] cookie)
{
	UnixSocket socket = unix::connect(socket_path, unix::SocketKind.STREAM)!;
	Session* session  = alloc::new(
		allocator,
		Session,
		{ .allocator = allocator, .socket = socket, .version = pulse::PROTOCOL_VERSION }
	);
	if (catch err = session.idle.init())
	{
		session.socket.close();
		alloc::free(allocator, session);
		return err~;
	}
	if (catch err = session.waiter.init(allocator, &session.idle, 1))
	{
		session.idle.close();
		session.socket.close();
		alloc::free(allocator, session);
		return err~;
	}
	if (catch err = session.waiter.add(
		{ .handle = session.socket.fd.raw(), .interest = { .readable = true }, .tag = SOCKET_TAG }
	))
	{
		session.close();
		return err~;
	}
	if (catch err = session.handshake(cookie))
	{
		session.close();
		return err~;
	}
	return session;
}

// AUTH, SET_CLIENT_NAME and SUBSCRIBE, each in its own pool.
fn void? Session.handshake(&self, char[] cookie)
{
	@pool()
	{
		uint tag        = self.next_tag++;
		DString auth    = pulse::request_auth(tmem, tag, cookie);
		TagReader reply = self.call(&auth, tag)!;
		uint server     = reply.u32()!;
		self.version = min(pulse::PROTOCOL_VERSION, server & pulse::VERSION_MASK);
	};
	@pool()
	{
		uint tag          = self.next_tag++;
		Property[2] props = { { "application.name", "Bleu audio" }, { "application.id", "bleu.audio" } };
		DString name      = pulse::request_set_client_name(tmem, tag, props[..]);
		self.acknowledge(&name, tag)!;
	};
	@pool()
	{
		uint tag          = self.next_tag++;
		DString subscribe = pulse::request_subscribe(tmem, tag, SUBSCRIBED_FACILITIES);
		self.acknowledge(&subscribe, tag)!;
	};
}

<*
 Send `request` and wait for the reply with the same tag. Returns the reply's
 arguments, read from a packet that lives in the caller's temporary pool.
*>
fn TagReader? Session.call(&self, DString* request, uint tag)
{
	self.socket.send_all(pulse::finish_packet(request))!;
	while (true)
	{
		char[] payload   = self.read_frame()!;
		TagReader reader = { .data = payload };
		uint command     = reader.u32()!;
		uint got         = reader.u32()!;
		if (command == (uint)PulseCommand.SUBSCRIBE_EVENT)
		{
			self.events_seen = true;
			continue;
		}
		if (got != tag) continue;
		if (command == (uint)PulseCommand.ERROR) return server_error(reader.u32()!)~;
		if (command != (uint)PulseCommand.REPLY)
		{
			return error::raise(
				error::PROTOCOL,
				error::Domain.PULSE,
				(int)command,
				"reply to tag %d has command %d",
				tag,
				command
			)~;
		}
		return reader;
	}
}

<* Send a request whose reply carries nothing the caller needs. *>
fn void? Session.acknowledge(&self, DString* request, uint tag)
{
	if (catch err = self.call(request, tag)) return err~;
}

<*
 Read one whole packet. Waits for readiness of the socket first, for at most
 REPLY_TIMEOUT; the rest of the packet is read with blocking reads, since a
 server writes whole packets.
*>
fn char[]? Session.read_frame(&self)
{
	Ready[] ready = self.waiter.wait(REPLY_TIMEOUT)!;
	if (ready.len == 0) return error::raise(TIMEOUT, error::Domain.PULSE, 0, "no packet from the server")~;
	char[pulse::FRAME_HEADER_SIZE] header;
	self.read_exact(header[..])!;
	FrameHeader frame = pulse::decode_header(header[..])!;
	if (frame.length > pulse::MAX_PAYLOAD) return error::raise(
		error::PROTOCOL,
		error::Domain.PULSE,
		0,
		"frame of %d bytes",
		frame.length
	)~;
	char[] payload = alloc::new_array(tmem, char, frame.length);
	self.read_exact(payload)!;
	return payload;
}

// Fill `bytes` completely from the socket, looping over short reads.
fn void? Session.read_exact(&self, char[] bytes)
{
	sz done = 0;
	while (done < bytes.len)
	{
		RecvResult got = self.socket.recv(bytes[done:bytes.len - done], { })!;
		done += (sz)got.bytes;
	}
}

<* Close the socket and free the session. *>
fn void Session.close(&self)
{
	(void)self.socket.close();
	self.waiter.free();
	self.idle.close();
	Allocator allocator = self.allocator;
	alloc::free(allocator, self);
}

<* The error an ERROR reply carries, classified in the Bleu vocabulary (def.h:471-498). *>
fn fault server_error(uint code) @private
{
	switch (code)
	{
		case (uint)PulseError.ACCESS: return error::raise(error::PERMISSION_DENIED, error::Domain.PULSE, (int)code, "server refused access");
		case (uint)PulseError.NOENTITY: return error::raise(NOT_FOUND, error::Domain.PULSE, (int)code, "no such device or stream");
		case (uint)PulseError.INVALID: return error::raise(error::INVALID_ARGUMENT, error::Domain.PULSE, (int)code, "server rejected an argument");
		case (uint)PulseError.NOTSUPPORTED: return error::raise(error::UNSUPPORTED, error::Domain.PULSE, (int)code, "server does not support it");
		case (uint)PulseError.TIMEOUT: return error::raise(TIMEOUT, error::Domain.PULSE, (int)code, "server timed out");
		default: return error::raise(error::BACKEND_FAILURE, error::Domain.PULSE, (int)code, "server error %d", code);
	}
}

<*
 Read one packet that the reply poller reported ready and note it: a
 subscription event sets `events_seen`; anything else is a stale reply and is
 dropped.
*>
fn void? Session.absorb(&self)
{
	char[] payload   = self.read_frame()!;
	TagReader reader = { .data = payload };
	uint command     = reader.u32()!;
	if (command == (uint)PulseCommand.SUBSCRIBE_EVENT) self.events_seen = true;
}

<* True for the failures after which the connection cannot be trusted any more. *>
fn bool breaks_session(fault err) => err == error::DISCONNECTED || err == TIMEOUT || err == error::PROTOCOL;