<*
 The macOS mechanism. External power comes from IOPowerSources, keep-awake from
 IOPMAssertion, sleep and wake from IORegisterForSystemPower, and Low Power
 Mode from NSProcessInfo. The v1 cut is in the README: sleep, shutdown,
 restart, lock, logout and the sleep barrier are reported unsupported.

 Everything here is compiled for macOS and type-checked; nothing has run on a
 Mac. Sources: the binding decisions and their citations are in
 docs/research/battery_power.md (sections M-P1 to M-P3, rows V24 to V36).

 Threading: this worker owns the run loop. Power notifications are delivered by
 the run loop inside `CFRunLoopRunInMode`, so their handlers only record what
 happened; the loop publishes after the run returns.
*>
module bleu::power::macos @feat(DARWIN);
import std::collections::list, std::collections::maybe, std::os::darwin::objc, bleu::availability, bleu::cf,
	bleu::error, bleu::iokit, bleu::iokit::power, bleu::mach, bleu::objc, bleu::observe, bleu::power, bleu::service,
	bleu::rt::worker;

extern fn void* cf_run_loop_get_current() @cname("CFRunLoopGetCurrent");
extern fn int cf_run_loop_run_in_mode(void* mode, double seconds, bool return_after_source) @cname("CFRunLoopRunInMode");
extern fn int pm_create_assertion(CFTypeRef type, uint level, CFTypeRef name, uint* id) @cname("IOPMAssertionCreateWithName");
extern fn int pm_release_assertion(uint id) @cname("IOPMAssertionRelease");

<* How long one run of the loop may wait for notifications before the requests are looked at. *>
const double POLL_SECONDS = 0.25;
<* Loop passes between state reads: about two seconds, which is what Low Power Mode needs. *>
const int REFRESH_TICKS = 8;
const usz COMMAND_BATCH = 16;
<* `kIOPMAssertionLevelOn` (IOPMLib.h): the assertion is in force. *>
const uint ASSERTION_LEVEL_ON = 255;

<* IOPMAssertion types (IOPMLib.h, and the strings used by keepawake; see V32). *>
const String ASSERTION_IDLE = "PreventUserIdleSystemSleep";
const String ASSERTION_DISPLAY = "PreventUserIdleDisplaySleep";
const String ASSERTION_SYSTEM = "PreventSystemSleep";

const Driver DRIVER = {
	.info = { "macos", "IOPowerSources, IOPMAssertion, IORegisterForSystemPower and NSProcessInfo", 10 },
	.id = MACOS,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

<* An IOPMAssertion this worker holds, released by `Inhibitor.release`. *>
struct Hold
{
	uint id;
	uint assertion;
}

struct Mac
{
	Allocator allocator;
	PowerHub* hub;
	Capabilities* capabilities;
	Startup* startup;
	SystemPower* system;
	cf::Ref source;
	bool dirty;
	uint next_hold;
	List{Hold} holds;
	List{PowerEvent} sleep_events;
	Maybe{bool} last_external;
}

fn bool probe(Options* options) => true;

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities, Startup* startup)
{
	Mac* mac = alloc::new(allocator, Mac);
	mac.allocator = allocator;
	mac.capabilities = capabilities;
	mac.startup = startup;
	return mac;
}

fn void destroy(Allocator allocator, void* state)
{
	alloc::free(allocator, state);
}

fn void run(void* state, PowerHub* hub, Host{Command}* host)
{
	Mac* mac = (Mac*)state;
	mac.hub = hub;
	mac.holds.init(mac.allocator);
	mac.sleep_events.init(mac.allocator);
	if (catch err = start(mac))
	{
		mac.startup.fail(err);
	}
	else
	{
		mac.startup.succeed();
		serve(mac, host);
	}
	shutdown(mac, host);
}

