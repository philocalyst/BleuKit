module bleu::color::schedule_test;
import bleu::color, bleu::color::schedule, bleu::error, bleu::unit, std::time, std::math;

// Instants, in Unix microseconds, at 00:00 UTC on the days the references are for.
const long MAR_20_2026 = 1773964800000000;
const long MAR_19_2026 = 1773878400000000;
const long JUN_21_2026 = 1782000000000000;
const long DEC_21_2026 = 1797811200000000;
const long SECOND      = 1000000;
const long MINUTE      = 60 * SECOND;

// A time of day in microseconds from midnight.
fn long hms(long h, long m, long s) => (h * 3600 + m * 60 + s) * SECOND;

fn bool within(long value, long expected, long tolerance) => math::abs(value - expected) <= tolerance;

// Published sunrise and sunset from sunrise-sunset.org (2026-03-20, UTC), checked against the
// NOAA equations here. Astral 3.2 (an independent Python implementation) agrees within about a
// minute; the published service runs about 1.5 minutes longer per event. Both are tolerances.
fn void london_matches_the_published_equinox() @test
{
	DayEvents e = schedule::day_events(51.5074, -0.1278, MAR_20_2026);
	assert(e.crosses, "London has a sunrise on the equinox");
	assert(within(e.sunrise - MAR_20_2026, hms(6, 1, 6), 3 * MINUTE), "sunrise within 3 min of 06:01:06");
	assert(within(e.sunset - MAR_20_2026, hms(18, 14, 49), 3 * MINUTE), "sunset within 3 min of 18:14:49");
	assert(within(e.sunrise - MAR_20_2026, hms(6, 3, 39), 90 * SECOND), "sunrise within 90 s of astral 06:03:39");
	assert(within(e.sunset - MAR_20_2026, hms(18, 13, 14), 90 * SECOND), "sunset within 90 s of astral 18:13:14");
}

fn void new_york_matches_the_published_equinox() @test
{
	DayEvents e = schedule::day_events(40.7128, -74.0060, MAR_20_2026);
	assert(within(e.sunrise - MAR_20_2026, hms(10, 57, 28), 3 * MINUTE), "sunrise within 3 min of 10:57:28");
	assert(within(e.sunset - MAR_20_2026, hms(23, 9, 21), 3 * MINUTE), "sunset within 3 min of 23:09:21");
	assert(within(e.sunrise - MAR_20_2026, hms(10, 59, 30), 90 * SECOND), "sunrise within 90 s of astral 10:59:30");
	assert(within(e.sunset - MAR_20_2026, hms(23, 7, 57), 90 * SECOND), "sunset within 90 s of astral 23:07:57");
}

// Sydney is east of Greenwich: the sunrise nearest solar noon on the UTC day of 20 March falls
// at 19:58 UTC on 19 March, which is 19:56:52 UTC in the published record. The comparison is on
// absolute instants because that sunrise lies before the day's start.
fn void sydney_matches_the_published_equinox() @test
{
	DayEvents e = schedule::day_events(-33.8688, 151.2093, MAR_20_2026);
	assert(e.crosses, "Sydney has a sunrise on the equinox");
	assert(within(
		e.sunrise,
		MAR_19_2026 + hms(19, 56, 52),
		3 * MINUTE
	), "sunrise within 3 min of 19:56:52 UTC on 19 March");
	assert(within(
		e.sunset,
		MAR_20_2026 + hms(8, 8, 36),
		3 * MINUTE
	), "sunset within 3 min of 08:08:36 UTC on 20 March");
}

