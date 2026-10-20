module dmsd::theme_auto_calc;
import std::time, std::core::test;

// The civil calendar round-trips, and 1970-01-01 is day zero.
fn void calendar_round_trips() @test
{
	test::eq(days_from_civil({ .year = 1970, .month = 1, .day = 1 }), 0);
	CivilDate date = civil_from_days(20381);
	test::eq(date.year, 2025);
	test::eq(date.month, 10);
	test::eq(date.day, 20);
	test::eq(days_from_civil(date), 20381);
	CivilDate leap = civil_from_days(days_from_civil({ .year = 2024, .month = 2, .day = 29 }));
	test::eq(leap.day, 29);
	test::eq(is_leap(1900), false);
	test::eq(is_leap(2000), true);
}

// Time mode across midnight: start 18:00 (1080) and end 06:00 (360), as DMS's defaults.
fn void time_mode_across_midnight() @test
{
	TimeChange evening = time_change(1200, 1080, 360);
	test::eq(evening.light, false);
	test::eq(evening.days, 1);
	test::eq(evening.minute, 360);
	TimeChange early = time_change(300, 1080, 360);
	test::eq(early.light, false);
	test::eq(early.days, 0);
	test::eq(early.minute, 360);
	TimeChange midday = time_change(700, 1080, 360);
	test::eq(midday.light, true);
	test::eq(midday.days, 0);
	test::eq(midday.minute, 1080);
}

// Time mode within one day: start 09:00 (540) and end 17:00 (1020).
fn void time_mode_within_a_day() @test
{
	TimeChange before = time_change(600, 540, 1020);
	test::eq(before.light, false);
	test::eq(before.minute, 1020);
	TimeChange after = time_change(1100, 540, 1020);
	test::eq(after.light, true);
	test::eq(after.days, 1);
	test::eq(after.minute, 540);
	TimeChange early = time_change(100, 540, 1020);
	test::eq(early.light, true);
	test::eq(early.days, 0);
	test::eq(early.minute, 540);
}

// Equal start and end: DMS takes the next start, a day later once it has passed.
fn void time_mode_equal_times() @test
{
	TimeChange later = time_change(500, 600, 600);
	test::eq(later.light, true);
	test::eq(later.days, 0);
	test::eq(later.minute, 600);
	TimeChange passed = time_change(600, 600, 600);
	test::eq(passed.days, 1);
}

// Mid-latitude sun: sunrise comes before sunset, and both fall in the same local day.
fn void sun_rises_before_it_sets() @test
{
	long now   = local_instant(days_from_civil({ .year = 2026, .month = 10, .day = 19 }), 0);
	SunDay day = sun_times(52.52, 13.405, -6.0, 3.0, now);
	test::eq(day.condition, SunCondition.NORMAL);
	test::@check(day.times.dawn < day.times.sunrise, "dawn is before sunrise");
	test::@check(day.times.sunrise < day.times.sunset, "sunrise is before sunset");
	test::@check(day.times.sunset < day.times.night, "sunset is before night");
	long hours = (day.times.sunset - day.times.sunrise) / (3600 * SEC_US);
	test::@check(hours >= 8 && hours <= 12, "daylight in October at 52 N is between 8 and 12 hours");
}

// Midnight sun at 80 N in June, and polar night in December.
fn void polar_days() @test
{
	long june = local_instant(days_from_civil({ .year = 2026, .month = 6, .day = 21 }), 720);
	test::eq(sun_times(80.0, 0.0, -6.0, 3.0, june).condition, SunCondition.MIDNIGHT_SUN);
	long december = local_instant(days_from_civil({ .year = 2026, .month = 12, .day = 21 }), 720);
	test::eq(sun_times(80.0, 0.0, -6.0, 3.0, december).condition, SunCondition.POLAR_NIGHT);
}

// Location mode at night: the next change is today's sunrise, and in daylight it is today's sunset.
fn void location_change_follows_the_sun() @test
{
	long night             = local_instant(days_from_civil({ .year = 2026, .month = 10, .day = 20 }), 180);
	SunDay today           = sun_times(52.52, 13.405, -6.0, 3.0, night);
	Transition before_dawn = location_change(52.52, 13.405, -6.0, 3.0, night);
	test::eq(before_dawn.light, false);
	test::eq(before_dawn.at, today.times.sunrise);
	long noon         = local_instant(days_from_civil({ .year = 2026, .month = 10, .day = 20 }), 720);
	Transition midday = location_change(52.52, 13.405, -6.0, 3.0, noon);
	test::eq(midday.light, true);
	test::eq(midday.at, today.times.sunset);
}