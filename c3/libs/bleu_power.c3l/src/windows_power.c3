<*
 The Windows mechanism. Battery saver and external power come from
 GetSystemPowerStatus; keep-awake from PowerCreateRequest; suspend, power off and
 lock from SetSuspendState, InitiateSystemShutdownExW and LockWorkStation.
 Everything else is reported unsupported (module `bleu::power`, README "Not
 done"): power profiles, the lid, hibernate, reboot, logout, and the delay
 barrier.

 Compiled for Windows and type-checked; nothing has run on Windows. Sources:
 docs/research/battery_power.md, sections W-B1, W-P2, W-P3, rows V44 to V54.

 Threading: the worker polls GetSystemPowerStatus; a request wakes it at once.
*>
module bleu::power::windows @feat(WIN32);
import std::collections::list, std::collections::maybe, std::time, bleu::availability, bleu::error,
	bleu::observe, bleu::power, bleu::rt::poller, bleu::rt::worker, bleu::service, bleu::win::errors,
	bleu::win::text, bleu::power::windows_api, bleu::power::windows_suspend, bleu::power::windows_shutdown,
	bleu::power::windows_lock, bleu::power::convert;

<* How often the worker reads the power status when nothing else wakes it. *>
const Duration POLL_INTERVAL = (Duration)2_000_000;
const usz COMMAND_BATCH = 16;
<* `SHTDN_REASON_FLAG_PLANNED` with `SHTDN_REASON_MAJOR_OTHER` (0): a planned shutdown with no specific cause. *>
const uint SHUTDOWN_REASON = 0x80000000;
<* `AC_LINE_ONLINE` and `AC_LINE_OFFLINE` (SYSTEM_POWER_STATUS.ACLineStatus); 255 is unknown. *>
const char AC_LINE_OFFLINE = 0;
const char AC_LINE_ONLINE = 1;
const char BATTERY_SAVER_ON = 1;
const char BATTERY_SAVER_OFF = 0;

const Driver DRIVER = {
	.info = { "win32", "GetSystemPowerStatus, PowerCreateRequest, SetSuspendState and friends", 10 },
	.id = WIN32,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

<* A keep-awake request this worker holds. *>
struct Hold
{
	uint id;
	void* request;
	int type;
}

struct Win
{
	Allocator allocator;
	PowerHub* hub;
	Capabilities* capabilities;
	Startup* startup;
	List{Hold} holds;
	uint next_hold;
	Maybe{bool} last_external;
}

fn bool probe(Options* options) => true;

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities, Startup* startup)
{
	Win* win = alloc::new(allocator, Win);
	win.allocator = allocator;
	win.capabilities = capabilities;
	win.startup = startup;
	return win;
}

fn void destroy(Allocator allocator, void* state)
{
	alloc::free(allocator, state);
}

fn void run(void* state, PowerHub* hub, Host{Command}* host)
{
	Win* win = (Win*)state;
	win.hub = hub;
	win.holds.init(win.allocator);
	fill_capabilities(win.capabilities);
	refresh(win);
	win.startup.succeed();
	serve(win, host);
	shutdown(win, host);
}

fn void fill_capabilities(Capabilities* caps)
{
	Availability no_profiles = availability::no(availability::Reason.UNSUPPORTED_BACKEND, "power modes are not read in this version: the overlay scheme calls are unverified");
	caps.set(PROFILE_READ, no_profiles);
	caps.set(PROFILE_SET, no_profiles);
	caps.set(PROFILE_HOLD, availability::no(availability::Reason.UNSUPPORTED_OS, "Windows has no profile holds"));
	caps.set(LOW_POWER_READ, availability::no(availability::Reason.UNSUPPORTED_OS, "Windows has a battery saver, not Low Power Mode"));
	caps.set(BATTERY_SAVER_READ, availability::YES);
	caps.set(KEEP_AWAKE_IDLE, availability::YES);
	caps.set(KEEP_AWAKE_DISPLAY, availability::YES);
	caps.set(KEEP_AWAKE_SYSTEM, availability::YES);
	caps.set(DELAY_SLEEP_HOOK, availability::no(availability::Reason.UNSUPPORTED_BACKEND, "no verified delay lock on Windows in this version"));
	caps.set(BLOCK_SHUTDOWN, availability::no(availability::Reason.UNSUPPORTED_BACKEND, "no verified shutdown block on Windows in this version"));
	caps.set(SUSPEND, availability::YES);
	caps.set(HIBERNATE, availability::no(availability::Reason.UNSUPPORTED_BACKEND, "hibernation state is not probed in this version"));
	caps.set(HYBRID_SLEEP, availability::no(availability::Reason.UNSUPPORTED_OS, "Windows has no hybrid sleep action in this version"));
	caps.set(POWER_OFF, availability::YES);
	caps.set(REBOOT, availability::no(availability::Reason.UNSUPPORTED_BACKEND, "deferred in this version"));
	caps.set(LOCK, availability::YES);
	caps.set(LOGOUT, availability::no(availability::Reason.UNSUPPORTED_BACKEND, "deferred in this version"));
	caps.set(IDLE_HINT, availability::no(availability::Reason.UNSUPPORTED_OS, "Windows has no idle hint"));
	caps.set(LID_EVENTS, availability::no(availability::Reason.UNSUPPORTED_BACKEND, "the lid switch payload is not verified in this version"));
	caps.set(AC_EVENTS, availability::YES);
}

fn void serve(Win* win, Host{Command}* host)
{
	Poller poller;
	poller.init(win.allocator, host.wakeup(), 0)!!;
	defer poller.free();
	Command[COMMAND_BATCH] batch;
	while (!host.stopping())
	{
		// Sleeps until the poll is due or a request wakes the worker; TIMEOUT is the normal tick.
		if (catch err = poller.wait(POLL_INTERVAL)) {}
		drain(win, host, batch[..]);
		refresh(win);
	}
}

fn void drain(Win* win, Host{Command}* host, Command[] batch)
{
	while (true)
	{
		usz count = host.mailbox().take_all(batch);
		if (count == 0) return;
		for (usz i = 0; i < count; i++) dispatch(win, &batch[i]);
	}
}

// Read the power status and publish it. A failed read leaves the fields it feeds unknown.
fn void refresh(Win* win)
{
	SystemPowerStatus status;
	if (catch err = read_status(&status)) return;
	Snapshot{State}* snapshot = win.hub.begin();
	State* state = &snapshot.value;
	if (status.ac_line_status == AC_LINE_ONLINE) state.on_external_power.set(true);
	if (status.ac_line_status == AC_LINE_OFFLINE) state.on_external_power.set(false);
	if (status.system_status_flag == BATTERY_SAVER_ON) state.battery_saver.set(true);
	if (status.system_status_flag == BATTERY_SAVER_OFF) state.battery_saver.set(false);
	Maybe{bool} external = state.on_external_power;
	win.hub.publish_if_changed(snapshot);
	if (external.has_value)
	{
		if (win.last_external.has_value && win.last_external.value != external.value)
		{
			power::publish_event(win.hub, external.value ? EXTERNAL_POWER_CONNECTED : EXTERNAL_POWER_DISCONNECTED, 0);
		}
		win.last_external = external;
	}
}

fn SystemPowerStatus? read_status(SystemPowerStatus* status)
{
	if (getSystemPowerStatus(status) == 0) return errors::raise_last("GetSystemPowerStatus")~;
	return *status;
}

fn void dispatch(Win* win, Command* command)
{
	switch (command.kind)
	{
		case SET_PROFILE: power::abort{Profile}(command.profile_op, error::UNSUPPORTED);
		case HOLD_PROFILE: power::abort{ProfileHold}(command.hold_op, error::UNSUPPORTED);
		case RELEASE_PROFILE: return;
		case ACK_SLEEP: return;
		case INHIBIT: inhibit(win, command);
		case RELEASE_INHIBITOR: release_hold(win, command.number);
		case CAN: power::finish{Availability}(command.can_op, win.capabilities.get(power::action_cap(command.action)));
		case PERFORM: perform(win, command);
	}
}

// The request type for a keep-awake kind; the other kinds are not available here.
fn int? request_type(InhibitKind kind)
{
	switch (kind)
	{
		case KEEP_AWAKE_DISPLAY: return POWER_REQUEST_DISPLAY_REQUIRED;
		case KEEP_AWAKE_IDLE:
		case KEEP_AWAKE_SYSTEM: return POWER_REQUEST_SYSTEM_REQUIRED;
		case SLEEP_DELAY:
		case SHUTDOWN_BLOCK: return error::UNSUPPORTED~;
	}
}

fn void inhibit(Win* win, Command* command)
{
	Inhibitor? inhibitor = take_request(win, command);
	if (catch err = inhibitor)
	{
		power::abort{Inhibitor}(command.inhibit_op, err);
	}
	else
	{
		power::finish{Inhibitor}(command.inhibit_op, inhibitor);
	}
}

// PowerCreateRequest with the reason, then PowerSetRequest for the kind. The reason is only needed during the call.
fn Inhibitor? take_request(Win* win, Command* command)
{
	int type = request_type(command.inhibit)!;
	@pool()
	{
		WideZ reason = text::to_wide(tmem, command.why)!;
		ReasonContext context = { .version = POWER_REQUEST_CONTEXT_VERSION, .flags = POWER_REQUEST_CONTEXT_SIMPLE_STRING, .simple_reason = reason.as_wstring() };
		void* request = powerCreateRequest(&context);
		if ((usz)request == INVALID_HANDLE) return errors::raise_last("PowerCreateRequest")~;
		if (powerSetRequest(request, type) == 0)
		{
			fault failure = errors::raise_last("PowerSetRequest");
			closeHandle(request);
			return failure~;
		}
		uint id = ++win.next_hold;
		win.holds.push({ .id = id, .request = request, .type = type });
		return { .id = id, .owner = command.owner };
	};
}

// Clear the request and close its handle. Failures leave nothing to retry: the request dies with the handle.
fn void release_hold(Win* win, uint id)
{
	foreach (i, &hold : win.holds)
	{
		if (hold.id != id) continue;
		powerClearRequest(hold.request, hold.type);
		closeHandle(hold.request);
		win.holds.remove_at(i);
		return;
	}
}

// The three actions this mechanism performs. Each reports the Win32 failure as a fault.
fn void perform(Win* win, Command* command)
{
	switch (command.action)
	{
		case SUSPEND:
			if (setSuspendState(0, 0, 0) == 0)
			{
				power::abort{Action}(command.action_op, errors::raise_last("SetSuspendState"));
			}
			else
			{
				power::finish{Action}(command.action_op, SUSPEND);
			}
		case POWER_OFF:
			if (initiateSystemShutdownExW(null, null, 0, 0, 0, SHUTDOWN_REASON) == 0)
			{
				power::abort{Action}(command.action_op, errors::raise_last("InitiateSystemShutdownExW"));
			}
			else
			{
				power::finish{Action}(command.action_op, POWER_OFF);
			}
		case LOCK:
			if (lockWorkStation() == 0)
			{
				power::abort{Action}(command.action_op, errors::raise_last("LockWorkStation"));
			}
			else
			{
				power::finish{Action}(command.action_op, LOCK);
			}
		case HIBERNATE:
		case HYBRID_SLEEP:
		case REBOOT:
		case LOGOUT: power::abort{Action}(command.action_op, error::UNSUPPORTED);
	}
}

fn void shutdown(Win* win, Host{Command}* host)
{
	Command[COMMAND_BATCH] batch;
	while (true)
	{
		usz count = host.mailbox().take_all(batch[..]);
		if (count == 0) break;
		for (usz i = 0; i < count; i++) power::abort_command(&batch[i], error::DISCONNECTED);
	}
	foreach (&hold : win.holds)
	{
		powerClearRequest(hold.request, hold.type);
		closeHandle(hold.request);
	}
	win.holds.free();
}
