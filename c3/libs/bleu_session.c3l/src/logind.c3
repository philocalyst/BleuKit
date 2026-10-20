<*
 The Linux mechanism: systemd-logind on the system bus (org.freedesktop.login1).

 One worker thread owns the bus connection. Signals arrive inside `Connection.process`, where
 the handlers only record what happened; the loop then reads logind, publishes the state, and
 announces the events, so no handler blocks on a method call.

 What logind gives: the lock state (`LockedHint`) and idle hint of the session this process
 runs in, the session and seat lists, `PrepareForSleep`, and the lock, unlock and terminate
 requests. What it does not give: idle time. logind stores `IdleHint` for the shell that sets
 it; nothing here measures input, so `watch_idle` is refused on this backend.

 Sources (see docs/research/session_windows_input.md, section 2 "Linux", route L1):
 * systemd `org.freedesktop.login1(5)` manual page: Manager methods GetSessionByPID,
 GetSession, ListSessions, ListSeats, LockSession, UnlockSession, TerminateSession; the
 Manager signal PrepareForSleep(b start); the Session properties Id, User, Name, Seat, Type,
 Active, Remote, LockedHint, IdleHint.
 * `bleu::power`'s logind backend (`libs/bleu_power.c3l/src/linux_logind.c3`), which uses the
 same bus name, session discovery and sleep signal.
*>
module bleu::session::logind @feat(LINUX);
import std::collections::list, std::collections::maybe, std::time, bleu::availability, bleu::dbus::connection, bleu::dbus::match, bleu::dbus::message, bleu::dbus::proxy, bleu::dbus::value, bleu::error, bleu::observe, bleu::rt, bleu::rt::poller, bleu::rt::worker, bleu::session;

extern fn int getpid() @cname("getpid");

const String LOGIND_BUS        = "org.freedesktop.login1";
const String LOGIND_PATH       = "/org/freedesktop/login1";
const String LOGIND_MANAGER    = "org.freedesktop.login1.Manager";
const String LOGIND_SESSION    = "org.freedesktop.login1.Session";
const String PREPARE_FOR_SLEEP = "PrepareForSleep";
const String SESSION_NEW       = "SessionNew";
const String SESSION_REMOVED   = "SessionRemoved";

<* The poller's tag for the bus connection. The worker's wake-up is not tagged (see bleu_rt). *>
const usz BUS_TAG            = 1;
<*
 Longest the loop sleeps when nothing happens. It bounds how late a missed signal is seen;
 the signals themselves are what normally wakes the loop.
*>
const Duration WAIT_INTERVAL = (Duration)5_000_000;
<* Commands taken from the mailbox per batch. *>
const usz COMMAND_BATCH      = 8;

const Driver DRIVER = {
	.info = { "logind", "systemd-logind over the system bus (org.freedesktop.login1)", 10 },
	.id = LOGIND,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

<*
 The worker's state. `session` is this process's logind session; it is absent for a process
 that is not in one (a system service), and the session features then stay empty.
*>
struct Logind
{
	Allocator allocator;
	String bus_address; // "" for the system bus; copied at create
	Connection bus;
	bool connected;
	Proxy manager;
	bool has_session;
	String session_path; // copied; the object path of `session`
	Proxy session;
	String session_id; // copied; the logind id of `session`
	Maybe{bool} locked; // LockedHint, as last read
	bool sleeping;
	bool dirty; // a signal or a request says the state is stale
	List{Event} pending; // PrepareForSleep edges, recorded by the handler
}

<* logind is on the system bus (or the address given) and owns its name there. *>
fn bool probe(Options* options)
{
	Connection connection;
	connection.init(mem);
	defer connection.free();
	if (catch open_bus(&connection, options.bus_address)) return false;
	defer connection.close();
	if (try owned = connection.name_has_owner(LOGIND_BUS)) return owned;
	return false;
}

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	capabilities.set(
		Cap.LOCK_STATE,
		availability::no(
			availability::Reason.DEGRADED,
			"Known only inside a logind session: a process outside one reads no lock state"
		)
	);
	capabilities.set(
		Cap.LOCK,
		availability::no(availability::Reason.DEGRADED, "Locks the logind session this process runs in")
	);
	capabilities.set(
		Cap.UNLOCK,
		availability::no(
			availability::Reason.DEGRADED,
			"logind only signals the session's locker, which still authenticates; polkit may refuse"
		)
	);
	capabilities.set(
		Cap.IDLE_WATCH,
		availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"No idle source here: bleu_wl has the ext-idle-notify bindings, but no backend uses them yet, and logind does not measure idle time"
		)
	);
	capabilities.set(
		Cap.IDLE_HINT,
		availability::no(availability::Reason.DEGRADED, "Only as accurate as the shell that sets IdleHint")
	);
	Logind* backend = alloc::new(allocator, Logind);
	backend.allocator = allocator;
	backend.pending.init(allocator);
	if (options.bus_address.len > 0) backend.bus_address = options.bus_address.copy(allocator);
	return backend;
}

