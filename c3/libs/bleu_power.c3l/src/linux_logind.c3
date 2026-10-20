<*
 The Linux mechanism: systemd-logind on the system bus for actions, inhibitors,
 the lid, external power, idle hint and sleep; power-profiles-daemon for the
 profile when it is on the bus (modern interface first, legacy second).

 One worker thread owns the bus connection. Native signals arrive inside
 `Connection.process`, where the handlers only record what happened; the loop
 then publishes state and events and runs queued requests, so no handler ever
 blocks on a method call.

 Sources (see docs/research/battery_power.md, L-P1 and L-P3, for the verified
 signatures):
 * login1 manual page, org.freedesktop.login1(5): Manager methods and
 properties, `Can*` answers, PrepareForSleep.
 * systemd docs/INHIBITOR_LOCKS.md: Inhibit returns a descriptor; closing it
 releases the lock; delay locks are released on PrepareForSleep.
 * power-profiles-daemon src/power-profiles-daemon.c: HoldProfile, ReleaseProfile,
 ActiveProfile, PerformanceDegraded, Profiles.
*>
module bleu::power::logind @feat(LINUX);
import std::collections::list, std::collections::maybe, std::io::path, std::os::env, std::time, bleu::availability, bleu::dbus::connection, bleu::dbus::match, bleu::dbus::message, bleu::dbus::proxy, bleu::dbus::value, bleu::error, bleu::power, bleu::power::convert, bleu::rt::poller, bleu::rt::unix, bleu::observe, bleu::service, bleu::rt::worker;

extern fn int getpid() @cname("getpid");

const DRIVER_NAME_TEXT           = "systemd-logind over the system bus";
const String SYSTEMD_RUNTIME_DIR = "/run/systemd/system";
const String SYSTEM_BUS_VARIABLE = "DBUS_SYSTEM_BUS_ADDRESS";

const String LOGIND_BUS        = "org.freedesktop.login1";
const String LOGIND_PATH       = "/org/freedesktop/login1";
const String LOGIND_MANAGER    = "org.freedesktop.login1.Manager";
const String LOGIND_SESSION    = "org.freedesktop.login1.Session";
const String PREPARE_FOR_SLEEP = "PrepareForSleep";

const String PPD_MODERN_BUS  = "org.freedesktop.UPower.PowerProfiles";
const String PPD_MODERN_PATH = "/org/freedesktop/UPower/PowerProfiles";
const String PPD_LEGACY_BUS  = "net.hadess.PowerProfiles";
const String PPD_LEGACY_PATH = "/net/hadess/PowerProfiles";

<* What this process tells the daemons it is doing, for the inhibitor and profile lists. *>
const String APPLICATION_ID = "org.bleu.power";
const String BARRIER_WHO    = "bleu";
const String BARRIER_WHY    = "Save state before sleep";

<* The poller's tag for the bus connection. *>
const usz BUS_TAG            = 1;
<* Longest the loop sleeps when nothing happens; bounds how late a missed signal is seen. *>
const Duration WAIT_INTERVAL = (Duration)1_000_000;
<* Commands taken from the mailbox per batch. *>
const usz COMMAND_BATCH      = 16;