fn void fill_capabilities(Capabilities* caps)
{
	Availability no_profiles = availability::no(availability::Reason.UNSUPPORTED_OS, "macOS has no power profiles; Low Power Mode is read-only");
	caps.set(PROFILE_READ, no_profiles);
	caps.set(PROFILE_SET, no_profiles);
	caps.set(PROFILE_HOLD, no_profiles);
	caps.set(LOW_POWER_READ, availability::YES);
	caps.set(BATTERY_SAVER_READ, availability::no(availability::Reason.UNSUPPORTED_OS, "macOS reports Low Power Mode, not a battery saver flag"));
	caps.set(KEEP_AWAKE_IDLE, availability::YES);
	caps.set(KEEP_AWAKE_DISPLAY, availability::YES);
	caps.set(KEEP_AWAKE_SYSTEM, availability::YES);
	caps.set(DELAY_SLEEP_HOOK, availability::no(availability::Reason.UNSUPPORTED_BACKEND, "bleu::iokit::power acknowledges the sleep at once; a barrier needs a deferred acknowledgement there"));
	caps.set(BLOCK_SHUTDOWN, availability::no(availability::Reason.UNSUPPORTED_BACKEND, "no verified route in this version"));
	Availability deferred = availability::no(availability::Reason.UNSUPPORTED_BACKEND, "deferred in this version: no route verified on hardware");
	caps.set(SUSPEND, deferred);
	caps.set(HIBERNATE, deferred);
	caps.set(HYBRID_SLEEP, deferred);
	caps.set(POWER_OFF, deferred);
	caps.set(REBOOT, deferred);
	caps.set(LOCK, deferred);
	caps.set(LOGOUT, deferred);
	caps.set(IDLE_HINT, availability::no(availability::Reason.UNSUPPORTED_OS, "macOS has no idle hint"));
	caps.set(LID_EVENTS, availability::no(availability::Reason.UNSUPPORTED_BACKEND, "the clamshell state is not read in this version"));
	caps.set(AC_EVENTS, availability::YES);
}

fn void? start(Mac* mac)
{
	fill_capabilities(mac.capabilities);
	void* loop = cf_run_loop_get_current();
	mac.system = iokit::power::register_system_power(&on_power_event, mac)!;
	iokit::power::attach_source(loop, mac.system.port.source());
	mac.source = iokit::power::power_source_change_source(&on_power_source_change, mac)!;
	iokit::power::attach_source(loop, mac.source.ptr);
	refresh(mac);
}

// Sleep and wake, recorded for the loop to publish.
fn void on_power_event(void* context, PowerEvent event)
{
	Mac* mac = (Mac*)context;
	mac.sleep_events.push(event);
}

// The power sources changed (plugged in or out, or the battery moved): re-read them.
fn void on_power_source_change(void* context)
{
	Mac* mac = (Mac*)context;
	mac.dirty = true;
}

fn void serve(Mac* mac, Host{Command}* host)
{
	Command[COMMAND_BATCH] batch;
	int ticks = 0;
	while (!host.stopping())
	{
		// Notifications are delivered inside this call; the requests follow.
		cf_run_loop_run_in_mode(iokit::power::KCF_RUNLOOP_DEFAULT_MODE, POLL_SECONDS, false);
		deliver_sleep(mac);
		drain(mac, host, batch[..]);
		ticks++;
		if (mac.dirty || ticks >= REFRESH_TICKS)
		{
			mac.dirty = false;
			ticks = 0;
			refresh(mac);
		}
	}
}

// Sleep and wake are events, not barriers: the sleep is acknowledged by bleu::iokit::power.
fn void deliver_sleep(Mac* mac)
{
	foreach (event : mac.sleep_events)
	{
		switch (event)
		{
			case PowerEvent.WILL_SLEEP: power::publish_event(mac.hub, PREPARE_SLEEP, 0);
			case PowerEvent.HAS_POWERED_ON: power::publish_event(mac.hub, RESUMED, 0);
			case PowerEvent.CAN_SLEEP:
			case PowerEvent.WILL_NOT_SLEEP:
			case PowerEvent.WILL_POWER_ON:
			case PowerEvent.WILL_POWER_OFF:
			case PowerEvent.WILL_RESTART:
			case PowerEvent.OTHER: return;
		}
	}
	mac.sleep_events.clear();
}

fn void drain(Mac* mac, Host{Command}* host, Command[] batch)
{
	while (true)
	{
		usz count = host.mailbox().take_all(batch);
		if (count == 0) return;
		for (usz i = 0; i < count; i++) dispatch(mac, &batch[i]);
	}
}

// Read the state and publish it. A failed read leaves its field unknown.
fn void refresh(Mac* mac)
{
	Snapshot{State}* snapshot = mac.hub.begin();
	State* state = &snapshot.value;
	external_power(state);
	state.low_power_mode.set(low_power_mode());
	Maybe{bool} external = state.on_external_power;
	mac.hub.publish_if_changed(snapshot);
	if (external.has_value)
	{
		if (mac.last_external.has_value && mac.last_external.value != external.value)
		{
			power::publish_event(mac.hub, external.value ? EXTERNAL_POWER_CONNECTED : EXTERNAL_POWER_DISCONNECTED, 0);
		}
		mac.last_external = external;
	}
}

