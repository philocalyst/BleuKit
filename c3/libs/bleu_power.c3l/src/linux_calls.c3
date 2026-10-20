<*
 The requests the Linux mechanism serves on its worker thread: profile set and
 hold, inhibitors, capability answers, actions, and the sleep acknowledgement.
 Every bus call here is synchronous on the worker; the caller only waits on the
 operation it was given.
*>
module bleu::power::logind @feat(LINUX);
import bleu::dbus::marshal, bleu::dbus::message, bleu::dbus::value, bleu::dbus::proxy, bleu::availability, bleu::error, bleu::power, bleu::power::convert, bleu::rt::unix, bleu::service;

<* One request dispatched by the worker. Requests with no operation report nothing. *>
fn void dispatch(Logind* b, Command* command)
{
	// Releases and the sleep acknowledgement act on descriptors this process holds: they need no bus.
	if (command.kind == RELEASE_INHIBITOR)
	{
		release_inhibitor(b, command.number);
		return;
	}
	if (command.kind == ACK_SLEEP)
	{
		acknowledge(b, command.number);
		return;
	}
	// A profile hold lives with its bus connection: once the bus is lost, the daemon has dropped it already.
	if (command.kind == RELEASE_PROFILE)
	{
		if (b.bus_alive)
		{
			if (catch err = release_profile(b, command.number)) b.note_failure(err);
		}
		return;
	}
	if (!b.bus_alive)
	{
		power::abort_command(command, error::DISCONNECTED);
		return;
	}
	switch (command.kind)
	{
		case SET_PROFILE:
			Profile? profile = set_profile(b, command.profile);
			if (catch err = profile)
			{
				power::abort{Profile}(command.profile_op, err);
			}
			else
			{
				power::finish{Profile}(command.profile_op, profile);
			}
		case HOLD_PROFILE:
			ProfileHold? hold = hold_profile(b, command);
			if (catch err = hold)
			{
				power::abort{ProfileHold}(command.hold_op, err);
			}
			else
			{
				power::finish{ProfileHold}(command.hold_op, hold);
			}
		case INHIBIT:
			Inhibitor? inhibitor = inhibit(b, command);
			if (catch err = inhibitor)
			{
				power::abort{Inhibitor}(command.inhibit_op, err);
			}
			else
			{
				power::finish{Inhibitor}(command.inhibit_op, inhibitor);
			}
		case RELEASE_INHIBITOR:
		case RELEASE_PROFILE:
		case ACK_SLEEP: return;
		case CAN:
			Availability? answer = can(b, command.action);
			if (catch err = answer)
			{
				power::abort{Availability}(command.can_op, err);
			}
			else
			{
				power::finish{Availability}(command.can_op, answer);
			}
		case PERFORM:
			Action? performed = perform(b, command.action);
			if (catch err = performed)
			{
				power::abort{Action}(command.action_op, err);
			}
			else
			{
				power::finish{Action}(command.action_op, performed);
			}
	}
}

// Write ActiveProfile through power-profiles-daemon; the value is the profile written.
fn Profile? set_profile(Logind* b, Profile profile)
{
	if (!b.has_profiles)
	{
		return error::raise(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "power-profiles-daemon is not on the bus")~;
	}
	String name = convert::profile_name(profile)!;
	@pool()
	{
		Value value = value::str(tmem, name)!;
		b.profiles.set_property("ActiveProfile", value)!;
	};
	return profile;
}

// HoldProfile(profile, reason, application id) on the modern interface.
fn ProfileHold? hold_profile(Logind* b, Command* command)
{
	if (!b.has_modern_profiles)
	{
		return error::raise(
			error::UNSUPPORTED,
			error::Domain.INTERNAL,
			0,
			"the legacy interface cannot hold profiles"
		)~;
	}
	String name = convert::profile_name(command.profile)!;
	uint cookie = hold_call(b, name, command.why)!;
	return make_hold(command, cookie);
}

fn uint? hold_call(Logind* b, String profile, String reason)
{
	Message* call = b.profiles.new_call(b.allocator, "HoldProfile")!;
	defer call.release();
	Writer* writer = call.body_writer("sss")!;
	writer.append_string(profile)!;
	writer.append_string(reason)!;
	writer.append_string(APPLICATION_ID)!;
	Message* reply = b.bus.call(call)!;
	defer reply.release();
	return reply.reader()!.read_u32()!;
}

// ReleaseProfile(cookie) on the modern interface.
fn void? release_profile(Logind* b, uint cookie)
{
	if (!b.has_modern_profiles) return;
	Message* call = b.profiles.new_call(b.allocator, "ReleaseProfile")!;
	defer call.release();
	call.body_writer("u")!.append_u32(cookie)!;
	Message* reply = b.bus.call(call)!;
	reply.release();
}

// The logind arguments of one inhibitor kind: what it blocks and the mode.
struct InhibitRequest
{
	String what;
	String mode;
}