fn void destroy(Allocator allocator, void* state)
{
	Logind* backend = (Logind*)state;
	forget_session(backend);
	if (backend.bus_address.len > 0) alloc::free(allocator, backend.bus_address.ptr);
	backend.pending.free();
	alloc::free(allocator, backend);
}

<* Open the bus at `address`, or the system bus when it is "". *>
fn void? open_bus(Connection* connection, String address)
{
	if (address.len > 0)
	{
		connection.open_address(address)!;
		return;
	}
	connection.open_system()!;
}

<*
 Open the bus, subscribe to the signals and register the connection with the poller, then find
 this process's session. On failure nothing stays open.

 @return? error::UNAVAILABLE : "when the bus cannot be reached"
*>
fn void? connect(Logind* b, Poller* poller)
{
	b.bus.init(b.allocator);
	if (catch err = open_bus(&b.bus, b.bus_address))
	{
		b.bus.free();
		return err~;
	}
	b.manager = proxy::for_object(&b.bus, LOGIND_BUS, LOGIND_PATH, LOGIND_MANAGER)!;
	if (catch err = subscribe(b))
	{
		b.bus.close();
		b.bus.free();
		return err~;
	}
	int fd = b.bus.fd()!;
	if (catch err = poller.add({ .handle = (rt::Native)fd, .interest = { .readable = true }, .tag = BUS_TAG }))
	{
		b.bus.close();
		b.bus.free();
		return err~;
	}
	b.connected = true;
	// A session that cannot be read leaves the session features off until the next connection.
	if (catch err = find_session(b))
	{
		if (err == error::DISCONNECTED)
		{
			disconnect(b, poller);
			return err~;
		}
	}
}

<* Close the connection and take it out of the poller. Safe when not connected. *>
fn void disconnect(Logind* b, Poller* poller)
{
	if (!b.connected) return;
	b.connected = false;
	if (catch poller.remove(BUS_TAG))
	{
		// Not registered: nothing to remove.
	}
	b.bus.close();
	b.bus.free();
	forget_session(b);
	b.locked = { };
}

<* Drop this process's session, so that the next connection finds it again. *>
fn void forget_session(Logind* b)
{
	if (b.session_path.len > 0) alloc::free(b.allocator, b.session_path.ptr);
	if (b.session_id.len > 0) alloc::free(b.allocator, b.session_id.ptr);
	b.session_path = "";
	b.session_id = "";
	b.has_session = false;
}

<*
 The subscriptions the connection needs: property changes under the logind object tree (every
 session), and the Manager signals PrepareForSleep, SessionNew and SessionRemoved. They end
 with the connection.
*>
fn void? subscribe(Logind* b)
{
	proxy::Proxy root = b.manager;
	if (catch err = root.watch_properties(&on_properties, b, true)) return err~;
	subscribe_signal(b, PREPARE_FOR_SLEEP, &on_prepare_for_sleep)!;
	subscribe_signal(b, SESSION_NEW, &on_session_list)!;
	subscribe_signal(b, SESSION_REMOVED, &on_session_list)!;
}

<* One Manager signal of logind, by member name. *>
fn void? subscribe_signal(Logind* b, String member, connection::SignalHandler handler)
{
	match::Match rule;
	rule.init(b.allocator);
	rule.with_type(message::MessageType.SIGNAL)!!;
	rule.with_sender(LOGIND_BUS)!!;
	rule.with_interface(LOGIND_MANAGER)!!;
	rule.with_path(LOGIND_PATH)!!;
	rule.with_member(member)!!;
	if (catch err = b.bus.subscribe(rule, handler, b)) return err~;
}

<* Property changes anywhere under logind's tree: the state is read again. *>
fn void on_properties(void* context, proxy::PropertyChange* change) @local
{
	Logind* b = (Logind*)context;
	b.dirty = true;
}

<* A session or seat appeared or went away: the lists are read again. *>
fn void on_session_list(void* context, Message* signal) @local
{
	Logind* b = (Logind*)context;
	b.dirty = true;
}

