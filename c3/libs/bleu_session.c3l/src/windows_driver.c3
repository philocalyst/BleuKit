<*
 The Windows mechanism: a hidden window on the worker thread receives the session lock and
 unlock messages (WTSRegisterSessionNotification) and the power broadcasts (sleep and wake).
 The worker pumps that window's queue at every tick. The lock state is also read on every tick,
 so a missed message delays an event by one tick but never leaves the state wrong.

 Idle time is `GetLastInputInfo`, read on every tick and compared with each threshold.
 A lock request is `LockWorkStation`. Only public Win32 APIs are used.
*>
module bleu::session::windows @feat(WIN32);
import std::collections::maybe, std::time, bleu::availability, bleu::error, bleu::rt::poller, bleu::rt::worker, bleu::session, bleu::session::windows_native, bleu::win::message_loop;

// Commands taken per batch.
const usz COMMAND_BATCH = 8;

const Driver DRIVER = {
	.info = { "win32", "WTS session notifications, GetLastInputInfo and power broadcasts", 10 },
	.id = WIN32,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

struct Windows
{
	Duration idle_poll;
	Polled polled;
	bool has_session;
	uint session_id;
}

<* Every Windows system has a desktop session to read. *>
fn bool probe(Options* options) => true;

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	capabilities.set(
		Cap.LOCK,
		availability::no(
			availability::Reason.DEGRADED,
			"LockWorkStation starts the lock; the request completes before the screen is locked"
		)
	);
	capabilities.set(
		Cap.UNLOCK,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "Windows has no API that unlocks the workstation")
	);
	capabilities.set(
		Cap.LOCK_SESSION,
		availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"Only the workstation this process runs in can be locked"
		)
	);
	capabilities.set(
		Cap.TERMINATE_SESSION,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "Not offered in this version")
	);
	capabilities.set(
		Cap.IDLE_WATCH,
		availability::no(
			availability::Reason.DEGRADED,
			"Input on this session's desktop, polled every idle_poll: an edge can come up to one poll late"
		)
	);
	capabilities.set(
		Cap.IDLE_HINT,
		availability::no(availability::Reason.UNSUPPORTED_OS, "logind's IdleHint does not exist on Windows")
	);
	capabilities.set(
		Cap.SESSION_LIST,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "Not read in this version")
	);
	Windows* win = alloc::new(allocator, Windows);
	win.idle_poll = options.idle_poll;
	win.polled.init(allocator, options.idle_thresholds);
	if (try id = windows_native::current_session_id())
	{
		win.session_id = id;
		win.has_session = true;
	}
	return win;
}

fn void destroy(Allocator allocator, void* state)
{
	Windows* win = (Windows*)state;
	win.polled.free();
	alloc::free(allocator, win);
}

<* A session lock, unlock, or power broadcast from the message window, recorded for the next settle. *>
fn void on_message(void* context, message_loop::Event* event) @local
{
	Windows* win = (Windows*)context;
	if (event.kind == message_loop::EventKind.SESSION_CHANGE)
	{
		if (event.code == windows_native::WTS_SESSION_LOCK)
		{
			win.polled.record(session::EventKind.LOCKED);
		}
		else if (event.code == windows_native::WTS_SESSION_UNLOCK)
		{
			win.polled.record(session::EventKind.UNLOCKED);
		}
	}
	else if (event.kind == message_loop::EventKind.POWER_STATE)
	{
		if (event.code == message_loop::PBT_APMSUSPEND)
		{
			win.polled.record(session::EventKind.WILL_SLEEP);
		}
		else if (event.code == message_loop::PBT_APMRESUMESUSPEND || event.code == message_loop::PBT_APMRESUMEAUTOMATIC)
		{
			// Windows reports a resume twice in some cases; `record` ignores the second.
			win.polled.record(session::EventKind.DID_WAKE);
		}
	}
}

<*
 Read the lock state and the idle time, publish, and announce. Called at every tick and after
 every command. A read that fails this tick leaves the last known value standing.
*>
fn void settle_now(Windows* win, SessionHub* hub)
{
	if (try locked = windows_native::is_session_locked())
	{
		win.polled.record(locked ? session::EventKind.LOCKED : session::EventKind.UNLOCKED);
	}
	if (try idle = windows_native::idle_milliseconds())
	{
		win.polled.observe_idle((Duration)(idle * 1000));
	}
	@pool()
	{
		String id = win.has_session ? string::tformat("%d", win.session_id) : "";
		win.polled.settle(hub, id);
	};
}

<* The worker: a window for the session messages, then the loop of poll ticks, messages and commands. *>
fn void run(void* state, SessionHub* hub, Host{Command}* host)
{
	Windows* win = (Windows*)state;
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 0, true)) return;
	defer poller.free();
	message_loop::Loop* loop = null;
	if (try opened = message_loop::open(mem, &on_message, win))
	{
		loop = opened;
		// Without the notification the lock state is still read on every tick.
		if (catch err = windows_native::register_session(loop.window))
		{
			// Lock events then come from the tick, one interval late.
		}
	}
	settle_now(win, hub);
	Command[COMMAND_BATCH] commands;
	while (!host.stopping())
	{
		// Sleeps until the poll interval passes, a window message arrives, or a command is queued.
		if (catch poller.wait(win.idle_poll))
		{
			// TIMEOUT is the normal tick.
		}
		message_loop::dispatch_pending();
		usz count = host.mailbox().take_all(commands[..]);
		for (usz i = 0; i < count; i++) execute(win, &commands[i]);
		settle_now(win, hub);
	}
	if (loop != null)
	{
		// Best effort: the window is destroyed with the loop, which ends the session messages either way.
		if (catch err = windows_native::unregister_session(loop.window))
		{
		}
		loop.close();
	}
}

<* Carry out a command: a request completes its operation; a watch command changes the thresholds. *>
fn void execute(Windows* win, Command* command)
{
	if (command.kind != CommandKind.REQUEST)
	{
		win.polled.apply_command(command);
		return;
	}
	SessionOperation* operation = command.operation;
	if (catch err = perform(command.request))
	{
		operation.fail(err);
	}
	else
	{
		operation.succeed(command.request);
	}
	operation.release();
}

<* The request on this platform. Only LOCK exists here. *>
fn void? perform(Request request)
{
	if (request != Request.LOCK)
	{
		return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "this request is not available on Windows")~;
	}
	windows_native::lock_work_station()!;
}