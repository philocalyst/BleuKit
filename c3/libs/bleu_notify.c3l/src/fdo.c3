<*
 The freedesktop notification server: this process owns org.freedesktop.Notifications
 on the session bus, answers Notify, CloseNotification, GetCapabilities and
 GetServerInformation, and emits NotificationClosed and ActionInvoked.

 The whole server runs on the worker thread, because a bus connection belongs to
 the thread that made it. Commands from the shell arrive on the mailbox; timers
 for expiry live in a `TimerQueue` that the poller's timeout follows.
*>
module bleu::notify::fdo @feat(LINUX);
import std::time, bleu::error, bleu::availability, bleu::observe, bleu::operation, bleu::dbus::address, bleu::dbus::bus, bleu::dbus::connection, bleu::dbus::ownership, bleu::dbus::server, bleu::dbus::value, bleu::rt::poller, bleu::rt::timers, bleu::rt::worker, bleu::notify, bleu::notify::store;

const String SERVICE_NAME = "org.freedesktop.Notifications";
const String OBJECT_PATH  = "/org/freedesktop/Notifications";
const String INTERFACE    = "org.freedesktop.Notifications";

// The notification server's own identity, reported by GetServerInformation. spec_version is the spec we implement.
const String SERVER_NAME    = "bleu";
const String SERVER_VENDOR  = "Bleu";
const String SERVER_VERSION = "0.1";
const String SPEC_VERSION   = "1.3";

// Tag of the poller source that is the bus connection.
const usz BUS_TAG = 1;

// Commands taken from the mailbox per round, and timers popped per round.
const usz COMMAND_BATCH = 8;
const usz TIMER_BATCH   = 8;

<* The state behind the backend handle: what `create` made and `run` uses. *>
struct Backend
{
	Allocator allocator;
	bool replace;
	notify::Policy policy;
	notify::StartOp* startup;
}

<*
 Everything `serve` owns on the worker: the store, the expiry timers, the
 publication target and the flags the bus callbacks set.
*>
struct Session
{
	store::Store store;
	timers::TimerQueue timers;
	notify::NotifyHub* hub;
	server::ObjectServer* objects;
	bool serving;
	bool name_lost;
}

const notify::Driver DRIVER = {
	.info = { "fdo", "freedesktop notification server on the session bus (org.freedesktop.Notifications)", 10 },
	.id = notify::Backend.FDO,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

// The session bus is where the server lives. Probing only checks that an address is configured.
fn bool probe(notify::Options* options)
{
	@pool()
	{
		if (try location = address::session_address(tmem)) return location.len > 0;
		return false;
	};
}

fn void*? create(
	Allocator allocator,
	notify::Options options,
	notify::Capabilities* capabilities,
	notify::StartOp* startup
)
{
	capabilities.init(availability::YES);
	capabilities.set(
		notify::Cap.ACTIVATION_TOKEN,
		availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"no activation token source: a daemon that is not focused cannot obtain one"
		)
	);
	capabilities.set(
		notify::Cap.PERSISTENCE,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "history is kept in memory only")
	);
	capabilities.set(
		notify::Cap.SOUND,
		availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"sound hints are recorded for the shell; nothing plays them"
		)
	);
	Backend* backend = alloc::new(allocator, Backend);
	*backend = { .allocator = allocator, .replace = options.replace, .policy = options.policy, .startup = startup };
	return backend;
}

fn void destroy(Allocator allocator, void* state)
{
	alloc::free(allocator, state);
}

// The worker entry. Reports the start-up outcome, serves until stopped or the bus is lost, then refuses what is still queued.
fn void run(void* state, notify::NotifyHub* hub, Host{Command}* host)
{
	Backend* backend         = (Backend*)state;
	notify::StartOp* startup = backend.startup;
	defer startup.release();
	if (catch err = serve(backend, hub, host)) (void)startup.fail(err);
	refuse_until_stopped(backend.allocator, host);
}

// The server's life: connect, take the name, then loop over bus traffic, timers and commands.
fn void? serve(Backend* backend, notify::NotifyHub* hub, Host{Command}* host)
{
	Description description;
	Connection conn;
	conn.init(backend.allocator);
	defer conn.free();
	conn.open_session()!;
	Session session = { .hub = hub };
	session.store.init(backend.allocator, backend.policy);
	defer session.store.free();
	session.timers.init(backend.allocator);
	defer session.timers.free();
	server::ObjectServer objects;
	objects.init(backend.allocator);
	defer objects.free();
	session.objects = &objects;
	describe(&description, &session);
	objects.export(OBJECT_PATH, description.interfaces[..])!;
	objects.attach(&conn);
	OwnedName* owned = claim_name(backend, &conn, &session)!;
	defer release_name(owned);
	(void)backend.startup.succeed(true);
	session.serving = true;
	defer stopped(&session);
	publish(&session);
	Poller io;
	io.init(backend.allocator, host.wakeup(), 2)!;
	defer io.free();
	io.add({ .handle = (Native)conn.fd()!, .interest = { .readable = true }, .tag = BUS_TAG })!;
	bool writable = false;
	notify::Command[COMMAND_BATCH] commands;
	usz[TIMER_BATCH] expired;
	while (!host.stopping() && !session.name_lost)
	{
		Duration until = session.timers.next_timeout();
		if (catch err = io.wait(until))
		{
			if (err != TIMEOUT) return err~;
		}
		conn.process()!;
		usz count = session.timers.pop_expired(expired[..]);
		for (usz k = 0; k < count; k++) expire(&session, (notify::NoteId)expired[k])!;
		while (true)
		{
			usz taken = host.mailbox().take_all(commands[..]);
			if (taken == 0) break;
			for (usz k = 0; k < taken; k++)
				{
					if (catch err = execute(&session, &commands[k]))
					{
						// The bus failed: refuse the commands taken but not yet run, so no operation stays pending.
						for (usz rest = k + 1; rest < taken; rest++) refuse(&commands[rest]);
						return err~;
					}
				}
		}
		conn.process()!;
		if (conn.has_pending_output() != writable)
		{
			writable = !writable;
			io.remove(BUS_TAG)!;
			io.add(
				{ .handle = (Native)conn.fd()!, .interest = { .readable = true, .writable = writable }, .tag = BUS_TAG }
			)!;
		}
	}
	if (session.name_lost) return error::raise(
		error::UNAVAILABLE,
		error::Domain.DBUS,
		0,
		"%s was taken by another daemon",
		SERVICE_NAME
	)~;
}