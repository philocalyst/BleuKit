module bleu::battery::iokit_test;
import std::collections::maybe, std::math, std::time, bleu::battery, bleu::battery::iokit, bleu::unit;

fn void capacity_and_flow_units() @test
{
	// 5 000 mAh at 12 000 mV is 60 Wh.
	assert(iokit::energy_from_capacity(5000, 12000) == (MilliWattHour)60_000);
	// The Apple Silicon sample in starship-battery's tests: 12 818 mV at -1 037 mA.
	// 1 037 x 12 818 = 13 292 266 µW, so 13 292 mW, drawn from the battery.
	assert(iokit::flow_magnitude(-1037, 12818) == (MilliWatt)13_292);
	assert(iokit::flow_magnitude(1037, 12818) == (MilliWatt)13_292);
}

fn void amperage_keeps_its_sign() @test
{
	// A negative 32-bit value read as an unsigned 64-bit CFNumber: 2^32 - 1 037.
	assert(iokit::amperage_from_registry(4294966259) == -1037);
	assert(iokit::amperage_from_registry(1500) == 1500);
}

fn void time_estimates_are_seconds_or_nothing() @test
{
	Maybe{Duration} hour = iokit::estimate_from_seconds(3600.0);
	assert(hour.has_value && hour.value == (Duration)3_600_000_000);
	assert(!iokit::estimate_from_seconds(-1.0).has_value, "negative means no estimate");
	assert(!iokit::estimate_from_seconds(-2.0).has_value, "the second sentinel too");
	double not_a_number = bitcast((ulong)0x7FF8000000000000, double);
	assert(!iokit::estimate_from_seconds(not_a_number).has_value, "NaN means no estimate");
}
