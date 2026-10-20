// Live test of bleu::power's Linux mechanism against a private system bus, a
// mock logind and power-profiles-daemon (mock_daemons.py), and the control
// object that the mock exposes for the test to drive and inspect it.
// Run by ../run.sh, which sets DBUS_SYSTEM_BUS_ADDRESS and passes the profile
// daemon mode: modern, legacy or none. Each check prints PASS or FAIL; the exit
// status is the number of failures.
module bleu::power::integration_test;
import std::io, std::io::path, std::os::env, std::thread, std::time, bleu::error, bleu::availability, bleu::observe, bleu::operation, bleu::stream, bleu::power, bleu::dbus::connection, bleu::dbus::message, bleu::dbus::proxy, bleu::rt::fs;

<* Failed checks so far. *>
int failures = 0;

fn void check(bool ok, String what)
{
	if (ok)
	{
		io::printfn("PASS %s", what);
		return;
	}
	failures++;
	io::printfn("FAIL %s", what);
}

<* Pause between polls of the service and the mock. *>
fn void pause() => thread::sleep(time::ms(20));

<* Call a method of the mock's control object that takes one boolean. *>
fn void control_bool(Connection* bus, Proxy* control, String member, bool value)
{
	Message* call = control.new_call(mem, member)!!;
	defer call.release();
	call.body_writer("b")!!.append_bool(value)!!;
	Message* reply = bus.call(call)!!;
	reply.release();
}

<*
 Whether the text the mock's `member` returns contains `needle`. The mock's JSON is only ever searched, never parsed.
*>
fn bool control_has(Connection* bus, Proxy* control, String member, String needle)
{
	Message* call = control.new_call(mem, member)!!;
	defer call.release();
	Message* reply = bus.call(call)!!;
	defer reply.release();
	String text = reply.reader()!!.read_string()!!;
	return text.contains(needle);
}

<* Poll the mock until `needle` appears in `member`'s text, or about two seconds pass. *>
fn bool control_eventually(Connection* bus, Proxy* control, String member, String needle)
{
	for (int i = 0; i < 100; i++)
	{
		if (control_has(bus, control, member, needle)) return true;
		pause();
	}
	return false;
}

<* The state's active profile, or Profile.UNKNOWN. *>
fn Profile active_profile(Power* svc)
{
	if (try snapshot = svc.latest())
	{
		defer snapshot.release();
		if (snapshot.value.active_profile.has_value) return snapshot.value.active_profile.value;
	}
	return Profile.UNKNOWN;
}

<* Poll the service until the active profile is `wanted`. *>
fn bool profile_eventually(Power* svc, Profile wanted)
{
	for (int i = 0; i < 100; i++)
	{
		if (active_profile(svc) == wanted) return true;
		pause();
	}
	return false;
}

<*
 Whether the next event within two seconds has kind `wanted`. Its ticket is
 written to `ticket` when given.
*>
fn bool got(Reader{Event}* reader, EventKind wanted, uint* ticket)
{
	if (try packet = reader.next(time::ms(2000)))
	{
		defer packet.release();
		if (ticket != null) *ticket = packet.value.ticket;
		return packet.value.kind == wanted;
	}
	return false;
}