const Driver DRIVER = {
	.info = { "logind", DRIVER_NAME_TEXT, 10 },
	.id = LOGIND,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

<* An inhibitor (or the sleep barrier) this worker holds: the descriptor keeps it alive. *>
struct HeldLock
{
	uint id;
	unix::Fd fd;
}

<* A sleep transition reported by logind, recorded by the handler and acted on by the loop. *>
enum SleepSignal : char
{
	PREPARE,
	RESUME,
}

struct Logind
{
	Allocator allocator;
	String bus_address; // "" for the system bus default
	bool sleep_barrier;
	Capabilities* capabilities;
	Startup* startup;
	PowerHub* hub;
	Connection bus;
	bool bus_alive;
	bool bus_registered;
	Proxy manager;
	bool has_session;
	Proxy session;
	String session_path;
	bool has_profiles;
	bool has_modern_profiles;
	Proxy profiles;
	List{HeldLock} locks;
	uint next_lock;
	unix::Fd barrier; // the delay lock held across a sleep, open while a PREPARE_SLEEP waits for ack
	uint barrier_ticket; // the ticket that `ack` must carry to close `barrier`; 0 when none
	uint next_ticket;
	List{SleepSignal} sleep_signals;
	bool dirty; // a property changed; re-read the state
	Maybe{bool} last_lid; // last reading, for LID_CLOSED and LID_OPENED
	Maybe{bool} last_external; // last reading, for EXTERNAL_POWER_*
}

<*
 Systemd is running, or a system bus address is given (by the options or by
 DBUS_SYSTEM_BUS_ADDRESS, which the bus library reads).
*>
fn bool probe(Options* options)
{
	if (options.bus_address.len > 0) return true;
	if (try variable = env::tget_var(SYSTEM_BUS_VARIABLE)) return variable.len > 0;
	return path::is_dir((Path)SYSTEMD_RUNTIME_DIR);
}

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities, Startup* startup)
{
	Logind* backend = alloc::new(allocator, Logind);
	backend.allocator = allocator;
	// A zeroed Fd is descriptor 0, which is open: the barrier starts empty only when it says so.
	backend.barrier = { .value = unix::FD_NONE };
	if (options.bus_address.len > 0) backend.bus_address = options.bus_address.copy(allocator);
	backend.sleep_barrier = options.sleep_barrier;
	backend.capabilities = capabilities;
	backend.startup = startup;
	return backend;
}

fn void destroy(Allocator allocator, void* state)
{
	Logind* backend = (Logind*)state;
	if (backend.bus_address.len > 0) alloc::free(allocator, backend.bus_address.ptr);
	if (backend.session_path.len > 0) alloc::free(allocator, backend.session_path.ptr);
	alloc::free(allocator, backend);
}

<* Record a failed call. A lost connection ends the bus for good; other failures leave their fields unknown. *>
fn void Logind.note_failure(&self, fault failure)
{
	if (failure == error::DISCONNECTED) self.bus_alive = false;
}

fn void run(void* state, PowerHub* hub, Host{Command}* host)
{
	Logind* backend = (Logind*)state;
	backend.hub = hub;
	backend.bus.init(backend.allocator);
	if (catch err = start(backend))
	{
		backend.startup.fail(err);
	}
	else
	{
		backend.startup.succeed();
		serve(backend, host);
	}
	shutdown(backend, host);
}

<* Connect, find what is there, subscribe to changes, and read the first state. *>
fn void? start(Logind* b)
{
	if (b.bus_address.len > 0)
	{
		b.bus.open_address(b.bus_address)!;
	}
	else
	{
		b.bus.open_system()!;
	}
	b.bus_alive = true;
	b.manager = proxy::for_object(&b.bus, LOGIND_BUS, LOGIND_PATH, LOGIND_MANAGER)!;
	// Probe logind before anything else: when it is absent, nothing below can work.
	b.manager.get_all_properties(b.allocator)!;
	find_session(b)!;
	find_profiles(b)!;
	subscribe(b)!;
	if (b.sleep_barrier) take_barrier(b)!;
	fill_capabilities(b);
	refresh(b);
}

<* Watch the properties and the sleep signal. The handlers only record what happened. *>
fn void? subscribe(Logind* b)
{
	b.manager.watch_properties(&on_property_change, b)!;
	if (b.has_profiles) b.profiles.watch_properties(&on_property_change, b)!;
	match::Match rule;
	rule.init(b.allocator);
	rule.with_type(MessageType.SIGNAL)!!;
	rule.with_sender(LOGIND_BUS)!!;
	rule.with_interface(LOGIND_MANAGER)!!;
	rule.with_member(PREPARE_FOR_SLEEP)!!;
	rule.with_path(LOGIND_PATH)!!;
	b.bus.subscribe(rule, &on_prepare_for_sleep, b)!;
}

fn void on_property_change(void* context, proxy::PropertyChange* change)
{
	Logind* b = (Logind*)context;
	b.dirty = true;
}

