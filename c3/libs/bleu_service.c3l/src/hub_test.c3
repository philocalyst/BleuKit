module bleu::service::hub_test;
import std::io, std::time, std::thread, bleu::error, bleu::rt::worker, bleu::service, bleu::observe, bleu::stream;

struct DemoState { int counter; }
enum DemoCommandKind : char { BUMP }
struct DemoCommand { DemoCommandKind kind; int by; }
struct DemoEvent { int bumped_to; }
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