fn int main(String[] args)
{
	String mode = args.len > 1 ? args[1] : "modern";
	// Never run against a real system bus: the checks call Suspend, Lock and friends on the bus they reach.
	// run.sh points DBUS_SYSTEM_BUS_ADDRESS at a private socket named bus-socket.
	if (try address = env::tget_var("DBUS_SYSTEM_BUS_ADDRESS"))
	{
		if (!address.contains("bus-socket"))
		{
			io::printfn("refusing: DBUS_SYSTEM_BUS_ADDRESS does not name the private bus socket");
			return 2;
		}
	}
	else
	{
		io::printfn("refusing: DBUS_SYSTEM_BUS_ADDRESS is not set");
		return 2;
	}
	if (mode == "bounce")
	{
		run_bounce_checks();
		io::printfn("%d check(s) failed", failures);
		return failures;
	}
	Connection bus;
	bus.init(mem);
	defer bus.free();
	bus.open_system()!!;
	Proxy control = proxy::for_object(&bus, "org.freedesktop.login1", "/org/bleu/Control", "org.bleu.Mock.Control")!!;

	io::printfn("mode %s", mode);
	Power*? opened = power::open(mem, { .backend = power::Backend.LOGIND });
	if (catch err = opened)
	{
		io::printfn("open failed: %s: %s", err, error::last().message());
		check(false, "open the logind mechanism");
	}
	else
	{
		Power* svc = opened;
		defer svc.close();
		run_linux_checks(svc, &bus, &control, mode);
	}
	if (mode == "modern" || mode == "legacy")
	{
		run_barrier_checks(&bus, &control);
	}
	run_failure_checks();
	run_after_close_checks(mode);
	io::printfn("%d check(s) failed", failures);
	return failures;
}

