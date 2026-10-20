// Unit tests of the DMS brightness arithmetic. Expected values are DMS's formulas
// (sysfs.go, ddc.go) evaluated by hand or with Go's integer rules; see the notes on each.
module dmsd::brightness_math_test;
import std::math, dmsd::brightness_math;

// A panel of 96000 steps at 48000: DMS shows 50 percent (ValueToPercent, linear).
fn void sysfs_percent_of_a_panel() @test
{
	assert(brightness_math::sysfs_percent(48000, 1, 96000) == 50);
	assert(brightness_math::sysfs_percent(96000, 1, 96000) == 100);
	assert(brightness_math::sysfs_percent(1, 1, 96000) == 1);
	assert(brightness_math::sysfs_percent(0, 1, 96000) == 1, "below the minimum is 1 percent, not 0");
}

// A keyboard LED has a minimum of 0, so 0 is 0 percent and 1 of 3 is 34 percent (round(33) + 1).
fn void sysfs_percent_of_a_led() @test
{
	assert(brightness_math::sysfs_percent(0, 0, 3) == 0);
	assert(brightness_math::sysfs_percent(1, 0, 3) == 34);
	assert(brightness_math::sysfs_percent(3, 0, 3) == 100);
}

fn void ddc_percent_is_raw_over_max() @test
{
	assert(brightness_math::ddc_percent(50, 100) == 50);
	assert(brightness_math::ddc_percent(7, 0) == 0, "an unknown maximum reads as 0");
	assert(brightness_math::ddc_percent(255, 254) == 100, "capped at 100");
}

// Linear: 1 + ((50-1) * 95999) / 99 = 1 + 47514 = 47515 (integer division).
fn void sysfs_value_linear_matches_dms() @test
{
	assert(brightness_math::sysfs_value(50, 1, 96000, false, 1.2) == 47515);
	assert(brightness_math::sysfs_value(60, 1, 96000, false, 1.2) == 57212);
	assert(brightness_math::sysfs_value(40, 1, 96000, false, 1.2) == 37818);
	assert(brightness_math::sysfs_value(0, 1, 96000, false, 1.2) == 1, "zero percent is the minimum");
	assert(brightness_math::sysfs_value(100, 1, 96000, false, 1.2) == 96000);
}

// Exponential, exponent 2: round(((50-1)/99)^2 * 95999) + 1 = round(23517.9) + 1 = 23518 (with the minimum 1).
fn void sysfs_value_exponential_matches_dms() @test
{
	assert(brightness_math::sysfs_value(50, 1, 96000, true, 2.0) == 23518);
	assert(brightness_math::sysfs_value(100, 1, 96000, true, 1.2) == 96000);
}

// DDC/CI uses minimum 1 and its own exponent 2.0 whatever the request says (ddc.go percentToValue).
fn void ddc_value_matches_dms() @test
{
	assert(brightness_math::ddc_value(100, 100, false) == 100);
	assert(brightness_math::ddc_value(0, 100, false) == 1);
	assert(brightness_math::ddc_value(50, 100, false) == 1 + (49 * 99) / 99);
	assert(brightness_math::ddc_value(50, 100, true) == 1 + (long)math::round(math::pow(0.5, 0.5) * 99.0));
}

fn void suppressed_names_match_dms() @test
{
	assert(brightness_math::suppressed("input5::capslock"));
	assert(brightness_math::suppressed("platform::lan"));
	assert(!brightness_math::suppressed("intel_backlight"));
	assert(!brightness_math::suppressed("input5::kbd_backlight"));
}

fn void dms_class_order_matches_manager_go() @test
{
	assert(brightness_math::DmsClass.BACKLIGHT.rank() < brightness_math::DmsClass.DDC.rank());
	assert(brightness_math::DmsClass.DDC.rank() < brightness_math::DmsClass.LEDS.rank());
	assert(brightness_math::DmsClass.LEDS.wire_name() == "leds");
	assert(brightness_math::DmsClass.DDC.backend() == "ddc");
}

fn void clamp_percent_matches_increment() @test
{
	assert(brightness_math::clamp_percent(-5) == 0);
	assert(brightness_math::clamp_percent(105) == 100);
	assert(brightness_math::clamp_percent(42) == 42);
}
