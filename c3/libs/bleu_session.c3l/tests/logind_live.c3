// Live tests against mock_logind.py: the logind backend of bleu_session on a private system bus.
// run.sh starts the bus and the mock, and sets DBUS_SYSTEM_BUS_ADDRESS to that bus.
module bleu::session::logind_live_test @feat(LINUX);
import std::os::env, std::time, bleu::availability, bleu::dbus::connection, bleu::dbus::message, bleu::dbus::proxy, bleu::error, bleu::observe, bleu::operation, bleu::session, bleu::stream;

// How long a test waits for the mock to answer or for a signal to arrive.
const Duration STEP = (Duration)3_000_000;

// Advance from `current` (released here) until `locked` is `wanted`, up to 20 states.
fn Snapshot{State}* settle_locked(Session* service, Snapshot{State}* current, bool wanted) @local
{
	Snapshot{State}* latest = current;
	for (usz i = 0; i < 20; i++)
	{
		if (latest.value.locked.has_value && latest.value.locked.value == wanted) return latest;
		Snapshot{State}* next = service.wait_after(latest.generation, STEP)!!;
		latest.release();
		latest = next;
	}
	return latest;
}

// Read events from `reader` until one of `kind` arrives (the others are skipped).
fn void expect_event(stream::Reader{Event}* reader, EventKind kind) @local
{
	for (usz i = 0; i < 10; i++)
	{
		Snapshot{Event}* packet = reader.next(STEP)!!;
		defer packet.release();
		if (packet.value.kind == kind) return;
	}
	unreachable("the expected event never arrived");
}

// Carry out a request and check that it completed with `request`.
fn void expect_success(SessionOperation* operation, Request request) @local
{
	defer operation.release();
	Request done = operation.wait(STEP)!!;
	assert(done == request, "the request completed with what was asked");
}

// Ask the mock to suspend, the way logind's Manager.Suspend does.
fn void suspend_through_logind() @local
{
	Connection bus;
	bus.init(mem);
	defer bus.free();
	bus.open_system()!!;
	defer bus.close();
	proxy::Proxy manager = proxy::for_object(
		&bus,
		"org.freedesktop.login1",
		"/org/freedesktop/login1",
		"org.freedesktop.login1.Manager"
	)!!;
	Message* call = manager.new_call(mem, "Suspend")!!;
	defer call.release();
	call.body_writer("b")!!.append_bool(false)!!;
	Message* reply = bus.call(call)!!;
	reply.release();
}

fn void drives_logind_end_to_end() @test
{
	Session* service = session::open(mem, { .backend = LOGIND })!!;
	defer service.close();
	assert(service.backend_name() == "logind", "logind is the backend");
	assert(service.capability(Cap.IDLE_WATCH)
		.reason == availability::Reason.UNSUPPORTED_BACKEND, "idle is refused until bleu_wl lands");
	assert(service.capability(Cap.LOCK).ok(), "this process has a session to lock");

	stream::Reader{Event}* events = service.subscribe()!!;
	defer events.release();

	Snapshot{State}* first = service.wait_after(0, STEP)!!;
	defer first.release();
	State* state = &first.value;
	assert(state.locked.has_value && !state.locked.value, "the session is not locked");
	assert(state.current.id == "32", "this process is session 32");
	assert(state.current.user == "alice", "the session user is alice");
	assert(state.current.uid.has_value && state.current.uid.value == 1000, "uid 1000");
	assert(state.current.seat == "seat0", "the session is on seat0");
	assert(state.current.type == WAYLAND, "the session type is wayland");
	assert(state.current.active.has_value && state.current.active.value, "the session is active");
	assert(state.current.remote.has_value && !state.current.remote.value, "the session is local");
	assert(state.idle_hint.has_value && !state.idle_hint.value, "IdleHint is read from the session");
	assert(state.seats.len == 1 && state.seats[0] == "seat0", "one seat");
	assert(state.sessions.len == 2, "two sessions");
	assert(state.sessions[1].id == "c1" && state.sessions[1].type == TTY, "the tty session c1 is listed");
	assert(state.sessions[1].remote.has_value && state.sessions[1].remote.value, "c1 is remote");
	assert(state.sessions[1].seat == "", "c1 has no seat");
	assert(!state.sleeping, "the system is awake");

	// Lock this session: the mock's locker sets LockedHint, the snapshot shows it, and LOCKED is announced.
	expect_success(service.lock()!!, LOCK);
	Snapshot{State}* locked = settle_locked(service, service.wait_after(first.generation, STEP)!!, true);
	defer locked.release();
	assert(locked.value.locked.has_value && locked.value.locked.value, "the session is locked");
	expect_event(events, LOCKED);

	expect_success(service.unlock()!!, UNLOCK);
	Snapshot{State}* unlocked = settle_locked(service, service.wait_after(locked.generation, STEP)!!, false);
	defer unlocked.release();
	assert(unlocked.value.locked.has_value && !unlocked.value.locked.value, "the session is unlocked again");
	expect_event(events, UNLOCKED);

	// Other sessions are asked for by id; the mock logs the call.
	expect_success(service.lock_session("c1")!!, LOCK_SESSION);

	// logind refuses a session it does not know; the operation fails rather than succeeding silently.
	SessionOperation* refused = service.terminate_session("nope")!!;
	defer refused.release();
	if (catch err = refused.wait(STEP))
	{
		// bleu_dbus maps no org.freedesktop.login1 names, so NoSuchSession is BACKEND_FAILURE; the text is in error::last().
		assert(err == error::BACKEND_FAILURE, "an unknown session is refused by logind");
	}
	else
	{
		unreachable("terminating an unknown session must fail");
	}

	// Idle is not measured on logind: the watch is refused, not faked.
	if (catch err = service.watch_idle((Duration)1_000_000))
	{
		assert(err == error::UNSUPPORTED, "idle watches are UNSUPPORTED on logind");
	}
	else
	{
		unreachable("idle watches must be refused on logind");
	}

	// Sleep: logind announces PrepareForSleep around the suspend, and the state follows it.
	suspend_through_logind();
	expect_event(events, WILL_SLEEP);
	if (try asleep = service.latest())
	{
		defer asleep.release();
		assert(asleep.value.sleeping, "the state shows the sleep before its event is read");
	}
	expect_event(events, DID_WAKE);
	if (try awake = service.latest())
	{
		defer awake.release();
		assert(!awake.value.sleeping, "the state shows the wake");
	}
}