fn void run_linux_checks(Power* svc, Connection* bus, Proxy* control, String mode)
{
	check(svc.backend_name() == "logind", "backend is logind");
	check(svc.capability(Cap.LOCK).ok(), "lock is available in the session");
	check(svc.capability(Cap.KEEP_AWAKE_DISPLAY)
		.reason == availability::Reason.UNSUPPORTED_BACKEND, "display inhibitor is unsupported");
	check(svc.capability(Cap.DELAY_SLEEP_HOOK)
		.reason == availability::Reason.UNSUPPORTED_BACKEND, "delay barrier is off without the option");
	bool holds = svc.capability(Cap.PROFILE_HOLD).ok();
	check(holds == (mode == "modern"), "holds are offered only by the modern interface");

	if (try snapshot = svc.latest())
	{
		defer snapshot.release();
		State state = snapshot.value;
		if (mode == "none")
		{
			check(!state.active_profile.has_value, "no active profile without a daemon");
		}
		else
		{
			check(
				state.active_profile.has_value && state.active_profile.value == Profile.BALANCED,
				"active profile is balanced"
			);
		}
		check(
			state.profiles.len == (mode == "none" ? 0 : 3),
			"profile list has three profiles when a daemon is present"
		);
		check(state.lid_closed.has_value && !state.lid_closed.value, "lid reads open");
		check(state.on_external_power.has_value && state.on_external_power.value, "external power reads connected");
		check(state.degraded == Degraded.NONE, "profile is not degraded");
	}
	else
	{
		check(false, "the first state is published before open returns");
	}

	if (mode == "none")
	{
		check(svc.capability(Cap.PROFILE_SET)
			.reason == availability::Reason.BACKEND_MISSING, "profiles are missing without the daemon");
		if (catch err = svc.set_profile(Profile.POWER_SAVER))
		{
			check(err == error::UNAVAILABLE, "set_profile fails without the daemon");
		}
		else
		{
			check(false, "set_profile fails without the daemon");
		}
		return;
	}

	if (try op = svc.set_profile(Profile.POWER_SAVER))
	{
		defer op.release();
		check((op.wait() ?? Profile.UNKNOWN) == Profile.POWER_SAVER, "set_profile reports the profile written");
	}
	else
	{
		check(false, "set_profile is accepted");
	}
	check(profile_eventually(svc, Profile.POWER_SAVER), "the state shows the new profile");
	check(control_has(bus, control, "Calls", "SetActiveProfile(power-saver)"), "the daemon received ActiveProfile");

	if (catch err = svc.hold_profile(Profile.BALANCED, "not holdable"))
	{
		check(err == error::INVALID_ARGUMENT, "only power-saver and performance can be held");
	}
	else
	{
		check(false, "only power-saver and performance can be held");
	}
	if (holds)
	{
		if (try op = svc.hold_profile(Profile.PERFORMANCE, "test hold"))
		{
			defer op.release();
			if (try hold = op.wait())
			{
				check(
					control_eventually(bus, control, "Calls", "HoldProfile(performance,test hold,org.bleu.power)"),
					"HoldProfile reaches the daemon"
				);
				hold.release()!!;
				check(
					control_eventually(bus, control, "Calls", "ReleaseProfile(1)"),
					"releasing the hold calls ReleaseProfile"
				);
			}
			else
			{
				check(false, "hold_profile succeeds");
			}
		}
		else
		{
			check(false, "hold_profile is accepted by the modern interface");
		}
	}
	else
	{
		if (catch err = svc.hold_profile(Profile.PERFORMANCE, "x"))
		{
			check(err == error::UNSUPPORTED, "holds are refused without the modern interface");
		}
		else
		{
			check(false, "holds are refused without the modern interface");
		}
	}

	if (try op = svc.inhibit(InhibitKind.KEEP_AWAKE_IDLE, "bleu-test", "testing"))
	{
		defer op.release();
		if (try inhibitor = op.wait())
		{
			check(
				control_eventually(
					bus,
					control,
					"Locks",
					"\"what\": \"idle\", \"mode\": \"block\", \"closed\": false"
				),
				"idle inhibitor is held by logind"
			);
			inhibitor.release()!!;
			check(
				control_eventually(bus, control, "Locks", "\"what\": \"idle\", \"mode\": \"block\", \"closed\": true"),
				"releasing the inhibitor closes its descriptor"
			);
		}
		else
		{
			check(false, "inhibit succeeds");
		}
	}

	if (try op = svc.can(Action.SUSPEND))
	{
		defer op.release();
		check((op.wait() ?? availability::no(availability::Reason.BACKEND_STOPPED, "")).ok(), "can(SUSPEND) is yes");
	}
	else
	{
		check(false, "can(SUSPEND) is asked");
	}
	if (try op = svc.can(Action.HIBERNATE))
	{
		defer op.release();
		check(
			(op.wait() ?? availability::YES).reason == availability::Reason.PERMISSION_NEEDED,
			"can(HIBERNATE) is challenge"
		);
	}
	else
	{
		check(false, "can(HIBERNATE) is asked");
	}
	if (try op = svc.can(Action.HYBRID_SLEEP))
	{
		defer op.release();
		check(
			(op.wait() ?? availability::YES).reason == availability::Reason.HARDWARE_ABSENT,
			"can(HYBRID_SLEEP) is na"
		);
	}
	else
	{
		check(false, "can(HYBRID_SLEEP) is asked");
	}

	if (try op = svc.perform(Action.SUSPEND))
	{
		defer op.release();
		check((op.wait() ?? Action.HIBERNATE) == Action.SUSPEND, "perform(SUSPEND) is accepted");
	}
	else
	{
		check(false, "perform(SUSPEND) is accepted by the service");
	}
	check(control_eventually(bus, control, "Calls", "Suspend(true)"), "Suspend reaches logind with interactive set");
	// Hibernate is available (the polkit check is the daemon's), so the request reaches logind and polkit answers.
	if (try op = svc.perform(Action.HIBERNATE))
	{
		defer op.release();
		if (catch err = op.wait())
		{
			check(err == error::AUTH_REQUIRED, "a polkit refusal maps to AUTH_REQUIRED");
		}
		else
		{
			check(false, "a polkit refusal is reported");
		}
	}
	else
	{
		check(false, "perform(HIBERNATE) reaches polkit");
	}
	if (try op = svc.perform(Action.LOCK))
	{
		defer op.release();
		check((op.wait() ?? Action.SUSPEND) == Action.LOCK, "perform(LOCK) is accepted");
	}
	else
	{
		check(false, "perform(LOCK) is accepted by the service");
	}
	check(control_eventually(bus, control, "Calls", "Session.Lock()"), "lock reaches the session object");

	run_event_checks(svc, bus, control);
}