fn void transition_is_centred_on_each_edge() @test
{
	Schedule s = {
		.mode = Mode.TIMES,
		.sunrise = (Duration)hms(6, 0, 0),
		.sunset = (Duration)hms(18, 0, 0),
		.day = (Kelvin)6500,
		.night = (Kelvin)4500,
		.transition = (Duration)(30 * MINUTE),
	};
	assert((int)schedule::temperature_at(
		s,
		(Time)(MAR_20_2026 + hms(5, 0, 0)),
		(Duration)0
	) == 4500, "night before the transition");
	assert((int)schedule::temperature_at(
		s,
		(Time)(MAR_20_2026 + hms(5, 50, 0)),
		(Duration)0
	) == 4648, "smoothstep 1/6 into the transition");
	assert((int)schedule::temperature_at(
		s,
		(Time)(MAR_20_2026 + hms(6, 0, 0)),
		(Duration)0
	) == 5500, "midway at sunrise");
	assert((int)schedule::temperature_at(
		s,
		(Time)(MAR_20_2026 + hms(6, 20, 0)),
		(Duration)0
	) == 6500, "day after the transition");
	assert((int)schedule::temperature_at(
		s,
		(Time)(MAR_20_2026 + hms(18, 0, 0)),
		(Duration)0
	) == 5500, "midway at sunset");
	assert((int)schedule::temperature_at(
		s,
		(Time)(MAR_20_2026 + hms(19, 0, 0)),
		(Duration)0
	) == 4500, "night after sunset");
}

fn void local_times_use_the_offset() @test
{
	// 06:00 local at UTC+1 is 05:00 UTC.
	Schedule s = {
		.mode = Mode.TIMES,
		.sunrise = (Duration)hms(6, 0, 0),
		.sunset = (Duration)hms(18, 0, 0),
		.day = (Kelvin)6500,
		.night = (Kelvin)4500,
		.transition = (Duration)(30 * MINUTE),
	};
	Duration plus_one = (Duration)(3600 * SECOND);
	assert((int)schedule::temperature_at(
		s,
		(Time)(MAR_20_2026 + hms(4, 0, 0)),
		plus_one
	) == 4500, "05:00 local is still night");
	assert((int)schedule::temperature_at(
		s,
		(Time)(MAR_20_2026 + hms(5, 0, 0)),
		plus_one
	) == 5500, "06:00 local is midway");
}

fn void sun_schedule_is_day_by_day_and_night_by_night() @test
{
	Schedule s = {
		.mode = Mode.SCHEDULE,
		.latitude = 51.5074,
		.longitude = -0.1278,
		.day = (Kelvin)6500,
		.night = (Kelvin)4500,
		.transition = (Duration)(30 * MINUTE),
	};
	assert((int)schedule::temperature_at(
		s,
		(Time)(MAR_20_2026 + hms(12, 0, 0)),
		(Duration)0
	) == 6500, "noon in London is day");
	assert((int)schedule::temperature_at(
		s,
		(Time)(MAR_20_2026 + hms(23, 0, 0)),
		(Duration)0
	) == 4500, "23:00 UTC in London is night");
}

fn void polar_day_and_night_follow_the_sun() @test
{
	// 80 N: the sun never sets on 21 June and never rises on 21 December.
	DayEvents june = schedule::day_events(80.0, 0.0, JUN_21_2026);
	assert(!june.crosses, "no sunrise or sunset on midsummer at 80 N");
	Schedule s = {
		.mode = Mode.SCHEDULE,
		.latitude = 80.0,
		.longitude = 0.0,
		.day = (Kelvin)6500,
		.night = (Kelvin)4500,
		.transition = (Duration)(30 * MINUTE),
	};
	assert((int)schedule::temperature_at(
		s,
		(Time)(JUN_21_2026 + hms(12, 0, 0)),
		(Duration)0
	) == 6500, "midsummer at 80 N is day");
	assert((int)schedule::temperature_at(
		s,
		(Time)(DEC_21_2026 + hms(12, 0, 0)),
		(Duration)0
	) == 4500, "midwinter at 80 N is night");
}

