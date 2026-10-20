module bleu::battery::common_test;
import std::collections::list, std::collections::maybe, std::math, std::time, bleu::availability, bleu::battery, bleu::unit;

fn void charge_state_follows_mains_and_flags() @test
{
	assert(battery::charge_state(false, false, false, false) == DISCHARGING);
	assert(battery::charge_state(false, false, false, true) == EMPTY);
	assert(battery::charge_state(true, true, false, false) == CHARGING);
	assert(battery::charge_state(true, false, true, false) == FULL);
	// Plugged in, not charging, not full: a charge limit or heat holds it.
	assert(battery::charge_state(true, false, false, false) == NOT_CHARGING);
}

fn void health_needs_a_design_capacity() @test
{
	assert(!battery::health_from((MilliWattHour)40_000, (MilliWattHour)0).has_value);
	Maybe{Level} health = battery::health_from((MilliWattHour)40_000, (MilliWattHour)50_000);
	assert(health.has_value && math::abs((float)health.value - 0.8f) < 0.0001f);
}

fn void time_at_rate_is_energy_over_flow() @test
{
	// 30 Wh at 15 W is two hours, whichever way the flow points.
	assert(battery::time_at_rate((MilliWattHour)30_000, (MilliWatt)-15_000).value == (Duration)7_200_000_000);
	assert(battery::time_at_rate((MilliWattHour)30_000, (MilliWatt)15_000).value == (Duration)7_200_000_000);
	assert(!battery::time_at_rate((MilliWattHour)30_000, (MilliWatt)0).has_value);
}

// One line per transition: the line came online, the battery became full, and a headset appeared.
fn void changes_name_each_transition_once() @test
{
	Source[2] old_sources = {
		{ .id = "AC", .kind = MAINS, .present = false },
		{ .id = "BAT0", .kind = BATTERY, .state = CHARGING },
	};
	State before = { .sources = old_sources[..] };
	Source[3] new_sources = {
		{ .id = "AC", .kind = MAINS, .present = true },
		{ .id = "BAT0", .kind = BATTERY, .state = FULL },
		{ .id = "HEADSET", .kind = PERIPHERAL, .present = true },
	};
	State after = { .on_mains = true, .sources = new_sources[..] };
	List{Event} events;
	events.init(mem);
	defer events.free();
	battery::changes(&before, &after, &events);
	Event[] out = events.array_view();
	assert(out.len == 3, "three transitions");
	assert(out[0].kind == MAINS_CHANGED && out[0].source_id == "", "the mains line");
	assert(out[1].kind == STATE_CHANGED && out[1].source_id == "BAT0", "the battery's state");
	assert(out[2].kind == SOURCE_ADDED && out[2].source_id == "HEADSET", "the headset appeared");
}

fn void an_unchanged_reading_has_no_transients() @test
{
	Source[1] sources = { { .id = "BAT0", .kind = BATTERY, .state = DISCHARGING } };
	State state       = { .sources = sources[..] };
	List{Event} events;
	events.init(mem);
	defer events.free();
	battery::changes(&state, &state, &events);
	assert(events.array_view().len == 0);
}

fn void a_removed_source_is_reported() @test
{
	Source[1] old_sources = { { .id = "BAT0", .kind = BATTERY } };
	State before          = { .sources = old_sources[..] };
	State after           = { };
	List{Event} events;
	events.init(mem);
	defer events.free();
	battery::changes(&before, &after, &events);
	Event[] out = events.array_view();
	assert(out.len == 1 && out[0].kind == SOURCE_REMOVED && out[0].source_id == "BAT0");
}

fn void a_copy_survives_the_source_it_came_from() @test
{
	@pool()
	{
		Source[1] sources = { { .id = "BAT0", .kind = BATTERY, .model = "Cell9" } };
		State from        = { .on_mains = true, .sources = sources[..], .reading = availability::YES };
		State copy        = battery::copy_state(&from, tmem);
		assert(copy.on_mains && copy.sources.len == 1);
		assert(copy.sources.ptr != from.sources.ptr, "the sources are copied, not shared");
		assert(copy.sources[0].model == "Cell9" && copy.sources[0].id == "BAT0");
	};
}

fn void reading_states_say_what_they_mean() @test
{
	assert(battery::reading_after(0).ok() && battery::reading_after(0).reason == availability::Reason.AVAILABLE);
	assert(battery::reading_after(2)
		.ok() && battery::reading_after(2).reason == availability::Reason.DEGRADED, "a degraded reading is still OK");
	assert(!battery::stale_reading().ok(), "a stale reading is not OK");
	assert(battery::degraded("x").ok());
}