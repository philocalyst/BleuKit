<*
 A connection to a D-Bus bus, driven by one thread.

 `Connection` owns a socket, the authentication handshake, the outgoing and
 incoming queues, the pending calls and the signal subscriptions. It is not
 thread-safe: the thread that calls `init` owns it, and every public method
 asserts, in debug builds, that it runs on that thread. A service runs its
 connection on its worker thread; other threads ask the worker to act.

 I/O is non-blocking except for `call`, which is blocking by design. An event
 loop watches `fd()` for readability, and also for writability while
 `has_pending_output()`, and calls `process()`. `call` pumps the connection
 until its reply arrives; every other message it reads is queued for the next
 `process()`, not dropped. Handlers run inside `process()` and must not call
 `process()` or `close()` themselves.

 When the peer closes the socket, or sends malformed data, the connection is
 closed: every later call reports DISCONNECTED until `open_*` is called again.
 Subscriptions and pending calls do not survive a reconnect; the caller sets
 them up again.

 Sources: D-Bus specification, "Message Protocol", "Authentication Protocol"
 (the NUL byte, EXTERNAL, NEGOTIATE_UNIX_FD, BEGIN), and "Message Bus
 Specification" (Hello and the unique name). A descriptor travels with the first
 byte of its message; the message's UNIX_FDS field counts them.
*>
module bleu::dbus::connection;
import bleu::error, bleu::deadline, bleu::dbus::address, bleu::dbus::auth, bleu::dbus::errors, bleu::dbus::match, bleu::dbus::message, bleu::dbus::transport, bleu::dbus::marshal;
import std::collections::list, std::thread, std::time;

<* Bus name and object path of the message bus daemon. *>
const BUS_NAME      = "org.freedesktop.DBus";
const BUS_PATH      = "/org/freedesktop/DBus";
const BUS_INTERFACE = "org.freedesktop.DBus";

<* Longest wait for a call whose timeout the caller does not give, in milliseconds. *>
const DEFAULT_TIMEOUT_MS = 25000;

<* Longest wait for the authentication handshake, in milliseconds. *>
const HANDSHAKE_TIMEOUT_MS = 25000;

<* Interface of the peer-to-peer methods every connection answers. *>
const PEER_INTERFACE = "org.freedesktop.DBus.Peer";

<* Bytes read from the socket per receive call. *>
const RECEIVE_CHUNK = 16384;

<* Identifier of a signal subscription, for `unsubscribe`. *>
typedef SubscriptionId = uint;

<*
 Called for each signal that matches a subscription. The message is valid only
 during the call; copy what must outlive it.
*>
alias SignalHandler = fn void(void* context, Message* signal);

<*
 Called when a pending call completes. On success `reply` is the METHOD_RETURN
 and `status` is OK. On failure `reply` is null and `status` classifies the
 failure; the D-Bus name and text are in `error::last()`. `reply` is valid only
 during the call.
*>
alias ReplyHandler = fn void(void* context, Message* reply, error::Status status);

<* A call that was sent and has not been answered yet. *>
struct PendingCall
{
	uint serial;
	Deadline deadline;
	ReplyHandler handler;
	void* context;
}

<*
 A signal subscription. The subscription owns `rule`, and `owned` (a context
 the library allocated for a typed wrapper, or null): both are freed when the
 subscription is dropped.
*>
struct Subscription
{
	SubscriptionId id;
	bool active;
	match::Match rule;
	SignalHandler handler;
	void* context;
	void* owned;
}

<* Descriptors to send with the message that starts at byte `at` of the outgoing queue. *>
struct OutboundFds
{
	usz at;
	int[] fds;
}

<* A well-known name and the unique name that owns it, as last reported by the bus. *>
struct NameOwner
{
	DString name;
	DString owner;
}

<*
 One connection to a bus. Initialise with `init`, release with `free`; while
 initialised it may be opened, closed and opened again.
