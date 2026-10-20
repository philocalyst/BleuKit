module bleu::battery::sysfs_test;
import std::time, bleu::battery, bleu::battery::sysfs;

fn void kernel_spellings_map_to_enums() @test
{
	assert(sysfs::kind_from_type("Mains") == MAINS);
	assert(sysfs::kind_from_type("Battery") == BATTERY);
	assert(sysfs::kind_from_type("Gizmo") == UNKNOWN);
	assert(sysfs::state_from_status("Not charging") == NOT_CHARGING);
	assert(sysfs::chemistry_from_technology("Li-poly") == LITHIUM_POLYMER);
}

fn void unit_conversions_are_exact() @test
{
	assert((long)sysfs::micro_to_milli(52_000_000) == 52_000);
	// 2 000 000 µAh at 11 100 000 µV = 22.2 Wh = 22 200 mWh
	assert((long)sysfs::energy_from_charge(2_000_000, 11_100_000) == 22_200);
	// 1 500 000 µA at 11 100 000 µV = 16.65 W
	assert((long)sysfs::power_from_current(1_500_000, 11_100_000) == 16_650);
	assert((float)sysfs::celsius_from_tenths(312) == 31.2f);
	// 30 Wh at 15 W is two hours
	assert(sysfs::hours_at(30_000, 15_000) == (Duration)7_200_000_000);
	assert(sysfs::hours_at(30_000, 0) == time::DURATION_ZERO);
}