fn void validation_refuses_out_of_range_values() @test
{
	schedule::validate({ .mode = Mode.MANUAL, .latitude = 91.0 })!!;
	Schedule bad_latitude = {
		.mode = Mode.SCHEDULE,
		.latitude = 91.0,
		.longitude = 0.0,
		.transition = (Duration)(30 * MINUTE)
	};
	assert(@catch(schedule::validate(bad_latitude)) == error::INVALID_ARGUMENT, "latitude above 90 is refused");
	Schedule long_transition = {
		.mode = Mode.TIMES,
		.sunrise = (Duration)hms(6, 0, 0),
		.sunset = (Duration)hms(18, 0, 0),
		.transition = (Duration)(2 * 3600 * SECOND)
	};
	assert(@catch(
		schedule::validate(long_transition)
	) == error::INVALID_ARGUMENT, "a transition over one hour is refused");
	Schedule past_midnight = {
		.mode = Mode.TIMES,
		.sunrise = (Duration)(24 * 3600 * SECOND),
		.sunset = (Duration)hms(18, 0, 0),
		.transition = (Duration)(30 * MINUTE)
	};
	assert(@catch(schedule::validate(past_midnight)) == error::INVALID_ARGUMENT, "a time of day of 24 h is refused");
	Schedule good = {
		.mode = Mode.SCHEDULE,
		.latitude = 51.5,
		.longitude = -0.1,
		.day = color::DEFAULT_DAY,
		.night = color::DEFAULT_NIGHT,
		.transition = (Duration)(30 * MINUTE)
	};
	schedule::validate(good)!!;
	// A zero temperature would publish 0 K; a temperature outside the kelvin range is not a schedule.
	Schedule no_day = good;
	no_day.day = (Kelvin)0;
	assert(@catch(schedule::validate(no_day)) == error::INVALID_ARGUMENT, "a zero day temperature is refused");
	Schedule hot_night = good;
	hot_night.night = (Kelvin)30000;
	assert(@catch(schedule::validate(hot_night)) == error::INVALID_ARGUMENT, "a night above 25000 K is refused");
	Schedule equal_times = {
		.mode = Mode.TIMES,
		.sunrise = (Duration)hms(6, 0, 0),
		.sunset = (Duration)hms(6, 0, 0),
		.day = color::DEFAULT_DAY,
		.night = color::DEFAULT_NIGHT,
		.transition = (Duration)(30 * MINUTE)
	};
	assert(@catch(schedule::validate(equal_times)) == error::INVALID_ARGUMENT, "equal sunrise and sunset are refused");
}

const long DAY_SECONDS = 86400;

// Sunrise at 06:00 and sunset at 06:20 with a one-hour transition: the two windows overlap. The daylight
// curve must still move continuously. Sampled every second over a day, no step may exceed what the two
// windows allow: a smoothstep rises at most 1.5 times its inverse width per second, and two overlap here.
fn void overlapping_edges_stay_continuous() @test
{
	Schedule overlap = {
		.mode = Mode.TIMES,
		.sunrise = (Duration)hms(6, 0, 0),
		.sunset = (Duration)hms(6, 20, 0),
		.day = color::DEFAULT_DAY,
		.night = color::DEFAULT_NIGHT,
		.transition = (Duration)(3600 * SECOND),
	};
	float previous = schedule::daylight_at(overlap, MAR_20_2026, 0);
	float largest  = 0.0f;
	for (long second = 1; second <= DAY_SECONDS; second++)
	{
		float current = schedule::daylight_at(overlap, MAR_20_2026 + second * SECOND, 0);
		float step    = math::abs(current - previous);
		if (step > largest) largest = step;
		previous = current;
	}
	float bound = 2.0f * 1.5f / 3600.0f + 0.0001f;
	assert(largest <= bound, "no second-to-second step is larger than the two windows allow");
	assert(schedule::daylight_at(
		overlap,
		MAR_20_2026 + hms(6, 10, 0),
		0
	) > 0.0f, "the day is light inside the overlap");
	assert(schedule::daylight_at(
		overlap,
		MAR_20_2026 + hms(12, 0, 0),
		0
	) == 0.0f, "the day is over after both windows");
}