*>
struct Connection
{
	Allocator allocator;
	Thread owner;
	bool is_open;
	int socket_fd;
	bool fds_negotiated;
	DString unique_name;
	uint next_serial;
	uint next_subscription;
	DString outbound;
	usz sent;
	List{OutboundFds} outbound_fds;
	DString inbox;
	List{int} descriptors;
	List{Message*} deferred;
	List{PendingCall} pending;
	List{Subscription*} subscriptions;
	List{NameOwner*} names;
}

<*
 Prepare a connection that is not open. The calling thread becomes its owner.

 @param [&inout] allocator : "Allocator for the queues and for every message the connection creates"
*>
fn void Connection.init(&self, Allocator allocator)
{
	*self = {
		.allocator = allocator,
		.owner = thread::current(),
		.socket_fd = -1,
		.next_serial = 1,
		.next_subscription = 1
	};
	self.unique_name.init(allocator);
	self.outbound.init(allocator);
	self.inbox.init(allocator);
	self.outbound_fds.init(allocator);
	self.descriptors.init(allocator);
	self.deferred.init(allocator);
	self.pending.init(allocator);
	self.subscriptions.init(allocator);
	self.names.init(allocator);
}

<* Close the connection if it is open, and release everything it holds. *>
fn void Connection.free(&self)
{
	self.check_owner();
	self.close();
	self.unique_name.free();
	self.outbound.free();
	self.inbox.free();
	self.outbound_fds.free();
	self.descriptors.free();
	self.deferred.free();
	self.pending.free();
	self.subscriptions.free();
	self.names.free();
}

// Asserts, in debug builds, that the caller is the thread that owns this connection.
fn void Connection.check_owner(&self) @inline
{
	assert(self.owner.equals(thread::current()), "a Connection may only be used by the thread that created it");
}

<*
 Connect to the session bus and complete the handshake.

 @return? error::UNAVAILABLE : "No session bus is listening where the address says"
 @return? error::PERMISSION_DENIED : "The bus refused the EXTERNAL credentials"
 @return? error::UNSUPPORTED : "The address uses a transport this library does not implement"
*>
fn void? Connection.open_session(&self)
{
	@pool()
	{
		self.open_address(address::session_address(tmem)!)!;
	};
}

<*
 Connect to the system bus and complete the handshake.

 @return? error::UNAVAILABLE : "No system bus is listening where the address says"
 @return? error::PERMISSION_DENIED : "The bus refused the EXTERNAL credentials"
*>
fn void? Connection.open_system(&self)
{
	@pool()
	{
		self.open_address(address::system_address(tmem))!;
	};
}

<*
 Connect to the first reachable endpoint of `addresses` (see `bleu::dbus::address`),
 authenticate, and say Hello to learn the unique name.

 @return? error::INVALID_STATE : "The connection is already open"
 @return? error::INVALID_ARGUMENT : "The address is malformed"
 @return? error::UNAVAILABLE : "No endpoint accepted a connection"
 @return? error::PERMISSION_DENIED : "The bus refused the EXTERNAL credentials"
*>
fn void? Connection.open_address(&self, String addresses)
{
	self.check_owner();
	if (self.is_open) return error::INVALID_STATE~;
	@pool()
	{
		Endpoint[] endpoints = address::parse_addresses(tmem, addresses)!;
		fault last           = error::UNAVAILABLE;
		foreach (endpoint : endpoints)
		{
			if (catch err = open_endpoint(self, endpoint))
			{
				reset(self);
				last = err;
				continue;
			}
			return;
		}
		return last~;
	};
}

