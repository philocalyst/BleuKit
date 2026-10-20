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
import bleu::error, bleu::rt, bleu::rt::unix, bleu::rt::poller, bleu::rt::wakeup, bleu::rt::worker, bleu::audio, bleu::audio::pulse, bleu::deadline, bleu::unit, std::time;

const usz SOCKET_TAG             = 1;               // poller tag of the socket
const Duration REPLY_TIMEOUT     = (Duration)5_000_000; // 5 s: a server that does not answer is failing
                                                    // The longest a reply wait goes without checking the worker's stop flag, so
                                                    // that `Audio.close` is answered within this time even while a server is silent.
const Duration STOP_POLL         = (Duration)50_000; // 50 ms
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
	Host{Command}* host; // the worker's host: its stop flag ends a reply wait
	uint version; // protocol version used for decoding replies
	uint next_tag;
	bool events_seen; // a subscription event arrived and has not been acted on yet
}

<*
 Connect and complete the handshake: authenticate, name the client, subscribe.

 @param allocator : "Allocator for the session (released by `Session.close`)"
 @param cookie : "The 256-byte authentication cookie"
 @param host : "The worker's host; a stop request ends any wait for the server"
 @return? error::PERMISSION_DENIED, error::UNAVAILABLE, error::DISCONNECTED, error::PROTOCOL, error::CANCELLED, TIMEOUT : "the server refused, is gone, speaks another protocol, is silent, or the worker is stopping"
*>
fn Session*? open_session(Allocator allocator, String socket_path, char[] cookie, Host{Command}* host)
{
	UnixSocket socket = unix::connect(socket_path, unix::SocketKind.STREAM)!;
	Session* session = alloc::new(
		allocator,
		Session,
		{ .allocator = allocator, .socket = socket, .version = pulse::PROTOCOL_VERSION, .host = host }
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
 Read one whole packet within REPLY_TIMEOUT, counted from its first byte. Each
 read waits for the socket first (see `await_readable`), so a server that stops
 part-way through a packet times out instead of parking the worker.
*>
fn char[]? Session.read_frame(&self)
{
	Deadline limit = deadline::after(REPLY_TIMEOUT);
	char[pulse::FRAME_HEADER_SIZE] header;
	self.read_exact(header[..], &limit)!;
	FrameHeader frame = pulse::decode_header(header[..])!;
	if (frame.length > pulse::MAX_PAYLOAD) return error::raise(
		error::PROTOCOL,
		error::Domain.PULSE,
		0,
		"frame of %d bytes",
		frame.length
	)~;
	char[] payload = alloc::new_array(tmem, char, frame.length);
	self.read_exact(payload, &limit)!;
	return payload;
}

<*
 Fill `bytes` completely from the socket, looping over short reads. A read that
 returns no bytes means the server closed the connection: a readable socket with
 nothing to read would otherwise make this loop spin.
*>
fn void? Session.read_exact(&self, char[] bytes, Deadline* limit)
{
	sz done = 0;
	while (done < bytes.len)
	{
		self.await_readable(limit)!;
		RecvResult got = self.socket.recv(bytes[done:bytes.len - done], { })!;
		if (got.bytes == 0) return error::raise(
			error::DISCONNECTED,
			error::Domain.PULSE,
			0,
			"server closed the connection with %d bytes of a packet missing",
			bytes.len - done
		)~;
		done += (sz)got.bytes;
	}
}

<*
 Wait until the socket is readable, for at most what is left of `deadline`. The
 wait is cut into STOP_POLL slices, so a stop request from `Audio.close` is seen
 within one slice; the worker's own wake-up is not used here, because the
 mailbox signals it for every command and a command must not be lost in a reply wait.

 @return? TIMEOUT : "the server sent nothing in time"
 @return? error::CANCELLED : "the worker is stopping"
*>
fn void? Session.await_readable(&self, Deadline* limit)
{
	while (true)
	{
		if (self.host.stopping()) return error::raise(
			error::CANCELLED,
			error::Domain.PULSE,
			0,
			"the service is closing while a reply is awaited"
		)~;
		if (limit.expired()) return error::raise(TIMEOUT, error::Domain.PULSE, 0, "no packet from the server")~;
		Duration left  = limit.remaining();
		Duration slice = left < STOP_POLL ? left : STOP_POLL;
		Ready[]? ready = self.waiter.wait(slice);
		if (catch err = ready)
		{
			// TIMEOUT is the end of this slice: check the stop flag and the deadline again.
			if (err != TIMEOUT) return err~;
			continue;
		}
		if (ready.len > 0) return;
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

<*
 The error an ERROR reply carries, classified in the Bleu vocabulary (def.h:471-498).
 A server's own timeout is not the client's: it does not break the session, so it
 is reported as a backend failure, and TIMEOUT stays the client's own wait.
*>
fn fault server_error(uint code) @private
{
	switch (code)
	{
		case (uint)PulseError.ACCESS: return error::raise(error::PERMISSION_DENIED, error::Domain.PULSE, (int)code, "server refused access");
		case (uint)PulseError.NOENTITY: return error::raise(NOT_FOUND, error::Domain.PULSE, (int)code, "no such device or stream");
		case (uint)PulseError.INVALID: return error::raise(error::INVALID_ARGUMENT, error::Domain.PULSE, (int)code, "server rejected an argument");
		case (uint)PulseError.NOTSUPPORTED: return error::raise(error::UNSUPPORTED, error::Domain.PULSE, (int)code, "server does not support it");
		case (uint)PulseError.TIMEOUT: return error::raise(error::BACKEND_FAILURE, error::Domain.PULSE, (int)code, "server timed out");
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