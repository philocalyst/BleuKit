module bleu::battery::win32_test;
import std::collections::maybe, std::time, bleu::battery, bleu::battery::win32, bleu::unit;

fn void summary_sentinels_are_unknown() @test
{
	assert(!win32::summary_percent(255).has_value, "255 is unknown");
	assert(!win32::summary_percent(101).has_value, "above 100 is not a percent");
	assert(win32::summary_percent(50).has_value && (float)win32::summary_percent(50).value == 0.5f);
	assert(!win32::summary_seconds(0xFFFFFFFF).has_value, "-1 is unknown");
	assert(win32::summary_seconds(3600).value == (Duration)3_600_000_000);
}

fn void summary_battery_presence() @test
{
	assert(!win32::summary_has_battery(128), "no system battery");
	assert(!win32::summary_has_battery(255), "unknown is not a battery");
	assert(win32::summary_has_battery(8), "charging is a battery");
	assert(win32::summary_has_battery(0), "between low and high is a battery");
	assert(win32::summary_on_mains(1) && !win32::summary_on_mains(255), "unknown line is offline");
}

fn void summary_state_from_flags_and_percent() @test
{
	assert(win32::summary_state(8, true, win32::summary_percent(40)) == CHARGING);
	assert(win32::summary_state(0, true, win32::summary_percent(100)) == FULL);
	assert(win32::summary_state(0, true, win32::summary_percent(60)) == NOT_CHARGING);
	assert(win32::summary_state(0, false, win32::summary_percent(0)) == EMPTY);
	assert(win32::summary_state(0, false, win32::summary_percent(50)) == DISCHARGING);
}

fn void device_state_from_power_state_bits() @test
{
	assert(win32::device_state(4, false, false) == CHARGING);
	assert(win32::device_state(2, false, false) == DISCHARGING);
	assert(win32::device_state(2, false, true) == EMPTY);
	assert(win32::device_state(1, true, false) == FULL);
	assert(win32::device_state(0, false, false) == UNKNOWN, "no bits set: not reported yet");
}

fn void device_units_and_sentinels() @test
{
	assert(win32::device_is_relative(0x40000000));
	assert(!win32::device_is_relative(0x80000000), "system battery bit only");
	assert(!win32::device_capacity(0xFFFFFFFF).has_value);
	assert(win32::device_capacity(40_000).value == (MilliWattHour)40_000);
	// Rate is signed: negative means discharging. The unknown marker is 0x80000000.
	assert(win32::device_rate(-16_000).value == (MilliWatt)-16_000);
	assert(!win32::device_rate((int)0x80000000).has_value);
}