// Connect to one endpoint and run the handshake. Leaves the connection open on success.
fn void? open_endpoint(Connection* c, Endpoint endpoint) @private
{
	c.socket_fd = transport::connect_unix(endpoint.path, endpoint.abstract)!;
	Deadline deadline = deadline::after(time::ms(HANDSHAKE_TIMEOUT_MS));
	c.outbound.append_char(0);
	auth::format_external(&c.outbound, transport::current_uid()!);
	flush_blocking(c, deadline)!;
	Reply ok = auth::parse_reply(read_line(c, deadline)!)!;
	if (ok.kind != OK) return error::PERMISSION_DENIED~;
	auth::format_negotiate_unix_fd(&c.outbound);
	flush_blocking(c, deadline)!;
	Reply answer = auth::parse_reply(read_line(c, deadline)!)!;
	c.fds_negotiated = answer.kind == AGREE_UNIX_FD;
	auth::format_begin(&c.outbound);
	flush_blocking(c, deadline)!;
	c.is_open = true;
	say_hello(c)!;
}

// Hello is the first message on a connection; its reply names the connection.
fn void? say_hello(Connection* c) @private
{
	Message* hello = message::method_call(c.allocator, BUS_NAME, BUS_PATH, BUS_INTERFACE, "Hello")!;
	defer hello.release();
	Message* reply = call(c, hello, time::ms(DEFAULT_TIMEOUT_MS))!;
	defer reply.release();
	Reader r = reply.reader()!;
	c.unique_name.clear();
	c.unique_name.append_string(r.read_string()!);
}

<* Close the connection. Pending calls fail with DISCONNECTED. Idempotent. *>
fn void Connection.close(&self)
{
	self.check_owner();
	reset(self);
}

<*
 The file descriptor to watch with a poller: readable at any time, and also
 writable while `has_pending_output()`.

 @return? error::INVALID_STATE : "The connection is not open"
*>
fn int? Connection.fd(&self)
{
	if (!self.is_open) return error::INVALID_STATE~;
	return self.socket_fd;
}

<* True while queued bytes wait for the socket to take them. *>
fn bool Connection.has_pending_output(&self) @inline => self.sent < (usz)self.outbound.len();

<* The unique name of this connection on the bus, or empty while closed. *>
fn String Connection.name_on_bus(&self) @inline => self.unique_name.str_view();

<*
 Queue `message` for sending and write as much as the socket takes now. The
 serial is assigned here unless the message already has one. Descriptors the
 message carries must stay open until `has_pending_output()` is false.

 @return "The serial of the message"
 @return? error::DISCONNECTED : "The connection is not open, or the peer has gone"
 @return? error::INVALID_ARGUMENT : "The message is too large, or carries too many descriptors"
*>
fn uint? Connection.send(&self, Message* message)
{
	self.check_owner();
	if (!self.is_open) return error::DISCONNECTED~;
	uint serial = queue_message(self, message)!;
	if (catch err = flush(self)) return drop(self, err)~;
	return serial;
}

<*
 Send `message` and block until its reply arrives or `timeout` passes. Other
 messages read in the meantime are queued for the next `process()`.

 @return "The METHOD_RETURN; the caller releases it"
 @return? error::DISCONNECTED : "The connection closed before the reply arrived"
 @return? error::UNAVAILABLE : "The bus has no owner for the destination (error reply)"
 @return? TIMEOUT : "No reply arrived in time; the connection stays open"
*>
fn Message*? Connection.call(&self, Message* message, Duration timeout = time::ms(DEFAULT_TIMEOUT_MS))
{
	self.check_owner();
	return call(self, message, timeout);
}

// The blocking call, shared with the handshake.
fn Message*? call(Connection* c, Message* message, Duration timeout) @private
{
	if (!c.is_open) return error::DISCONNECTED~;
	uint serial       = queue_message(c, message)!;
	Deadline deadline = deadline::after(timeout);
	Message* reply    = null;
	while (true)
	{
		if (catch err = flush(c)) return drop(c, err)~;
		bool eof = read_available(c)!!;
		if (catch err = parse_inbox(c, serial, &reply)) return drop(c, err)~;
		if (reply != null) return finish_reply(reply);
		if (eof) return drop(c, error::DISCONNECTED)~;
		if (deadline.expired()) return TIMEOUT~;
		transport::wait(c.socket_fd, true, c.has_pending_output(), deadline.remaining());
	}
}

