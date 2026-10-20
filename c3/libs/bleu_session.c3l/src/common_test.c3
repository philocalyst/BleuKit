module bleu::session::common_test;
import std::collections::list, std::time, bleu::session;

fn void reached_is_inclusive() @test
{
	Duration minute = (Duration)60_000_000;
	assert(session::reached((Duration)59_999_999, minute) == false);
	assert(session::reached(minute, minute) == true);
	assert(session::reached((Duration)0, time::DURATION_ZERO) == true);
}

fn void negative_seconds_are_no_idle_time() @test
{
	assert(session::duration_of_seconds(-1.5) == time::DURATION_ZERO);
	assert(session::duration_of_seconds(2.5) == (Duration)2_500_000);
	assert(session::seconds_of((Duration)1_500_000) == 1.5);
}

fn void session_type_names_map_to_their_variants() @test
{
	assert(session::session_type_of("wayland") == WAYLAND);
	assert(session::session_type_of("x11") == X11);
	assert(session::session_type_of("tty") == TTY);
	assert(session::session_type_of("unspecified") == UNSPECIFIED);
	assert(session::session_type_of("mir") == MIR);
	assert(session::session_type_of("") == UNKNOWN);
	assert(session::session_type_of("Wayland") == UNKNOWN);
}

fn void idle_edges_follow_their_watch() @test
{
	Duration[2] thresholds = { (Duration)60_000_000, (Duration)300_000_000 };
	IdleRegistry registry;
	registry.init(mem, thresholds[..]);
	defer registry.free();
	List{Event} pending;
	pending.init(mem);
	defer pending.free();
	Command watch = { .kind = CommandKind.WATCH_IDLE, .watch = 7, .threshold = (Duration)10_000_000 };
	registry.apply(&watch);

	// Ten seconds of idle time reaches the watch (10 s) and nothing configured.
	registry.advance((Duration)10_000_000, &pending);
	assert(pending.len() == 1 && pending.get(0).kind == EventKind.IDLE && pending.get(0).watch == 7);
	// The same idle time again is not a new edge.
	registry.advance((Duration)10_000_000, &pending);
	assert(pending.len() == 1, "an edge fires once per crossing");
	// Input resets the idle time: RESUMED, for the same watch.
	registry.advance(time::DURATION_ZERO, &pending);
	assert(pending.len() == 2 && pending.get(1).kind == EventKind.RESUMED && pending.get(1).watch == 7);

	// Once unwatched, the slot is gone; the configured thresholds still report.
	Command unwatch = { .kind = CommandKind.UNWATCH_IDLE, .watch = 7 };
	registry.apply(&unwatch);
	registry.advance((Duration)999_000_000, &pending);
	assert(pending.len() == 4, "the two configured thresholds crossed");
	for (sz i = 2; i < pending.len(); i++)
	{
		assert(pending.get(i).watch == 0 && pending.get(i).kind == EventKind.IDLE, "configured edges carry no watch");
	}
	IdleStatus[] statuses = registry.statuses(mem);
	defer alloc::free(mem, statuses.ptr);
	assert(statuses.len == 2 && statuses[0].idle && statuses[1].idle, "both configured thresholds are reached");
	assert(statuses[0].threshold == thresholds[0] && statuses[1].threshold == thresholds[1], "in the order given");
}

fn void polled_records_each_change_once() @test
{
	Duration[] none;
	Polled polled;
	polled.init(mem, none);
	defer polled.free();
	polled.record(EventKind.LOCKED);
	polled.record(EventKind.LOCKED);
	polled.record(EventKind.UNLOCKED);
	polled.record(EventKind.WILL_SLEEP);
	polled.record(EventKind.WILL_SLEEP);
	assert(polled.pending.len() == 3, "a repeated change is not recorded again");
	session::apply_pending(&polled.pending, &polled.locked, &polled.sleeping);
	assert(polled.locked.has_value && !polled.locked.value, "the last lock change wins");
	assert(polled.sleeping, "the system is asleep");
	polled.pending.clear();
	polled.record(EventKind.UNLOCKED);
	polled.record(EventKind.DID_WAKE);
	assert(polled.pending.len() == 1 && polled.pending.get(0)
		.kind == EventKind.DID_WAKE, "an unchanged lock is not recorded");
}

fn void retry_delay_doubles_up_to_thirty_seconds() @test
{
	assert(session::retry_delay(0) == (Duration)1_000_000, "the first retry waits one second");
	assert(session::retry_delay(1) == (Duration)1_000_000);
	assert(session::retry_delay(2) == (Duration)2_000_000);
	assert(session::retry_delay(5) == (Duration)16_000_000);
	assert(session::retry_delay(6) == (Duration)30_000_000, "the wait is capped at 30 seconds");
	assert(session::retry_delay(1000) == (Duration)30_000_000);
}
