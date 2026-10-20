module dmsd::gamma_settings;
import bleu::color, bleu::error, bleu::unit, std::core::test;

// DMS's "15:04" clock values: one or two hour digits, two minute digits, and the ranges of a day.
fn void clock_values_parse_as_go_does() @test
{
	test::eq(parse_clock("06:30") ?? -1L, 390L);
	test::eq(parse_clock("6:05") ?? -1L, 365L);
	test::eq(parse_clock("23:59") ?? -1L, 1439L);
	test::@error(parse_clock("24:00"), error::INVALID_ARGUMENT);
	test::@error(parse_clock("12:60"), error::INVALID_ARGUMENT);
	test::@error(parse_clock("1230"), error::INVALID_ARGUMENT);
	test::@error(parse_clock("12:3x"), error::INVALID_ARGUMENT);
	test::@error(parse_clock(""), error::INVALID_ARGUMENT);
}

// The manual sunrise is centred on its ramp: DMS ramps from sunrise minus the duration to sunrise,
// bleu_color's change is centred on the edge, so the edge sits half a duration earlier.
fn void manual_times_centre_their_ramps() @test
{
	GammaSettings s = default_settings();
	s.has_manual = true;
	s.sunrise_minute = 390;
	s.sunset_minute = 1080;
	s.has_duration = true;
	s.duration_minutes = 30;
	color::Schedule times = times_schedule(s);
	test::eq(times.mode, color::Mode.TIMES);
	test::eq((long)times.sunrise, 375 * 60000000L);
	test::eq((long)times.sunset, 1095 * 60000000L);
	test::eq((long)times.transition, 30 * 60000000L);
	test::eq(times.day, (unit::Kelvin)6500);
	test::eq(times.night, (unit::Kelvin)4500);
}

// A sunrise at 00:10 with a one hour ramp: its edge is centred half an hour before, at 23:40 of the day before.
fn void manual_times_wrap_past_midnight() @test
{
	GammaSettings s = default_settings();
	s.has_manual = true;
	s.sunrise_minute = 10;
	s.sunset_minute = 1080;
	s.has_duration = true;
	s.duration_minutes = 60;
	color::Schedule times = times_schedule(s);
	test::eq((long)times.sunrise, 1420 * 60000000L);
}

// Without a duration, DMS uses one hour (manager.go:132).
fn void manual_times_default_to_an_hour() @test
{
	GammaSettings s = default_settings();
	s.has_manual = true;
	s.sunrise_minute = 390;
	s.sunset_minute = 1080;
	color::Schedule times = times_schedule(s);
	test::eq((long)times.transition, 60 * 60000000L);
}

// DMS's precedence: disabled is the identity, equal temperatures are a constant, manual times beat a location.
fn void plans_follow_dms_precedence() @test
{
	GammaSettings s = default_settings();
	test::eq(plan_of(s), Plan.RESET);
	s.enabled = true;
	test::eq(plan_of(s), Plan.RESET);
	s.has_location = true;
	s.latitude = 52.52;
	s.longitude = 13.405;
	test::eq(plan_of(s), Plan.SUN);
	s.has_manual = true;
	test::eq(plan_of(s), Plan.TIMES);
	s.low_temp = s.high_temp;
	test::eq(plan_of(s), Plan.CONSTANT);
	s.enabled = false;
	test::eq(plan_of(s), Plan.RESET);
}