// An ERROR reply becomes its fault, and a METHOD_RETURN is handed over as it is.
fn Message*? finish_reply(Message* reply) @private
{
	if (reply.type != ERROR) return reply;
	fault failure = errors::from_reply(reply);
	reply.release();
	return failure~;
}

<*
 Send `message` and return at once. `handler` runs on this connection's thread
 from `process()`, once the reply arrives or `timeout` passes. If the connection
 closes first the handler runs with DISCONNECTED, possibly before this returns.

 @return? error::DISCONNECTED : "The connection is not open"
*>
fn void? Connection.call_async(
	&self,
	Message* message,
	ReplyHandler handler,
	void* context,
	Duration timeout = time::ms(DEFAULT_TIMEOUT_MS)
)
{
	self.check_owner();
	if (!self.is_open) return error::DISCONNECTED~;
	uint serial = queue_message(self, message)!;
	self.pending.push(
		{ .serial = serial, .deadline = deadline::after(timeout), .handler = handler, .context = context }
	);
	if (catch err = flush(self)) return drop(self, err)~;
}

<*
 Do what is possible without blocking: write queued output, read what the
 socket holds, parse complete messages, expire calls past their timeout, and
 run the handlers of everything received.

 @return? error::DISCONNECTED : "The peer closed the connection, or the connection was already closed"
 @return? error::PROTOCOL : "The peer sent malformed data; the connection is closed"
*>
fn void? Connection.process(&self)
{
	self.check_owner();
	if (!self.is_open) return error::DISCONNECTED~;
	if (catch err = flush(self)) return drop(self, err)~;
	bool eof = read_available(self)!!;
	if (catch err = parse_inbox(self, 0, null)) return drop(self, err)~;
	expire_calls(self);
	dispatch(self);
	if (eof || !self.is_open) return drop(self, error::DISCONNECTED)~;
}

// Assigns the serial, encodes the message into the outgoing queue, and records its descriptors.
fn uint? queue_message(Connection* c, Message* message) @private
{
	if (message.serial == 0) message.serial = new_serial(c);
	usz count = (usz)message.fds.len();
	if (count > transport::MAX_DESCRIPTORS) return error::INVALID_ARGUMENT~;
	usz at = (usz)c.outbound.len();
	message.encode(&c.outbound)!;
	if (count > 0)
	{
		int[] fds = alloc::new_array(c.allocator, int, (sz)count);
		for (usz i = 0; i < count; i++) fds[i] = message.fds.get((sz)i);
		c.outbound_fds.push({ .at = at, .fds = fds });
	}
	return message.serial;
}

// The next serial. Serial 0 means "none", so it is skipped when the counter wraps.
fn uint new_serial(Connection* c) @private
{
	uint serial = c.next_serial++;
	if (serial == 0) serial = c.next_serial++;
	return serial;
}

// Writes as much of the outgoing queue as the socket takes without blocking.
// Descriptors go out with the first byte of their message.
fn void? flush(Connection* c) @private
{
	usz total = (usz)c.outbound.len();
	while (c.sent < total)
	{
		bool carries = c.outbound_fds.len() > 0 && c.outbound_fds.get(0).at == c.sent;
		int[] fds    = carries ? c.outbound_fds.get(0).fds : { };
		usz written  = transport::send_some(c.socket_fd, c.outbound.str_view(), c.sent, fds)!;
		if (written == 0) return;
		if (carries)
		{
			alloc::free(c.allocator, c.outbound_fds.get(0).fds.ptr);
			c.outbound_fds.remove_at(0);
		}
		c.sent += written;
	}
	c.outbound.clear();
	c.sent = 0;
}