// Display inhibitors have no logind equivalent, so that kind is refused here.
fn InhibitRequest? inhibit_request(InhibitKind kind)
{
	switch (kind)
	{
		case KEEP_AWAKE_IDLE: return { .what = "idle", .mode = "block" };
		case KEEP_AWAKE_SYSTEM: return { .what = "sleep", .mode = "block" };
		case SLEEP_DELAY: return { .what = "sleep", .mode = "delay" };
		case SHUTDOWN_BLOCK: return { .what = "shutdown", .mode = "block" };
		case KEEP_AWAKE_DISPLAY: return error::UNSUPPORTED~;
	}
}

fn Inhibitor? inhibit(Logind* b, Command* command)
{
	InhibitRequest request = inhibit_request(command.inhibit)!;
	unix::Fd fd            = inhibit_fd(b, request.what, command.who, command.why, request.mode)!;
	uint id                = ++b.next_lock;
	b.locks.push({ .id = id, .fd = fd });
	return make_inhibitor(command, id);
}

// Inhibit(what, who, why, mode): the reply's descriptor is duplicated, because the reply owns the original.
fn unix::Fd? inhibit_fd(Logind* b, String what, String who, String why, String mode)
{
	Message* call = b.manager.new_call(b.allocator, "Inhibit")!;
	defer call.release();
	Writer* writer = call.body_writer("ssss")!;
	writer.append_string(what)!;
	writer.append_string(who)!;
	writer.append_string(why)!;
	writer.append_string(mode)!;
	Message* reply = b.bus.call(call)!;
	defer reply.release();
	uint index        = reply.reader()!.read_unix_fd()!;
	int raw           = reply.unix_fd(index)!;
	unix::Fd received = { .value = raw };
	return received.dup_cloexec();
}

// Close the descriptor of the inhibitor with `id`; closing it releases the lock.
fn void release_inhibitor(Logind* b, uint id)
{
	foreach (i, &held : b.locks)
	{
		if (held.id != id) continue;
		// Fd.close releases the descriptor even when close(2) fails; there is nothing to retry.
		if (catch err = held.fd.close())
		{
		}
		b.locks.remove_at(i);
		return;
	}
}

// Whether `action` can be performed: the logind `Can*` answer, or the session check for lock and logout.
fn Availability? can(Logind* b, Action action)
{
	switch (action)
	{
		case SUSPEND: return can_answer(b, "CanSuspend");
		case HIBERNATE: return can_answer(b, "CanHibernate");
		case HYBRID_SLEEP: return can_answer(b, "CanHybridSleep");
		case POWER_OFF: return can_answer(b, "CanPowerOff");
		case REBOOT: return can_answer(b, "CanReboot");
		case LOCK:
		case LOGOUT: return b.capabilities.get(power::action_cap(action));
	}
}

// The text of a `Can*` answer, copied into temporary memory (the caller opens the pool).
fn String? can_text(Logind* b, String member)
{
	Message* call = b.manager.new_call(b.allocator, member)!;
	defer call.release();
	Message* reply = b.bus.call(call)!;
	defer reply.release();
	return reply.reader()!.read_string()!.copy(tmem);
}

fn Availability? can_answer(Logind* b, String member)
{
	@pool()
	{
		String answer = can_text(b, member)!;
		return convert::availability_from_can(answer);
	};
}

<*
 The capability of an action from its `Can*` answer read at open: refused for good when
 logind says the hardware lacks it or the configuration forbids it, otherwise available
 (polkit may still ask the user, and an inhibitor may block it for now).
*>
fn Availability? action_availability(Logind* b, String member)
{
	@pool()
	{
		String answer = can_text(b, member)!;
		if (convert::refused_at_open(answer)) return convert::availability_from_can(answer);
		return availability::YES;
	};
}

// Perform the action. Manager methods get `interactive = true`, so polkit may ask the user; nothing is bypassed.
fn Action? perform(Logind* b, Action action)
{
	switch (action)
	{
		case SUSPEND: call_empty(b, &b.manager, "Suspend", true)!;
		case HIBERNATE: call_empty(b, &b.manager, "Hibernate", true)!;
		case HYBRID_SLEEP: call_empty(b, &b.manager, "HybridSleep", true)!;
		case POWER_OFF: call_empty(b, &b.manager, "PowerOff", true)!;
		case REBOOT: call_empty(b, &b.manager, "Reboot", true)!;
		case LOCK: call_empty(b, &b.session, "Lock", false)!;
		case LOGOUT: call_empty(b, &b.session, "Terminate", false)!;
	}
	return action;
}

// A method without arguments, or with the one `interactive` boolean that logind's action methods take.
fn void? call_empty(Logind* b, Proxy* proxy, String member, bool interactive)
{
	Message* call = proxy.new_call(b.allocator, member)!;
	defer call.release();
	if (interactive)
	{
		call.flags = (char)(call.flags | message::FLAG_ALLOW_INTERACTIVE_AUTHORIZATION);
		call.body_writer("b")!.append_bool(true)!;
	}
	Message* reply = b.bus.call(call)!;
	reply.release();
}

// Acknowledge a sleep barrier. A ticket that is no longer waited for is ignored: logind has passed it.
fn void acknowledge(Logind* b, uint ticket)
{
	if (b.barrier_ticket == 0 || b.barrier_ticket != ticket) return;
	b.barrier_ticket = 0;
	// Fd.close releases the descriptor even when close(2) fails; there is nothing to retry.
	if (catch err = b.barrier.close())
	{
	}
}