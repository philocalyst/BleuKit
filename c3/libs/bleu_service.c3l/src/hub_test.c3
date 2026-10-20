module bleu::service::hub_test;
import std::io, std::time, std::thread, bleu::error, bleu::rt::worker, bleu::service, bleu::observe, bleu::stream;

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

fn void hub_publishes_state_and_events() @test
{
	DemoHub hub;
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
int abandoned_total;

fn void count_abandoned(void* backend, DemoCommand* command)
{
	abandoned_total += command.by;
}

fn void bails_out_at_once(void* backend, DemoHub* hub, Host{DemoCommand}* host)
{
	// An early error exit: returns without ever serving the mailbox.
}

fn void commands_left_behind_are_abandoned_not_lost() @test
{
	abandoned_total = 0;
	DemoHub hub;
	hub.start(mem, "demo", "fake", &bails_out_at_once, null, abandon: &count_abandoned)!!;
	// Give the worker time to run and return, then post: the mailbox is closed, so the post is refused.
	thread::sleep_ms(50)!!;
	assert(@catch(hub.post({ BUMP, 4 })) == error::UNAVAILABLE, "closed mailbox refuses new commands");
	hub.stop();
	assert(abandoned_total == 0, "nothing was queued before the bail-out");
}

fn void queued_commands_reach_abandon_on_stop() @test
{
	abandoned_total = 0;
	DemoHub hub;
	// run_slow serves nothing: it just waits for stop, so queued commands stay queued.
	hub.start(mem, "demo", "fake", &waits_for_stop, null, abandon: &count_abandoned)!!;
	hub.post({ BUMP, 3 })!!;
	hub.post({ BUMP, 5 })!!;
	hub.stop();
	assert(abandoned_total == 8, "both queued commands were handed to abandon");
}

fn void waits_for_stop(void* backend, DemoHub* hub, Host{DemoCommand}* host)
{
	while (!host.stopping()) thread::sleep_ms(2)!!;
}