// Flushes everything, waiting for the socket as needed, until `deadline`.
fn void? flush_blocking(Connection* c, Deadline deadline) @private
{
	while (true)
	{
		flush(c)!;
		if (!c.has_pending_output()) return;
		if (deadline.expired()) return TIMEOUT~;
		transport::wait(c.socket_fd, false, true, deadline.remaining());
	}
}

// The next line of the handshake, copied out of the input buffer.
fn String? read_line(Connection* c, Deadline deadline) @private
{
	while (true)
	{
		if (try end = auth::find_line_end(c.inbox.str_view()))
		{
			String line = c.inbox.str_view()[0:end].copy(tmem);
			c.inbox.delete(0, (sz)end + 2);
			return line;
		}
		if (deadline.expired()) return TIMEOUT~;
		transport::wait(c.socket_fd, true, false, deadline.remaining());
		if (read_available(c)!!) return error::DISCONNECTED~;
	}
}

// Reads everything the socket holds into the input buffer. Returns true at end of stream.
fn bool? read_available(Connection* c) @private
{
	char[RECEIVE_CHUNK] chunk;
	while (true)
	{
		usz? got = transport::recv_some(c.socket_fd, chunk[0:RECEIVE_CHUNK], 0, &c.descriptors);
		if (try n = got)
		{
			if (n == 0) return false;
			c.inbox.append_bytes(chunk[0:n]);
			continue;
		}
		if (catch err = got)
		{
			if (err == error::DISCONNECTED) return true;
			return err~;
		}
	}
}

// Parses every complete message in the input buffer. A reply to `wanted` goes to
// `found` (when it is not null); every other message is queued for dispatch.
fn void? parse_inbox(Connection* c, uint wanted, Message** found) @private
{
	while (c.inbox.len() >= (sz)message::FIXED_HEADER_LENGTH)
	{
		String buffered = c.inbox.str_view();
		usz total       = message::frame_length(buffered[0:message::FIXED_HEADER_LENGTH])!;
		if (c.inbox.len() < (sz)total) return;
		Message* parsed = message::parse(c.allocator, buffered[0:total], &c.descriptors)!;
		c.inbox.delete(0, (sz)total);
		if (wanted != 0 && found != null && *found == null && is_reply_to(parsed, wanted))
		{
			*found = parsed;
		}
		else
		{
			c.deferred.push(parsed);
		}
	}
}

// True when `m` answers the call that was sent with serial `serial`.
fn bool is_reply_to(Message* m, uint serial) @private
{
	return (m.type == METHOD_RETURN || m.type == ERROR) && m.reply_serial == serial;
}

// Runs the handlers of every queued message. Handlers may queue more; those run too.
fn void dispatch(Connection* c) @private
{
	while (c.is_open && c.deferred.len() > 0)
	{
		Message* m = c.deferred.pop_first()!!;
		dispatch_one(c, m);
		m.release();
	}
}

// Routes one message to whoever is waiting for it. Does not release it.
fn void dispatch_one(Connection* c, Message* m) @private
{
	switch (m.type)
	{
		case METHOD_RETURN:
		case ERROR:
			deliver_reply(c, m);
		case SIGNAL:
			observe_owner_change(c, m);
			deliver_signal(c, m);
		case METHOD_CALL:
			answer_unknown(c, m);
		case INVALID:
		case UNKNOWN:
		// Unknown types are ignored, as the specification requires.
	}
}

// Completes the pending call that `m` answers, if any.
fn void deliver_reply(Connection* c, Message* m) @private
{
	foreach (i, call : c.pending)
	{
		if (call.serial != m.reply_serial) continue;
		c.pending.remove_at((sz)i);
		if (m.type == ERROR)
		{
			fault failure = errors::from_reply(m);
			call.handler(call.context, null, error::status_of(failure));
		}
		else
		{
			call.handler(call.context, m, error::Status.OK);
		}
		return;
	}
}