fn void run_event_checks(Power* svc, Connection* bus, Proxy* control)
{
	if (try reader = svc.subscribe())
	{
		defer reader.release();
		control_bool(bus, control, "SetLidClosed", true);
		check(got(reader, EventKind.LID_CLOSED, null), "closing the lid is reported");
		if (try snapshot = svc.latest())
		{
			defer snapshot.release();
			check(
				snapshot.value.lid_closed.has_value && snapshot.value.lid_closed.value,
				"the state says the lid is closed"
			);
		}
		else
		{
			check(false, "the state is published after the lid closes");
		}
		control_bool(bus, control, "SetLidClosed", false);
		check(got(reader, EventKind.LID_OPENED, null), "opening the lid is reported");
		control_bool(bus, control, "SetExternalPower", false);
		check(got(reader, EventKind.EXTERNAL_POWER_DISCONNECTED, null), "unplugging is reported");
		control_bool(bus, control, "SetExternalPower", true);
		check(got(reader, EventKind.EXTERNAL_POWER_CONNECTED, null), "plugging in is reported");
	}
	else
	{
		check(false, "subscribe to events");
	}
}

// The sleep barrier: PREPARE_SLEEP carries a ticket, the delay lock stays until ack, and resume retakes it.
fn void run_barrier_checks(Connection* bus, Proxy* control)
{
	if (try svc = power::open(mem, { .backend = power::Backend.LOGIND, .sleep_barrier = true }))
	{
		defer svc.close();
		check(svc.capability(Cap.DELAY_SLEEP_HOOK).ok(), "the barrier is available with the option");
		check(
			control_eventually(bus, control, "Locks", "\"what\": \"sleep\", \"mode\": \"delay\", \"closed\": false"),
			"the delay lock is held at start"
		);
		if (try reader = svc.subscribe())
		{
			defer reader.release();
			control_bool(bus, control, "EmitPrepareForSleep", true);
			uint ticket = 0;
			check(
				got(reader, EventKind.PREPARE_SLEEP, &ticket) && ticket != 0,
				"PREPARE_SLEEP carries a barrier ticket"
			);
			pause();
			check(
				control_has(bus, control, "Locks", "\"what\": \"sleep\", \"mode\": \"delay\", \"closed\": false"),
				"the delay lock stays until acknowledged"
			);
			svc.ack(ticket)!!;
			check(
				control_eventually(
					bus,
					control,
					"Locks",
					"\"what\": \"sleep\", \"mode\": \"delay\", \"closed\": true"
				),
				"acknowledging closes the delay lock"
			);
			control_bool(bus, control, "EmitPrepareForSleep", false);
			check(got(reader, EventKind.RESUMED, null), "resume is reported");
			check(
				control_eventually(
					bus,
					control,
					"Locks",
					"\"what\": \"sleep\", \"mode\": \"delay\", \"closed\": false"
				),
				"the delay lock is retaken after resume"
			);
		}
		else
		{
			check(false, "subscribe to the barrier's events");
		}
	}
	else
	{
		check(false, "open with the sleep barrier");
	}
}

// A bus address nobody listens on must fail the open, not hang it.
fn void run_failure_checks()
{
	if (catch err = power::open(
		mem,
		{ .backend = power::Backend.LOGIND, .bus_address = "unix:path=/nonexistent/bleu-power-bus" }
	))
	{
		check(
			err == error::UNAVAILABLE || err == error::DISCONNECTED || err == error::PERMISSION_DENIED,
			"open fails when no bus listens"
		);
	}
	else
	{
		check(false, "open fails when no bus listens");
	}
}

// Whether the service answers a profile request, which it can only do with a live bus.
fn bool service_answers(Power* svc)
{
	for (int i = 0; i < 500; i++)
	{
		if (try op = svc.set_profile(Profile.BALANCED))
		{
			defer op.release();
			if (try written = op.wait()) return written == Profile.BALANCED;
		}
		pause();
	}
	return false;
}

// Whether `name` exists, polling for about 20 seconds.
fn bool file_appears(String name)
{
	for (int i = 0; i < 1000; i++)
	{
		if (path::is_file((Path)name)) return true;
		pause();
	}
	return false;
}