// `PrepareForSleep(b start)`: true before the system sleeps, false after it resumes.
fn void on_prepare_for_sleep(void* context, Message* signal)
{
	Logind* b = (Logind*)context;
	// A malformed signal cannot be answered; the signature is checked by the bus library.
	if (try reader = signal.reader())
	{
		if (try starting = reader.read_bool())
		{
			b.sleep_signals.push(starting ? PREPARE : RESUME);
		}
	}
}

<* Find this process's logind session, if it has one. Only a lost bus is an error here. *>
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
	b.has_session = true;
}

<* Use power-profiles-daemon's modern interface when it answers, else the legacy one. *>
fn void? find_profiles(Logind* b)
{
	Proxy modern = proxy::for_object(&b.bus, PPD_MODERN_BUS, PPD_MODERN_PATH, PPD_MODERN_BUS)!;
	if (daemon_answers(&modern)!)
	{
		b.profiles = modern;
		b.has_profiles = true;
		b.has_modern_profiles = true;
		return;
	}
	Proxy legacy = proxy::for_object(&b.bus, PPD_LEGACY_BUS, PPD_LEGACY_PATH, PPD_LEGACY_BUS)!;
	if (daemon_answers(&legacy)!)
	{
		b.profiles = legacy;
		b.has_profiles = true;
	}
}

// True when the object answers a property read. The bus is only probed, so a
// daemon that is merely absent is not an error; a lost connection is.
fn bool? daemon_answers(Proxy* proxy)
{
	@pool()
	{
		if (catch err = proxy.get_all_properties(tmem))
		{
			if (err == error::DISCONNECTED) return err~;
			return false;
		}
		return true;
	};
}

// Each capability the Linux mechanism offers, decided by what was found above.
fn void fill_capabilities(Logind* b)
{
	Capabilities* caps    = b.capabilities;
	Availability profiles = b.has_profiles ? availability::YES
		: availability::no(availability::Reason.BACKEND_MISSING, "power-profiles-daemon is not on the system bus");
	caps.set(PROFILE_READ, profiles);
	caps.set(PROFILE_SET, profiles);
	caps.set(
		PROFILE_HOLD,
		b.has_modern_profiles ? availability::YES
			: availability::no(
				availability::Reason.UNSUPPORTED_BACKEND,
				"holds need the modern power-profiles-daemon interface"
			)
	);
	caps.set(
		LOW_POWER_READ,
		availability::no(
			availability::Reason.UNSUPPORTED_OS,
			"Linux has no Low Power Mode flag; use the power-saver profile"
		)
	);
	caps.set(
		BATTERY_SAVER_READ,
		availability::no(availability::Reason.UNSUPPORTED_OS, "Linux has no battery saver flag")
	);
	caps.set(KEEP_AWAKE_IDLE, availability::YES);
	caps.set(
		KEEP_AWAKE_DISPLAY,
		availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"logind has no display inhibitor; the screen saver interface would be needed"
		)
	);
	caps.set(KEEP_AWAKE_SYSTEM, availability::YES);
	caps.set(
		DELAY_SLEEP_HOOK,
		b.sleep_barrier ? availability::YES
			: availability::no(
				availability::Reason.UNSUPPORTED_BACKEND,
				"set Options.sleep_barrier to hold the delay lock"
			)
	);
	caps.set(BLOCK_SHUTDOWN, availability::YES);
	caps.set(SUSPEND, availability::YES);
	caps.set(HIBERNATE, availability::YES);
	caps.set(HYBRID_SLEEP, availability::YES);
	caps.set(POWER_OFF, availability::YES);
	caps.set(REBOOT, availability::YES);
	Availability session = b.has_session ? availability::YES
		: availability::no(availability::Reason.BACKEND_MISSING, "this process is not in a logind session");
	caps.set(LOCK, session);
	caps.set(LOGOUT, session);
	caps.set(IDLE_HINT, availability::YES);
	caps.set(LID_EVENTS, availability::YES);
	caps.set(AC_EVENTS, availability::YES);
}

