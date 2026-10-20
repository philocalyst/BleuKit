module bleu::battery::upower_test;
import std::time, bleu::battery, bleu::battery::upower, bleu::unit;

fn void enums_map_as_the_spec_says() @test
{
	assert(upower::device_kind(1) == MAINS && upower::device_kind(2) == BATTERY);
	assert(upower::device_kind(3) == UPS && upower::device_kind(5) == PERIPHERAL);
	assert(upower::device_kind(0) == UNKNOWN);
	assert(upower::device_state(1) == CHARGING && upower::device_state(2) == DISCHARGING);
	assert(upower::device_state(4) == FULL && upower::device_state(3) == EMPTY);
	assert(upower::device_state(5) == NOT_CHARGING && upower::device_state(6) == NOT_CHARGING);
	assert(upower::device_state(0) == UNKNOWN);
	assert(upower::technology(1) == LITHIUM_ION && upower::technology(3) == LITHIUM_IRON_PHOSPHATE);
	assert(upower::technology(9) == UNKNOWN);
}

fn void units_and_signs() @test
{
	// 50 Wh is 50 000 mWh.
	assert(upower::energy_from_wh(50.0) == (MilliWattHour)50_000);
	// EnergyRate is positive when discharging: 15 W out of the battery is -15 000 mW.
	assert(upower::power_from_rate(15.0) == (MilliWatt)-15_000);
	assert(upower::power_from_rate(-20.0) == (MilliWatt)20_000, "charging is positive");
}

fn void unknown_markers_are_empty() @test
{
	assert(!upower::duration_from_seconds(0).has_value, "0 is unknown for times");
	assert(upower::duration_from_seconds(60).value == (Duration)60_000_000);
	assert(!upower::cycles_from(-1).has_value, "-1 is unknown for cycles");
	assert(upower::cycles_from(0).value == 0, "zero cycles is a value");
	assert(!upower::charge_from_percentage(-1.0).has_value);
	assert((float)upower::charge_from_percentage(25.0).value == 0.25f);
}