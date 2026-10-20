// Regression tests for the input service, through a real Hub with fake backends: a switch to an id longer than
// the old 128-byte command field, a switch still queued when the backend stops, and the order in which a state
// is published and its event announced.
module bleu::input::service_test;
import std::thread, std::time, bleu::availability, bleu::error, bleu::observe, bleu::operation, bleu::rt::worker, bleu::service, bleu::stream, bleu::input;

// The id length that broke the old fixed buffer (ID_CAPACITY was 128 bytes).
const usz LONG_ID = 200;
const Duration STEP = (Duration)3_000_000;

// The id length the last switch carried, as the fake backend saw it.
usz seen_id_length;
// How many states the fake backend has published on REFRESH; each one has one more layout.
usz refreshes;

<* Publish a state with `count` layouts whose ids are `first` (and "us" for the rest). The text is copied. *>
fn void publish_layouts(input::InputHub* hub, String first, usz count) @local
{
	Snapshot{input::State}* snapshot = hub.begin();
	input::Layout[] layouts = alloc::new_array(snapshot.allocator(), input::Layout, (sz)count);
	for (usz i = 0; i < count; i++)
	{
		String id = i == 0 ? first : "us";
		layouts[i] = { .id = id.copy(snapshot.allocator()), .name = "" };
	}
	snapshot.value = { .layouts = layouts, .can_switch = count > 1 };
	hub.publish(snapshot);
}

// Takes commands: a switch is acknowledged and its id length recorded; a refresh publishes a longer list.
fn void serves_commands(void* backend, input::InputHub* hub, Host{input::Command}* host) @local
{
	while (!host.stopping())
	{
		input::Command[8] batch;
		usz count = host.mailbox().take_all(batch[..]);
		for (usz i = 0; i < count; i++)
		{
			if (batch[i].kind == input::CommandKind.SWITCH_TO)
			{
				seen_id_length = batch[i].id.len;
				input::succeed_switch(batch[i].operation, input::SwitchOutcome.ACKNOWLEDGED);
				continue;
			}
			refreshes++;
			Snapshot{input::State}* snapshot = hub.begin();
			input::Layout[] layouts = alloc::new_array(snapshot.allocator(), input::Layout, (sz)(refreshes + 1));
			for (usz k = 0; k < layouts.len; k++) layouts[k] = { .id = "de".copy(snapshot.allocator()) };
			snapshot.value = { .layouts = layouts };
			input::publish_state(hub, snapshot);
		}
		if (catch thread::sleep((Duration)1_000))
		{
			// Interrupted: check the stop flag again.
		}
	}
}

// Takes no commands: it only waits for the stop.
fn void waits_without_taking(void* backend, input::InputHub* hub, Host{input::Command}* host) @local
{
	while (!host.stopping())
	{
		if (catch thread::sleep((Duration)1_000))
		{
			// Interrupted: check the stop flag again.
		}
	}
}

// A service whose hub runs `run`, with every capability available.
fn void open_with(input::Input* svc, service::RunFn{input::State, input::Command, input::Event} run) @local
{
	svc.allocator = mem;
	svc.capabilities.init(availability::YES);
	svc.hub.start(mem, "input", "fake", run, null, abandon: &input::abandon_command)!!;
}

fn void switch_carries_an_id_longer_than_the_old_command_field() @test
{
	seen_id_length = 0;
	input::Input svc;
	open_with(&svc, &serves_commands);
	defer svc.hub.stop();
	char[LONG_ID] long_id;
	for (usz i = 0; i < LONG_ID; i++) long_id[i] = 'a';
	publish_layouts(&svc.hub, (String)long_id[..], 2);
	// With no current layout, `next` picks the first one: the long id.
	input::SwitchOperation* operation = svc.next()!!;
	defer operation.release();
	input::SwitchOutcome outcome = operation.wait(STEP)!!;
	assert(outcome == input::SwitchOutcome.ACKNOWLEDGED, "the switch was acknowledged");
	assert(seen_id_length == LONG_ID, "the backend received the whole id");
}

fn void events_follow_the_state_they_announce() @test
{
	refreshes = 0;
	input::Input svc;
	open_with(&svc, &serves_commands);
	defer svc.hub.stop();
	publish_layouts(&svc.hub, "us", 1);
	stream::Reader{input::Event}* reader = svc.subscribe()!!;
	defer reader.release();
	// The refresh publishes a state with one more layout and announces it.
	svc.refresh()!!;
	Snapshot{input::Event}* packet = reader.next(STEP)!!;
	defer packet.release();
	assert(packet.value.kind == input::EventKind.LAYOUTS_CHANGED, "the layout list changed");
	// Woken by the event, a subscriber must already find the state it announces.
	Snapshot{input::State}* latest = svc.latest()!!;
	defer latest.release();
	assert(latest.value.layouts.len == 2, "latest() shows the state of the event");
}

fn void switch_queued_when_the_backend_stops_is_cancelled() @test
{
	input::Input svc;
	open_with(&svc, &waits_without_taking);
	publish_layouts(&svc.hub, "us", 2);
	input::SwitchOperation* operation = svc.next()!!;
	defer operation.release();
	// The request is queued and never taken: stopping must hand it to abandon.
	svc.hub.stop();
	if (catch err = operation.wait(STEP))
	{
		assert(err == error::CANCELLED, "the abandoned switch fails with CANCELLED");
		return;
	}
	unreachable("a switch queued at shutdown must not succeed");
}
