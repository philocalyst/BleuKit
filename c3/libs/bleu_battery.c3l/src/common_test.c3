module bleu::battery::common_test;
import std::collections::maybe, std::math, std::time, bleu::battery, bleu::unit;

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