<* The loop: wait for the bus or a request, then do what is waiting. Runs until the service stops. *>
fn void serve(Logind* b, Host{Command}* host)
{
	Poller poller;
	poller.init(b.allocator, host.wakeup(), 1)!!;
	defer poller.free();
	Command[COMMAND_BATCH] batch;
	while (!host.stopping())
	{
		sync_bus_source(b, &poller);
		// A wait that fails is not retried in a loop: the bus is treated as lost.
		if (catch err = poller.wait(WAIT_INTERVAL))
		{
			if (err != TIMEOUT) b.bus_alive = false;
		}
		pump(b);
		drain(b, host, batch[..]);
		pump(b);
		react(b);
	}
}

// Keep the bus connection registered with the poller exactly while it is alive.
fn void sync_bus_source(Logind* b, Poller* poller)
{
	bool wanted = b.bus_alive;
	if (wanted == b.bus_registered) return;
	if (wanted)
	{
		poller::Source source = { .handle = b.bus.fd()!!, .interest = { .readable = true }, .tag = BUS_TAG };
		poller.add(source)!!;
	}
	else
	{
		poller.remove(BUS_TAG)!!;
	}
	b.bus_registered = wanted;
}

// Read whatever the bus has, dispatching signals to their handlers.
fn void pump(Logind* b)
{
	if (!b.bus_alive) return;
	if (catch err = b.bus.process())
	{
		// process() reports DISCONNECTED or PROTOCOL once the connection is unusable.
		b.bus_alive = false;
	}
}

// Run every queued request, in batches, until the mailbox is empty.
fn void drain(Logind* b, Host{Command}* host, Command[] batch)
{
	while (true)
	{
		usz count = host.mailbox().take_all(batch);
		if (count == 0) return;
		for (usz i = 0; i < count; i++) dispatch(b, &batch[i]);
	}
}

// Publish what the signals and requests changed.
fn void react(Logind* b)
{
	if (!b.bus_alive) return;
	foreach (signal : b.sleep_signals)
	{
		if (signal == PREPARE)
		{
			begin_sleep(b);
		}
		else
		{
			end_sleep(b);
		}
	}
	b.sleep_signals.clear();
	if (b.dirty)
	{
		b.dirty = false;
		refresh(b);
	}
}

// The machine is about to sleep. With a barrier, the delay lock stays until `ack`.
fn void begin_sleep(Logind* b)
{
	uint ticket  = ++b.next_ticket;
	uint barrier = 0;
	if (b.barrier.is_open())
	{
		b.barrier_ticket = ticket;
		barrier = ticket;
	}
	power::publish_event(b.hub, PREPARE_SLEEP, barrier);
}

// The machine woke up: drop any barrier logind already passed, announce it, retake the lock.
fn void end_sleep(Logind* b)
{
	if (b.barrier.is_open())
	{
		// Fd.close releases the descriptor even when close(2) fails; there is nothing to retry.
		if (catch err = b.barrier.close())
		{
		}
	}
	b.barrier_ticket = 0;
	power::publish_event(b.hub, RESUMED, 0);
	if (b.sleep_barrier)
	{
		// A refused retake leaves no barrier, so the next PREPARE_SLEEP carries no ticket
		// and nothing waits for an acknowledgement that cannot come.
		if (catch err = take_barrier(b)) b.note_failure(err);
	}
}

// Hold the delay lock that makes the next sleep wait for `ack`.
fn void? take_barrier(Logind* b)
{
	unix::Fd fd = inhibit_fd(b, "sleep", BARRIER_WHO, BARRIER_WHY, "delay")!;
	b.barrier = fd;
}

// Shut down: fail what is queued, release every lock, close the bus.
fn void shutdown(Logind* b, Host{Command}* host)
{
	Command[COMMAND_BATCH] batch;
	while (true)
	{
		usz count = host.mailbox().take_all(batch[..]);
		if (count == 0) break;
		for (usz i = 0; i < count; i++) power::abort_command(&batch[i], error::DISCONNECTED);
	}
	if (b.barrier.is_open())
	{
		if (catch err = b.barrier.close())
		{
		}
	}
	foreach (&held : b.locks)
	{
		// As for the barrier: the descriptor is released either way.
		if (catch err = held.fd.close())
		{
		}
	}
	b.locks.free();
	b.sleep_signals.free();
	b.bus.free();
}