// The number of descriptors this process holds, from /proc/self/fd.
fn usz open_descriptors()
{
	@pool()
	{
		PathList entries = fs::list_dir(tmem, "/proc/self/fd")!!;
		return (usz)entries.len();
	};
}

// A release after the service is closed is refused with DISCONNECTED and never touches the freed service.
// Run under valgrind, this is the use-after-free regression: the old code read the closed service.
fn void run_after_close_checks(String mode)
{
	Power*? opened = power::open(mem, { .backend = power::Backend.LOGIND });
	if (catch err = opened)
	{
		check(false, "open the logind mechanism for the release-after-close checks");
		return;
	}
	Power* svc         = opened;
	Inhibitor held;
	bool got_inhibitor = false;
	if (try op = svc.inhibit(InhibitKind.KEEP_AWAKE_IDLE, "bleu-test", "after close"))
	{
		defer op.release();
		if (try inhibitor = op.wait())
		{
			held = inhibitor;
			got_inhibitor = true;
		}
	}
	ProfileHold hold_held;
	bool got_hold = false;
	if (mode == "modern")
	{
		if (try op = svc.hold_profile(Profile.PERFORMANCE, "after close"))
		{
			defer op.release();
			if (try hold = op.wait())
			{
				hold_held = hold;
				got_hold = true;
			}
		}
	}
	svc.close();
	if (!got_inhibitor)
	{
		check(false, "inhibit before the close");
		return;
	}
	if (catch err = held.release())
	{
		check(err == error::DISCONNECTED, "an inhibitor released after close is refused with DISCONNECTED");
	}
	else
	{
		check(false, "an inhibitor released after close is refused");
	}
	if (catch err = held.release())
	{
		check(false, "a second release of the same inhibitor is a no-op");
	}
	else
	{
		check(true, "a second release of the same inhibitor is a no-op");
	}
	if (got_hold)
	{
		if (catch err = hold_held.release())
		{
			check(err == error::DISCONNECTED, "a profile hold released after close is refused with DISCONNECTED");
		}
		else
		{
			check(false, "a profile hold released after close is refused");
		}
	}
}

// The bus restarts under a live service (run.sh does it while this waits). Before the
// restart the service holds an inhibitor. After it: the service answers again, releasing the
// old inhibitor closes its descriptor, and a new inhibitor can be taken.
fn void run_bounce_checks()
{
	String dir     = env::tget_var("BLEU_POWER_BOUNCE_DIR")!!;
	Power*? opened = power::open(mem, { .backend = power::Backend.LOGIND });
	if (catch err = opened)
	{
		check(false, "open the logind mechanism for the bus restart");
		return;
	}
	Power* svc = opened;
	defer svc.close();
	Inhibitor held;
	bool got_inhibitor = false;
	if (try op = svc.inhibit(InhibitKind.KEEP_AWAKE_IDLE, "bleu-test", "before the restart"))
	{
		defer op.release();
		if (try inhibitor = op.wait())
		{
			held = inhibitor;
			got_inhibitor = true;
		}
	}
	if (!got_inhibitor)
	{
		check(false, "inhibit before the bus restart");
		return;
	}
	fs::write_text(string::tformat("%s/ready", dir), "1")!!;
	check(file_appears(string::tformat("%s/bounced", dir)), "the harness restarted the bus");
	check(service_answers(svc), "the service answers again after the bus restarts");
	usz before = open_descriptors();
	if (catch err = held.release())
	{
		check(false, "releasing an inhibitor taken before the restart is accepted");
	}
	else
	{
		check(open_descriptors() + 1 == before, "releasing it closes its descriptor");
	}
	if (try op = svc.inhibit(InhibitKind.KEEP_AWAKE_IDLE, "bleu-test", "after the restart"))
	{
		defer op.release();
		if (try inhibitor = op.wait())
		{
			check(true, "a new inhibitor is taken after the restart");
		}
		else
		{
			check(false, "a new inhibitor is taken after the restart");
		}
	}
	else
	{
		check(false, "a new inhibitor is requested after the restart");
	}
}