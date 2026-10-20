// The diff of two states into events: what a shell hears, for each kind of change.
module bleu::audio::changes_test;
import bleu::audio, bleu::unit;

// Collects the events of one diff.
struct Collector
{
	Event[8] events;
	sz count;
}

fn void collect(void* context, Event event)
{
	Collector* c = (Collector*)context;
	c.events[c.count] = event;
	c.count++;
}

fn void identical_states_report_nothing() @test
{
	State state;
	Collector c;
	audio::report_changes(&state, &state, &c, &collect);
	assert(c.count == 0);
}

fn void added_and_removed_devices_are_reported() @test
{
	Device[1] before = { { .id = "a", .name = "A" } };
	Device[1] after = { { .id = "b", .name = "B" } };
	State old = { .outputs = before[..] };
	State now = { .outputs = after[..] };
	Collector c;
	audio::report_changes(&old, &now, &c, &collect);
	assert(c.count == 2);
	assert(c.events[0].kind == DEVICE_ADDED && c.events[0].id == "b" && c.events[0].flow == OUTPUT);
	assert(c.events[1].kind == DEVICE_REMOVED && c.events[1].id == "a");
}

fn void changed_volume_defaults_and_microphone_are_reported() @test
{
	Gain[1] loud = { (Gain)1.0f };
	Gain[1] quiet = { (Gain)0.5f };
	Device[1] before = { { .id = "a", .volume = loud[..] } };
	Device[1] after = { { .id = "a", .volume = quiet[..] } };
	State old = { .outputs = before[..], .default_output = "a" };
	State now = { .outputs = after[..], .default_output = "b", .mic_in_use = true };
	Collector c;
	audio::report_changes(&old, &now, &c, &collect);
	assert(c.count == 3);
	assert(c.events[0].kind == DEVICE_CHANGED && c.events[0].id == "a");
	assert(c.events[1].kind == DEFAULT_CHANGED && c.events[1].id == "b" && c.events[1].flow == OUTPUT);
	assert(c.events[2].kind == MIC_IN_USE_CHANGED && c.events[2].flow == INPUT);
}