// Calls the handler of every active subscription that accepts `m`.
fn void deliver_signal(Connection* c, Message* m) @private
{
	compact_subscriptions(c);
	for (usz i = 0; i < (usz)c.subscriptions.len(); i++)
	{
		Subscription* s = c.subscriptions.get((sz)i);
		if (!s.active) continue;
		if (s.rule.accepts(m, sender_owner(c, s.rule.sender))) s.handler(s.context, m);
	}
}

// Frees subscriptions that were deactivated. Runs only outside signal delivery.
fn void compact_subscriptions(Connection* c) @private
{
	for (sz i = (sz)c.subscriptions.len() - 1; i >= 0; i--)
	{
		Subscription* s = c.subscriptions.get((sz)i);
		if (s.active) continue;
		c.subscriptions.remove_at((sz)i);
		free_subscription(c, s);
	}
}

// The unique name a sender refers to: a unique name is its own owner; a well-known
// name is looked up in the owner cache, and is empty when it is not tracked.
fn String sender_owner(Connection* c, String sender) @private
{
	if (sender.len == 0) return "";
	if (sender[0] == ':') return sender;
	foreach (entry : c.names)
	{
		if (entry.name.str_view() == sender) return entry.owner.str_view();
	}
	return "";
}

// Keeps the owner cache current from the bus's NameOwnerChanged signals.
fn void observe_owner_change(Connection* c, Message* m) @private
{
	if (m.sender != BUS_NAME || m.interface_name != BUS_INTERFACE || m.member != "NameOwnerChanged") return;
	if (try r = m.reader())
	{
		if (try name = r.read_string())
		{
			if (catch r.read_string()) return;
			if (try owner = r.read_string()) set_owner(c, name, owner);
		}
	}
}

// Answers a method call that no one implements here. Peer.Ping gets its empty
// reply, as the specification requires of every peer; everything else gets
// UnknownMethod. (The service answers its own methods once it exports objects.)
fn void answer_unknown(Connection* c, Message* m) @private
{
	if ((m.flags & message::FLAG_NO_REPLY_EXPECTED) != 0) return;
	if (m.interface_name == PEER_INTERFACE && m.member == "Ping")
	{
		if (try reply = message::reply(c.allocator, m)) send_or_drop(c, reply);
		return;
	}
	if (try reply = message::error_reply(
		c.allocator,
		m,
		"org.freedesktop.DBus.Error.UnknownMethod",
		"no such method is implemented here"
	))
	{
		send_or_drop(c, reply);
	}
}

// Sends a reply built for an incoming call and releases it. If sending fails the
// connection has closed, and the next call reports that.
fn void send_or_drop(Connection* c, Message* reply) @private
{
	defer reply.release();
	if (catch c.send(reply))
	{
	}
}

// Fails every call whose deadline has passed. The handlers run after the list is updated.
fn void expire_calls(Connection* c) @private
{
	@pool()
	{
		List{PendingCall} expired;
		expired.init(tmem);
		for (sz i = (sz)c.pending.len() - 1; i >= 0; i--)
		{
			if (!c.pending.get((sz)i).deadline.expired()) continue;
			expired.push(c.pending.get((sz)i));
			c.pending.remove_at((sz)i);
		}
		foreach (call : expired)
		{
			call.handler(call.context, null, error::Status.TIMEOUT);
		}
	};
}

// Closes the socket and forgets everything held for it. Pending calls fail with
// DISCONNECTED. Safe to call on a connection that is already closed.
fn void reset(Connection* c) @private
{
	if (c.socket_fd >= 0)
	{
		transport::close_fd(c.socket_fd);
		c.socket_fd = -1;
	}
	c.is_open = false;
	c.fds_negotiated = false;
	c.unique_name.clear();
	c.outbound.clear();
	c.sent = 0;
	foreach (entry : c.outbound_fds) alloc::free(c.allocator, entry.fds.ptr);
	c.outbound_fds.clear();
	c.inbox.clear();
	foreach (fd : c.descriptors) transport::close_fd(fd);
	c.descriptors.clear();
	foreach (m : c.deferred) m.release();
	c.deferred.clear();
	clear_subscriptions(c);
	clear_names(c);
	fail_pending(c);
}

