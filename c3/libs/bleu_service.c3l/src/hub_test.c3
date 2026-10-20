module bleu::service::hub_test;
import std::io, std::time, std::thread, bleu::error, bleu::rt::foreign, bleu::rt::worker, bleu::service, bleu::observe, bleu::stream;

struct DemoState
{
	int counter;
}
enum DemoCommandKind : char
{
	BUMP
}
struct DemoCommand
{
	DemoCommandKind kind;
	int by;
}
struct DemoEvent
{
	int bumped_to;
}
alias DemoHub = Hub{DemoState, DemoCommand, DemoEvent};

// Totals kept by the worker and read by the test after `stop` has joined it.
int processed_total;
int abandoned_total;

fn void demo_run(void* backend, DemoHub* hub, Host{DemoCommand}* host)
{
	int counter = 0;
	DemoCommand[8] buffer;
	while (!host.stopping())
	{
		usz n = host.mailbox().take_all(&buffer);
		for (usz i = 0; i < n; i++)
		{
			counter += buffer[i].by;
			Snapshot{DemoState}* s = hub.begin();
			s.value.counter = counter;
			hub.publish(s);
			Packet{DemoEvent}* p = hub.emit_begin();
			p.value.bumped_to = counter;
			hub.emit(p);
		}
		// A real backend waits in a Poller on its sources plus host.wakeup(); this test only needs the loop to turn.
		thread::sleep_ms(2)!!;
	}
}

// Takes commands and counts them, pausing between rounds so that the queue can fill.
fn void counting_run(void* backend, DemoHub* hub, Host{DemoCommand}* host)
{
	DemoCommand[8] buffer;
	while (!host.stopping())
	{
		usz n = host.mailbox().take_all(&buffer);
		processed_total += (int)n;
		thread::sleep_ms(1)!!;
	}
}

fn void count_abandoned(void* backend, DemoCommand* command)
{
	abandoned_total += command.by;
}

fn void hub_publishes_state_and_events() @test
{
	DemoHub hub;
	defer hub.free();
	hub.start(mem, "demo", "fake", &demo_run, null)!!;
	Reader{DemoEvent}* reader = hub.events.subscribe()!!;
	hub.post({ BUMP, 5 })!!;
	hub.post({ BUMP, 2 })!!;
	Snapshot{DemoState}* s = hub.state.wait_after(1, time::ms(2000))!!;
	assert(s.value.counter == 7, "state after two bumps");
	s.release();
	Packet{DemoEvent}* first = reader.next(time::ms(2000))!!;
	assert(first.value.bumped_to == 5, "first event");
	first.release();
	reader.release();
	hub.stop();
	assert(@catch(hub.state.latest()) == error::UNAVAILABLE, "closed hub has no state");
}

fn void bails_out_at_once(void* backend, DemoHub* hub, Host{DemoCommand}* host)
{
	// An early error exit: returns without ever serving the mailbox.
}

fn void commands_left_behind_are_abandoned_not_lost() @test
{
	abandoned_total = 0;
	DemoHub hub;
	defer hub.free();
	hub.start(mem, "demo", "fake", &bails_out_at_once, null, abandon: &count_abandoned)!!;
	// Give the worker time to run and return, then post: the mailbox is closed, so the post is refused.
	thread::sleep_ms(50)!!;
	test::@error(hub.post({ BUMP, 4 }), error::UNAVAILABLE);
	hub.stop();
	assert(abandoned_total == 0, "nothing was queued before the bail-out");
}

fn void waits_for_stop(void* backend, DemoHub* hub, Host{DemoCommand}* host)
{
	while (!host.stopping()) thread::sleep_ms(2)!!;
}

fn void queued_commands_reach_abandon_on_stop() @test
{
	abandoned_total = 0;
	DemoHub hub;
	defer hub.free();
	// waits_for_stop serves nothing: it just waits for stop, so queued commands stay queued.
	hub.start(mem, "demo", "fake", &waits_for_stop, null, abandon: &count_abandoned)!!;
	hub.post({ BUMP, 3 })!!;
	hub.post({ BUMP, 5 })!!;
	hub.stop();
	assert(abandoned_total == 8, "both queued commands were handed to abandon");
}

fn void without_abandon_leftover_commands_are_dropped_and_stop_returns() @test
{
	DemoHub hub;
	defer hub.free();
	hub.start(mem, "demo", "fake", &waits_for_stop, null)!!;
	hub.post({ BUMP, 1 })!!;
	// Dropped with a log line on stderr; the stop must still return.
	hub.stop();
	test::@error(hub.post({ BUMP, 1 }), error::UNAVAILABLE);
}

fn void posts_are_refused_when_the_hub_is_not_running() @test
{
	DemoHub idle;
	defer idle.free();
	test::@error(idle.post({ BUMP, 1 }), error::UNAVAILABLE);
	idle.stop();
	idle.free();
	test::@error(idle.post({ BUMP, 1 }), error::UNAVAILABLE);
	test::@error(idle.latest(), error::UNAVAILABLE);
}

fn void start_twice_is_refused_and_a_freed_hub_starts_again() @test
{
	DemoHub hub;
	defer hub.free();
	hub.start(mem, "demo", "fake", &waits_for_stop, null)!!;
	test::@error(hub.start(mem, "demo", "fake", &waits_for_stop, null), error::INVALID_STATE);
	hub.stop();
	test::@error(hub.start(mem, "demo", "fake", &waits_for_stop, null), error::INVALID_STATE);
	hub.free();
	hub.start(mem, "demo", "fake", &demo_run, null)!!;
	hub.post({ BUMP, 9 })!!;
	Snapshot{DemoState}* s = hub.state.wait_after(0, time::ms(2000))!!;
	assert(s.value.counter == 9, "the restarted hub serves its backend");
	s.release();
}

// Poster thread: posts until a post is refused as UNAVAILABLE (the hub stopped).
struct Poster
{
	DemoHub* hub;
	int accepted;
	bool saw_stop;
}

fn int poster_loop(void* context)
{
	Poster* poster = (Poster*)context;
	foreign::@foreign_entry()
	{
		while (true)
		{
			if (catch err = poster.hub.post({ BUMP, 1 }))
			{
				// BUSY just means the queue is full for now; UNAVAILABLE means the hub stopped.
				if (err == error::UNAVAILABLE)
				{
					poster.saw_stop = true;
					break;
				}
			}
			else
			{
				poster.accepted++;
			}
		}
	};
	return 0;
}

// A post racing with `stop`: every accepted command is either processed by the backend or
// abandoned at stop, never lost and never run twice. The hub is not freed until the poster
// has returned, which is the rule `free` documents.
fn void posts_racing_stop_are_each_processed_or_abandoned() @test
{
	for (int round = 0; round < 200; round++)
	{
		processed_total = 0;
		abandoned_total = 0;
		DemoHub hub;
		hub.start(mem, "demo", "fake", &counting_run, null, max_queue: 4, abandon: &count_abandoned)!!;
		Poster poster = { .hub = &hub };
		Thread thread_handle;
		thread_handle.create(&poster_loop, &poster)!!;
		// Vary how long the poster runs before the stop, so that the stop lands in different places.
		if (round % 3 != 0) thread::sleep_ms(1)!!;
		hub.stop();
		thread_handle.join()!!;
		test::@check(poster.saw_stop, "the poster ends on UNAVAILABLE once the hub stopped");
		test::eq(poster.accepted, processed_total + abandoned_total);
		hub.free();
	}
}