// On external power when any source reports AC. A machine with no power source has no answer.
fn void external_power(State* state)
{
	@pool()
	{
		if (try sources = iokit::power::read_power_sources(tmem))
		{
			if (sources.len == 0) return;
			bool on_ac = false;
			foreach (&entry : sources)
			{
				if (entry.state == PowerSourceState.AC) on_ac = true;
			}
			state.on_external_power.set(on_ac);
		}
	};
}

// NSProcessInfo.lowPowerModeEnabled, read on the worker.
fn bool low_power_mode()
{
	bool enabled = false;
	objc::@autorelease_pool()
	{
		ObjId info = objc::class_named("NSProcessInfo").send(ObjId, "processInfo");
		objc::Obj process = objc::borrow(info);
		defer process.close();
		enabled = process.send_bool("isLowPowerModeEnabled");
	};
	return enabled;
}

fn void dispatch(Mac* mac, Command* command)
{
	switch (command.kind)
	{
		// The public API refuses these before queuing them, so the worker has nothing to add.
		case SET_PROFILE: power::abort{Profile}(command.profile_op, error::UNSUPPORTED);
		case HOLD_PROFILE: power::abort{ProfileHold}(command.hold_op, error::UNSUPPORTED);
		case PERFORM: power::abort{Action}(command.action_op, error::UNSUPPORTED);
		case RELEASE_PROFILE: return;
		case ACK_SLEEP: return;
		case INHIBIT: inhibit(mac, command);
		case RELEASE_INHIBITOR: release_hold(mac, command.number);
		case CAN: power::finish{Availability}(command.can_op, mac.capabilities.get(power::action_cap(command.action)));
	}
}

// The IOPMAssertion type for a keep-awake kind; the other kinds are not sleep assertions.
fn String? assertion_type(InhibitKind kind)
{
	switch (kind)
	{
		case KEEP_AWAKE_IDLE: return ASSERTION_IDLE;
		case KEEP_AWAKE_DISPLAY: return ASSERTION_DISPLAY;
		case KEEP_AWAKE_SYSTEM: return ASSERTION_SYSTEM;
		case SLEEP_DELAY:
		case SHUTDOWN_BLOCK: return error::UNSUPPORTED~;
	}
}

fn void inhibit(Mac* mac, Command* command)
{
	String type = assertion_type(command.inhibit) ?? "";
	if (type.len == 0)
	{
		power::abort{Inhibitor}(command.inhibit_op, error::UNSUPPORTED);
		return;
	}
	Inhibitor? inhibitor = take_assertion(mac, type, command);
	if (catch err = inhibitor)
	{
		power::abort{Inhibitor}(command.inhibit_op, err);
	}
	else
	{
		power::finish{Inhibitor}(command.inhibit_op, inhibitor);
	}
}

// Create the assertion; `why` is its name, which `pmset -g assertions` shows.
fn Inhibitor? take_assertion(Mac* mac, String type, Command* command)
{
	cf::Ref type_ref = cf::from_string(type);
	defer type_ref.close();
	cf::Ref name_ref = cf::from_string(command.why);
	defer name_ref.close();
	uint assertion = 0;
	int result = pm_create_assertion(type_ref.ptr, ASSERTION_LEVEL_ON, name_ref.ptr, &assertion);
	if (result != 0) return mach::raise_code(result, "IOPMAssertionCreateWithName")~;
	uint id = ++mac.next_hold;
	mac.holds.push({ .id = id, .assertion = assertion });
	return { .id = id, .owner = command.owner };
}

// Release the assertion with `id`. IOPMAssertionRelease is idempotent for the caller here: an id is removed once.
fn void release_hold(Mac* mac, uint id)
{
	foreach (i, &hold : mac.holds)
	{
		if (hold.id != id) continue;
		// A failed release is not retried: the kernel drops the assertion when the process ends.
		(void)pm_release_assertion(hold.assertion);
		mac.holds.remove_at(i);
		return;
	}
}

fn void shutdown(Mac* mac, Host{Command}* host)
{
	Command[COMMAND_BATCH] batch;
	while (true)
	{
		usz count = host.mailbox().take_all(batch[..]);
		if (count == 0) break;
		for (usz i = 0; i < count; i++) power::abort_command(&batch[i], error::DISCONNECTED);
	}
	foreach (&hold : mac.holds)
	{
		(void)pm_release_assertion(hold.assertion);
	}
	mac.holds.free();
	mac.sleep_events.free();
	if (mac.system != null) mac.system.close();
	mac.source.close();
}