// Frees every subscription, active or not.
fn void clear_subscriptions(Connection* c) @private
{
	foreach (s : c.subscriptions) free_subscription(c, s);
	c.subscriptions.clear();
}

// Frees one subscription with everything it owns.
fn void free_subscription(Connection* c, Subscription* s) @private
{
	s.rule.free();
	if (s.owned != null) alloc::free(c.allocator, s.owned);
	alloc::free(c.allocator, s);
}

// Frees the owner cache.
fn void clear_names(Connection* c) @private
{
	foreach (entry : c.names)
	{
		entry.name.free();
		entry.owner.free();
		alloc::free(c.allocator, entry);
	}
	c.names.clear();
}

// Hands every pending call the DISCONNECTED status. Runs last in `reset`, when
// the connection is already in its closed state.
fn void fail_pending(Connection* c) @private
{
	@pool()
	{
		PendingCall[] calls = c.pending.to_aligned_array(tmem);
		c.pending.clear();
		foreach (call : calls)
		{
			call.handler(call.context, null, error::Status.DISCONNECTED);
		}
	};
}

// Closes the connection after a failure and returns the failure, for `return drop(...)~`.
fn fault drop(Connection* c, fault failure) @private
{
	reset(c);
	return failure;
}

<*
 Register a handler for the messages `rule` accepts. The connection takes
 ownership of `rule`, and of `owned` if it is not null (it is freed with the
 subscription): do not free either afterwards. Nothing is sent to the bus here;
 `bus::subscribe` registers the handler and asks the bus for the messages.

 @return "Identifier for `deactivate`"
*>
fn SubscriptionId Connection.add_subscription(
	&self,
	match::Match rule,
	SignalHandler handler,
	void* context,
	void* owned = null
)
{
	Subscription* s = alloc::new(self.allocator, Subscription);
	*s = {
		.id = (SubscriptionId)self.next_subscription++,
		.active = true,
		.rule = rule,
		.handler = handler,
		.context = context,
		.owned = owned
	};
	self.subscriptions.push(s);
	return s.id;
}

<*
 The active subscription with this identifier.

 @return? NOT_FOUND : "No active subscription has this identifier"
*>
fn Subscription*? Connection.subscription(&self, SubscriptionId id)
{
	foreach (s : self.subscriptions)
	{
		if (s.active && s.id == id) return s;
	}
	return NOT_FOUND~;
}

<* Stop delivering to a subscription. Its rule is freed at the next signal delivery. *>
fn void Connection.deactivate(&self, SubscriptionId id)
{
	foreach (s : self.subscriptions)
	{
		if (s.id == id) s.active = false;
	}
}

<* True when the owner cache follows this well-known name. *>
fn bool Connection.tracks_name(&self, String name)
{
	foreach (entry : self.names)
	{
		if (entry.name.str_view() == name) return true;
	}
	return false;
}

<* The unique name that owns `name`, as the bus last reported it; empty when unowned or untracked. *>
fn String Connection.owner_of(&self, String name) => sender_owner(self, name);

<*
 Record the owner of a well-known name, starting to track it if needed. An
 empty `owner` means the name is unowned.
*>
fn void Connection.set_owner(&self, String name, String owner) => set_owner(self, name, owner);

fn void set_owner(Connection* c, String name, String owner) @private
{
	foreach (entry : c.names)
	{
		if (entry.name.str_view() != name) continue;
		entry.owner.clear();
		entry.owner.append_string(owner);
		return;
	}
	NameOwner* entry = alloc::new(c.allocator, NameOwner);
	entry.name.init(c.allocator);
	entry.name.append_string(name);
	entry.owner.init(c.allocator);
	entry.owner.append_string(owner);
	c.names.push(entry);
}