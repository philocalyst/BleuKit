<*
 The macOS mechanism: the window server's session dictionary (lock state), HID idle time from
 CoreGraphics (polled), and the system power notifications of IOKit (sleep and wake).

 The worker runs a CFRunLoop: the power notifications are delivered on it, and the loop wakes
 every `Options.idle_poll` to read the lock state and the idle time. Commands are taken at the
 same ticks, so a request waits at most one poll interval to start.

 Public API only, except the lock request, which is behind `Options.allow_private` (see
 `macos_lock_private.c3`). Sleep and wake use the IOKit power notifications that `bleu_objc`
 wraps, not NSWorkspace: NSWorkspace posts on the main thread, and this worker runs no main run
 loop. Sources and open items: docs/research/session_windows_input.md, section 2 "macOS".
*>
module bleu::session::macos @feat(DARWIN);
import std::collections::maybe, std::time, bleu::availability, bleu::error, bleu::iokit::power, bleu::session, bleu::session::macos_lock, bleu::session::macos_native, bleu::rt::worker;

extern fn void* cf_run_loop_get_current() @cname("CFRunLoopGetCurrent");
extern fn int cf_run_loop_run_in_mode(void* mode, double seconds, bool return_after_source) @cname("CFRunLoopRunInMode");

<* Commands taken per batch. *>
const usz COMMAND_BATCH = 8;

const Driver DRIVER = {
	.info = { "macos", "Window server session, HID idle time and IOKit power notifications", 10 },
	.id = MACOS,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

struct Macos
{
	Allocator allocator;
	Duration idle_poll;
	Polled polled;
	bool has_lock;
	LockScreen lock;
	power::SystemPower* system; // registered on the worker's run loop; null when IOKit refused it
}

<* Every macOS has a window server session to read. *>
fn bool probe(Options* options) => true;

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	capabilities.set(
		Cap.LOCK_STATE,
		availability::no(
			availability::Reason.DEGRADED,
			"Polled every idle_poll; the CGSSessionScreenIsLocked key is unverified on hardware"
		)
	);
	capabilities.set(
		Cap.IDLE_WATCH,
		availability::no(availability::Reason.DEGRADED, "Polled every idle_poll, so an edge can come up to one poll late")
	);
	capabilities.set(
		Cap.IDLE_HINT,
		availability::no(availability::Reason.UNSUPPORTED_OS, "logind's IdleHint does not exist on macOS")
	);
	capabilities.set(
		Cap.UNLOCK,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "No public API unlocks the screen: the lock screen authenticates")
	);
	capabilities.set(
		Cap.LOCK_SESSION,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "macOS locks only the session this process runs in")
	);
	capabilities.set(
		Cap.TERMINATE_SESSION,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "No public API ends a user session")
	);
	capabilities.set(
		Cap.SESSION_LIST,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "Not read in this version")
	);
	if (!options.allow_private)
	{
		capabilities.set(
			Cap.LOCK,
			availability::no(
				availability::Reason.UNSUPPORTED_BACKEND,
				"The public API has no lock request; set Options.allow_private to use SACLockScreenImmediate"
			)
		);
	}
	Macos* mac = alloc::new(allocator, Macos);
	mac.allocator = allocator;
	mac.idle_poll = options.idle_poll;
	mac.polled.init(allocator, options.idle_thresholds);
	if (options.allow_private)
	{
		if (catch err = macos_lock::open_lock_screen(&mac.lock))
		{
			capabilities.set(
				Cap.LOCK,
				availability::no(availability::Reason.UNSUPPORTED_BACKEND, "login.framework does not export SACLockScreenImmediate")
			);
		}
		else
		{
			mac.has_lock = true;
			capabilities.set(
				Cap.LOCK,
				availability::no(availability::Reason.DEGRADED, "Private API SACLockScreenImmediate: not verified on hardware")
			);
		}
	}
	// IOKit refuses a registration it cannot make. Register once here and close at once, so that
	// SLEEP_EVENTS is not claimed for a notification that cannot be had.
	power::SystemPower*? check = power::register_system_power(&ignore_power_event, mac);
	if (catch err = check)
	{
		capabilities.set(
			Cap.SLEEP_EVENTS,
			availability::no(availability::Reason.UNSUPPORTED_BACKEND, "IOKit refused the system power registration")
		);
	}
	else
	{
		check.close();
	}
	return mac;
}

fn void destroy(Allocator allocator, void* state)
{
	Macos* mac = (Macos*)state;
	mac.polled.free();
	alloc::free(allocator, mac);
}

// The registration made in `create` is only a check; its handler is never called.
fn void ignore_power_event(void* context, power::PowerEvent event) @local
{
}

<* A sleep or wake from IOKit, recorded for the next settle on the worker. *>
fn void on_power_event(void* context, power::PowerEvent event) @local
{
	Macos* mac = (Macos*)context;
	if (event == power::PowerEvent.WILL_SLEEP)
	{
		mac.polled.record(EventKind.WILL_SLEEP);
	}
	else if (event == power::PowerEvent.HAS_POWERED_ON)
	{
		mac.polled.record(EventKind.DID_WAKE);
	}
}

<*
 Read the lock state and the idle time, publish, and announce. Called from the worker's loop
 at every tick and after every command.
*>
fn void settle_now(Macos* mac, SessionHub* hub)
{
	// A read that fails this tick leaves the last known lock state standing.
	Maybe{bool} locked = macos_native::screen_locked();
	if (locked.has_value) mac.polled.record(locked.value ? EventKind.LOCKED : EventKind.UNLOCKED);
	mac.polled.observe_idle(session::duration_of_seconds(macos_native::hid_idle_seconds()));
	mac.polled.settle(hub, "");
}

<* The worker: sleep and wake arrive on the run loop; commands and the poll tick are taken between runs. *>
fn void run(void* state, SessionHub* hub, Host{Command}* host)
{
	Macos* mac = (Macos*)state;
	void* loop = cf_run_loop_get_current();
	if (try system = power::register_system_power(&on_power_event, mac))
	{
		mac.system = system;
		power::attach_source(loop, system.port.source());
	}
	settle_now(mac, hub);
	Command[COMMAND_BATCH] commands;
	while (!host.stopping())
	{
		// Runs the loop until the poll interval passes or a notification is delivered.
		cf_run_loop_run_in_mode(power::KCF_RUNLOOP_DEFAULT_MODE, session::seconds_of(mac.idle_poll), false);
		usz count = host.mailbox().take_all(commands[..]);
		for (usz i = 0; i < count; i++) execute(mac, &commands[i]);
		settle_now(mac, hub);
	}
	if (mac.system != null) mac.system.close();
}

<* Carry out a command: a request completes its operation; a watch command changes the thresholds. *>
fn void execute(Macos* mac, Command* command)
{
	if (command.kind != CommandKind.REQUEST)
	{
		mac.polled.apply_command(command);
		return;
	}
	SessionOperation* operation = command.operation;
	if (catch err = perform(mac, command.request))
	{
		operation.fail(err);
	}
	else
	{
		operation.succeed(command.request);
	}
	operation.release();
}

<* The request on this platform. Only LOCK exists here, and only with the private gate open. *>
fn void? perform(Macos* mac, Request request)
{
	if (request != Request.LOCK || !mac.has_lock)
	{
		return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "this request is not available on macOS")~;
	}
	mac.lock.api.lock_screen_immediate();
}
