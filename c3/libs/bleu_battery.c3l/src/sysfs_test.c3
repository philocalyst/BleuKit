module bleu::battery::sysfs_test;
import std::time, bleu::battery, bleu::battery::sysfs;

fn void kernel_spellings_map_to_enums() @test
{
	assert(sysfs::kind_from_type("Mains") == MAINS);
	assert(sysfs::kind_from_type("Battery") == BATTERY);
	assert(sysfs::kind_from_type("Gizmo") == UNKNOWN);
	assert(sysfs::state_from_status("Not charging") == NOT_CHARGING);
	assert(sysfs::chemistry_from_technology("Li-poly") == LITHIUM_POLYMER);
	assert(sysfs::kind_from_type("USB_PD_DRP") == MAINS, "a dual-role USB-C port is a charger");
}

fn void power_now_takes_its_direction_from_the_status() @test
{
	// power_now is a magnitude in µW: 16 650 000 µW is 16 650 mW, out while discharging, in otherwise.
	assert((long)sysfs::flow_from_power(16_650_000, DISCHARGING) == -16_650);
	assert((long)sysfs::flow_from_power(16_650_000, CHARGING) == 16_650);
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

// current_now is signed by the kernel: a negative reading is a discharge whatever the status says.
fn void current_now_keeps_its_sign_whatever_the_status() @test
{
	assert((long)sysfs::power_from_current(-1_500_000, 11_100_000) == -16_650, "discharging, with status Unknown");
	assert((long)sysfs::power_from_current(1_500_000, 11_100_000) == 16_650);
}