<*
 `PrepareForSleep(b start)`: true before the system sleeps, false after it resumes. Recorded for
 the loop, which announces it after publishing.
*>
fn void on_prepare_for_sleep(void* context, Message* signal) @local
{
	Logind* b = (Logind*)context;
	// A malformed signal cannot be answered; the bus library checks the signature.
	if (try reader = signal.reader())
	{
		if (try starting = reader.read_bool())
		{
			b.pending.push({ .kind = starting ? EventKind.WILL_SLEEP : EventKind.DID_WAKE });
			b.dirty = true;
		}
	}
}

<*
 Find this process's logind session, if it has one. Not being in one, or logind refusing to
 say, leaves the session features off without an error. A lost bus is an error.
*>
fn void? find_session(Logind* b)
{
	Message* call = b.manager.new_call(b.allocator, "GetSessionByPID")!;
	defer call.release();
	call.body_writer("u")!.append_u32((uint)getpid())!;
	Message*? reply = b.bus.call(call);
	if (catch err = reply)
	{
		// Not in a session (a system service), or logind refused: the session features stay off.
		if (err == error::DISCONNECTED) return err~;
		return;
	}
	defer reply.release();
	String path = reply.reader()!.read_object_path()!;
	b.session_path = path.copy(b.allocator);
	b.session = proxy::for_object(&b.bus, LOGIND_BUS, b.session_path, LOGIND_SESSION)!;
	@pool()
	{
		Value props = b.session.get_all_properties(tmem)!;
		String id   = prop_text(props, "Id", tmem);
		b.session_id = id.copy(b.allocator);
	};
	b.has_session = true;
}

<*
 Read logind into a snapshot, then publish it and announce what changed. Called on the worker
 thread, and only from there.
*>
fn void refresh(Logind* b, SessionHub* hub)
{
	List{Event} changes;
	changes.init(mem);
	defer changes.free();
	// Sleep edges are changes of the state. Apply them before reading, so the snapshot shows them.
	session::apply_pending(&b.pending, &b.locked, &b.sleeping);
	for (sz i = 0; i < b.pending.len(); i++) changes.push(b.pending.get(i));
	b.pending.clear();
	Maybe{bool} before        = b.locked;
	Snapshot{State}* snapshot = hub.begin();
	if (try state = read_state(b, snapshot.allocator()))
	{
		snapshot.value = state;
	}
	else
	{
		snapshot.value = { .sleeping = b.sleeping };
	}
	if (before.has_value && b.locked.has_value && before.value != b.locked.value)
	{
		changes.push({ .kind = b.locked.value ? EventKind.LOCKED : EventKind.UNLOCKED });
	}
	hub.publish_if_changed(snapshot);
	session::announce(&changes, hub);
}

<*
 Dispatch what the bus has: the socket, and the messages that earlier calls read into the
 connection's inbox. A lost bus disconnects; the next tick reconnects.
*>
fn void pump(Logind* b, Poller* poller)
{
	if (!b.connected) return;
	if (catch b.bus.process())
	{
		// The bus went away: the next tick reconnects.
		disconnect(b, poller);
		b.dirty = true;
	}
}

<* The worker: connect, then wait for signals, requests and the interval, and refresh. *>
fn void run(void* state, SessionHub* hub, Host{Command}* host)
{
	Logind* b = (Logind*)state;
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 1)) return;
	defer poller.free();
	if (catch connect(b, &poller))
	{
		// logind is not reachable yet: each tick tries again, and the state stays empty.
	}
	refresh(b, hub);
	pump(b, &poller);
	Command[COMMAND_BATCH] commands;
	while (!host.stopping())
	{
		// A change already known (a signal dispatched by the last pump) needs no wait. Otherwise
		// sleep until the interval passes, the bus has data, or a command is queued. The poller only
		// sees the socket, so a signal read during a call must never be the reason for a sleep.
		bool timed_out = false;
		if (!b.dirty)
		{
			if (catch poller.wait(WAIT_INTERVAL))
			{
				timed_out = true;
			}
		}
		pump(b, &poller);
		usz count = host.mailbox().take_all(commands[..]);
		for (usz i = 0; i < count; i++) execute(b, &commands[i]);
		if (!b.connected)
		{
			if (catch connect(b, &poller))
			{
				// Still unreachable; the empty state stands.
			}
		}
		if (timed_out || count > 0 || b.dirty)
		{
			b.dirty = false;
			refresh(b, hub);
		}
		// The calls above may have read signals into the inbox. Dispatch them now, so that the
		// next pass knows about them.
		pump(b, &poller);
	}
	disconnect(b, &poller);
}