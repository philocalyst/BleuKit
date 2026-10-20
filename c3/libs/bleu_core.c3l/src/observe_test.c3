module bleu::observe_test;
import bleu::observe, bleu::error, std::core::test, std::thread, std::time;

alias WatchId = observe::WatchId{int};

// What a recording listener has seen, written on the thread that delivers.
struct Seen
{
	int calls;
	int last;
}

fn void record(void* context, observe::Snapshot{int}* snapshot)
{
	Seen* seen = (Seen*)context;
	seen.calls++;
	seen.last = snapshot.value;
}

fn void publish_value(observe::Observable{int}* state, int value)
{
	observe::Snapshot{int}* snapshot = observe::begin{int}(mem);
	snapshot.value = value;
	state.publish(snapshot);
}

fn void publish_numbers_and_read_the_newest() @test
{
	observe::Observable{int} state;
	state.init(mem);
	defer state.destroy();
	test::@error(state.latest(), error::UNAVAILABLE);
	publish_value(&state, 1);
	publish_value(&state, 2);
	observe::Snapshot{int}* newest = state.latest()!!;
	defer newest.release();
	test::eq(2, newest.value);
	test::eq((ulong)2, newest.generation);
}

fn void watch_replays_the_current_state_then_follows() @test
{
	observe::Observable{int} state;
	state.init(mem);
	defer state.destroy();
	publish_value(&state, 10);
	Seen seen;
	WatchId id = state.watch(&record, &seen);
	test::eq(1, seen.calls);
	test::eq(10, seen.last);
	publish_value(&state, 11);
	test::eq(2, seen.calls);
	test::eq(11, seen.last);
	state.unwatch(id)!!;
	publish_value(&state, 12);
	test::eq(2, seen.calls);
}

// Probes what a listener may do to its own observable while it runs.
struct Probe
{
	observe::Observable{int}* state;
	WatchId self_id;
	WatchId nested_id;
	int calls;
	int latest_seen;
	int nested_calls;
	bool self_unwatch_refused;
}

fn void nested_count(void* context, observe::Snapshot{int}* snapshot)
{
	Probe* probe = (Probe*)context;
	probe.nested_calls++;
}

fn void probing(void* context, observe::Snapshot{int}* snapshot)
{
	Probe* probe = (Probe*)context;
	probe.calls++;
	// latest() takes the state lock, which is not held while listeners run.
	if (try newest = probe.state.latest())
	{
		probe.latest_seen = newest.value;
		newest.release();
	}
	if (probe.calls == 2)
	{
		// A listener may register another one; its first call happens right here, nested.
		probe.nested_id = probe.state.watch(&nested_count, probe);
	}
	if (probe.self_id != (WatchId)0)
	{
		if (catch err = probe.state.unwatch(probe.self_id))
		{
			probe.self_unwatch_refused = err == error::INVALID_STATE;
		}
	}
}

fn void a_listener_may_read_watch_and_refuse_to_unwatch_itself() @test
{
	observe::Observable{int} state;
	state.init(mem);
	defer state.destroy();
	publish_value(&state, 1);
	Probe probe = { .state = &state };
	probe.self_id = state.watch(&probing, &probe);
	test::eq(1, probe.calls);
	test::eq(1, probe.latest_seen);
	publish_value(&state, 2);
	test::eq(2, probe.calls);
	test::eq(2, probe.latest_seen);
	test::@check(probe.self_unwatch_refused, "unwatch of the running listener is refused, not deadlocked");
	test::@check(probe.nested_id != (WatchId)0, "the nested watch registered a listener");
	publish_value(&state, 3);
	// The nested listener was called once when it was registered, and once per later publication.
	test::eq(3, probe.calls);
	test::eq(2, probe.nested_calls);
	test::eq(3, probe.latest_seen);
	state.unwatch(probe.nested_id)!!;
	state.unwatch(probe.self_id)!!;
}

// Closes its observable when it sees the value 2.
struct Closer
{
	observe::Observable{int}* state;
	int calls;
}

fn void closing_listener(void* context, observe::Snapshot{int}* snapshot)
{
	Closer* closer = (Closer*)context;
	closer.calls++;
	if (snapshot.value == 2) closer.state.close();
}

fn void close_from_a_listener_stops_further_delivery() @test
{
	observe::Observable{int} state;
	state.init(mem);
	defer state.destroy();
	publish_value(&state, 1);
	Closer closer = { .state = &state };
	WatchId id = state.watch(&closing_listener, &closer);
	test::eq(1, closer.calls);
	publish_value(&state, 2);
	test::eq(2, closer.calls);
	publish_value(&state, 3);
	test::eq(2, closer.calls);
	test::@error(state.latest(), error::UNAVAILABLE);
	test::@error(state.wait_after(0, time::ms(1)), error::DISCONNECTED);
	test::eq((WatchId)0, state.watch(&closing_listener, &closer));
	test::@check(id != (WatchId)0, "the first registration had a token");
}

fn void wait_after_times_out_then_sees_a_newer_publication() @test
{
	observe::Observable{int} state;
	state.init(mem);
	defer state.destroy();
	test::@error(state.wait_after(0, time::ms(5)), TIMEOUT);
	Thread publisher;
	publisher.create(&publish_later, &state)!!;
	observe::Snapshot{int}* newer = state.wait_after(0, time::SEC * 5)!!;
	defer newer.release();
	publisher.join()!!;
	test::eq((ulong)1, newer.generation);
}

fn int publish_later(void* context)
{
	thread::sleep(time::ms(5))!!;
	publish_value((observe::Observable{int}*)context, 7);
	return 0;
}

// What a waiting thread found.
struct Waiter
{
	observe::Observable{int}* state;
	bool disconnected;
}

fn int wait_forever(void* context)
{
	Waiter* waiter = (Waiter*)context;
	if (catch err = waiter.state.wait_after(0))
	{
		waiter.disconnected = err == error::DISCONNECTED;
	}
	return 0;
}

fn void close_wakes_waiters_with_disconnected() @test
{
	observe::Observable{int} state;
	state.init(mem);
	defer state.destroy();
	Waiter waiter = { .state = &state };
	Thread worker;
	worker.create(&wait_forever, &waiter)!!;
	thread::sleep(time::ms(5))!!;
	state.close();
	worker.join()!!;
	test::@check(waiter.disconnected, "a waiter blocked when the observable closes gets DISCONNECTED");
}

// A listener that stays inside its call until released, so an unwatch has to wait for it.
struct Slow
{
	bool entered;
	bool finished;
	int calls;
}

fn void slow_listener(void* context, observe::Snapshot{int}* snapshot)
{
	Slow* slow = (Slow*)context;
	slow.calls++;
	slow.entered = true;
	thread::sleep(time::ms(30))!!;
	slow.finished = true;
}

fn int publish_once(void* context)
{
	publish_value((observe::Observable{int}*)context, 5);
	return 0;
}

fn void unwatch_waits_for_a_listener_running_on_another_thread() @test
{
	observe::Observable{int} state;
	state.init(mem);
	defer state.destroy();
	Slow slow;
	WatchId id = state.watch(&slow_listener, &slow);
	Thread publisher;
	publisher.create(&publish_once, &state)!!;
	for (int wait = 0; wait < 5000 && !slow.entered; wait++) thread::sleep(time::ms(1))!!;
	test::@check(slow.entered, "the publication reached the slow listener");
	state.unwatch(id)!!;
	// unwatch returned only after the listener returned.
	test::@check(slow.finished, "unwatch waited for the running listener");
	publisher.join()!!;
	publish_value(&state, 6);
	test::eq(1, slow.calls);
}
