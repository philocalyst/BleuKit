<*
 The calculation behind `theme.auto`: when the shell should be in its light theme, and when that
 changes next. Pure: the clock and the local time zone are arguments (`now` is passed in, and
 the offset comes from the OS through `std::time`), so every rule is unit-tested.

 Sources, DMS master 8be08999:
 * `core/internal/server/thememode/manager.go:361-443` (`computeSchedule`,
   `computeTimeSchedule`, `computeLocationSchedule`, `startOfNextDay`).
 * `core/internal/server/wayland/suncalc.go:1-150` (`CalculateSunTimesWithTwilight`, the
   solar equations and the horizon thresholds). DMS's sun model is its own; bleu_color's
   NOAA model is a different one (it uses a fixed horizon), so it is not used here.

 Times are Unix microseconds (`long`). A "local day" is a count of days since 1970-01-01 in
 the local time zone.
*>
module dmsd::theme_auto_calc;
import std::math, std::time, std::time::datetime;

<* Microseconds in one second, minute, and day. *>
const long SEC_US = 1000000;
const long MINUTE_US = 60000000;
const long DAY_US = 86400000000;

<* Noon, in minutes of the day. *>
const long NOON_MINUTE = 720;

<* One degree in radians, and the reverse. Go's `degToRad` and `radToDeg` (suncalc.go:9-10). *>
const double DEG_TO_RAD = math::PI / 180.0;
const double RAD_TO_DEG = 180.0 / math::PI;

<* The zenith distance of the sun's centre at sunrise, in degrees (suncalc.go:85). *>
const double HORIZON_ZENITH = 90.833;

<* The calendar date of a local or UTC day. *>
struct CivilDate
{
	long year;
	long month;
	long day;
}

<* A change of the theme: `light` from `at` (Unix microseconds) on. *>
struct Transition
{
	bool light;
	long at;
}

<* Sun times of one day, as Unix microseconds (suncalc.go:21-26). Zero when the sun does not rise or set. *>
struct SunTimes
{
	long dawn;
	long sunrise;
	long sunset;
	long night;
}

<* Whether the sun rises and sets on a day (suncalc.go:15-19). *>
enum SunCondition : char
{
	NORMAL,
	MIDNIGHT_SUN,
	POLAR_NIGHT,
}

<* A day's sun times and the condition they hold under. *>
struct SunDay
{
	SunCondition condition;
	SunTimes times;
}

<* The sun is above, or below, the threshold all day (suncalc.go:57-63). *>
enum Threshold : char
{
	CROSSES,
	ALWAYS_ABOVE,
	ALWAYS_BELOW,
}

<* The current time, in Unix microseconds (the wall clock). *>
fn long now_us() => (long)time::now();

<*
 The UTC offset of the local zone at `unix_us`, in microseconds. Read from the OS through
 `std::time`, so it follows the zone rules in effect at that instant.
*>
fn long offset_us(long unix_us)
{
	TzDateTime local = datetime::from_time((Time)unix_us).to_local();
	return (long)local.gmt_offset * SEC_US;
}

<* Floor division for a positive divisor, so that negative instants fall on the day before. *>
fn long floor_div(long value, long divisor) @inline
{
	return value >= 0 ? value / divisor : -((-value + divisor - 1) / divisor);
}

<* Days since 1970-01-01 of a proleptic Gregorian date (H. Hinnant, "chrono-compatible" algorithm). *>
fn long days_from_civil(CivilDate date)
{
	long y   = date.month <= 2 ? date.year - 1 : date.year;
	long era = floor_div(y, 400);
	long yoe = y - era * 400;
	long mp  = date.month > 2 ? date.month - 3 : date.month + 9;
	long doy = (153 * mp + 2) / 5 + date.day - 1;
	long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
	return era * 146097 + doe - 719468;
}

<* The date of `days` since 1970-01-01 (the inverse of `days_from_civil`). *>
fn CivilDate civil_from_days(long days)
{
	long z   = days + 719468;
	long era = floor_div(z, 146097);
	long doe = z - era * 146097;
	long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
	long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
	long mp  = (5 * doy + 2) / 153;
	long d   = doy - (153 * mp + 2) / 5 + 1;
	long m   = mp < 10 ? mp + 3 : mp - 9;
	long y   = yoe + era * 400;
	return { .year = m <= 2 ? y + 1 : y, .month = m, .day = d };
}

<* Whether `year` is a leap year in the Gregorian calendar (suncalc.go:28-33). *>
fn bool is_leap(long year) @inline
{
	return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
}

<* The local day, as days since 1970-01-01, that holds `unix_us` in the local zone. *>
fn long local_day_of(long unix_us)
{
	return floor_div(unix_us + offset_us(unix_us), DAY_US);
}

<* The minute of the local day (0..1439) at `unix_us`. *>
fn long local_minute_of(long unix_us)
{
	long wall = unix_us + offset_us(unix_us);
	return (wall - floor_div(wall, DAY_US) * DAY_US) / MINUTE_US;
}

<*
 The instant of a local wall-clock time: `minute` minutes after midnight of local day `day`
 (days since 1970-01-01). The offset is taken at the instant itself, so a day with a
 transition is read correctly except inside the skipped hour of a spring-forward gap.
*>
fn long local_instant(long day, long minute)
{
	long wall   = day * DAY_US + minute * MINUTE_US;
	long offset = offset_us(wall);
	long at     = wall - offset;
	long again  = offset_us(at);
	return again == offset ? at : wall - again;
}

<*
 The start of the local day after the one holding `unix_us` (`startOfNextDay`, thememode/manager.go:444).
*>
fn long start_of_next_day(long unix_us)
{
	return local_instant(local_day_of(unix_us) + 1, 0);
}

<*
 Time mode (computeTimeSchedule, thememode/manager.go:370-403). `current`, `start` and `end` are
 minutes of the local day. The result is the next change: `light` from the start of the local
 day `days` after today at `minute`, which the caller turns into an instant.
*>
struct TimeChange
{
	bool light;
	long days;
	long minute;
}

<* The next time-mode change from the local minute `current`. *>
fn TimeChange time_change(long current, long start, long end)
{
	if (start == end)
	{
		// Equal times: light all the time, changing at the next start (DMS adds a day when the start has passed).
		return { .light = true, .days = start > current ? 0 : 1, .minute = start };
	}
	if (start < end)
	{
		if (current < start) return { .light = true, .days = 0, .minute = start };
		if (current >= end) return { .light = true, .days = 1, .minute = start };
		return { .light = false, .days = 0, .minute = end };
	}
	if (current >= start) return { .light = false, .days = 1, .minute = end };
	if (current < end) return { .light = false, .days = 0, .minute = end };
	return { .light = true, .days = 0, .minute = start };
}

<*
 The solar hour angle of a threshold elevation (sunHourAngle, suncalc.go:65-77).

 @param latitude : "Radians"
 @param declination : "Radians"
 @param target : "The sun's zenith distance at the threshold, radians"
*>
fn double hour_angle(double latitude, double declination, double target, Threshold* state)
{
	double cos_hour = math::cos(target) / (math::cos(latitude) * math::cos(declination)) - math::tan(latitude) * math::tan(declination);
	if (cos_hour < -1.0)
	{
		*state = ALWAYS_ABOVE;
		return math::PI;
	}
	if (cos_hour > 1.0)
	{
		*state = ALWAYS_BELOW;
		return 0.0;
	}
	*state = CROSSES;
	return math::acos(cos_hour);
}

<* Seconds after midnight UTC of a sun event at hour angle `hour`, with equation of time `eqtime` (suncalc.go:79-81). *>
fn double hour_angle_seconds(double hour, double eqtime) @inline
{
	return RAD_TO_DEG * (4.0 * math::PI - 4 * hour - eqtime) * 60;
}

<* Days in a year, 365 or 366 (suncalc.go:28-33). *>
fn long days_in_year(long year) @inline => is_leap(year) ? 366 : 365;

<* The orbit angle of the reference day (suncalc.go:35-37). `day_of_year` is 1-based. *>
fn double orbit_angle(long year, long day_of_year) @inline
{
	return 2 * math::PI / (double)days_in_year(year) * (double)(day_of_year - 1);
}

<* The equation of time, in minutes (suncalc.go:39-45). *>
fn double equation_of_time(double angle) @inline
{
	return 4 * (0.000075 + 0.001868 * math::cos(angle) - 0.032077 * math::sin(angle)
		- 0.014615 * math::cos(2 * angle) - 0.040849 * math::sin(2 * angle));
}

<* The sun's declination, in radians (suncalc.go:47-55). *>
fn double sun_declination(double angle) @inline
{
	return 0.006918 - 0.399912 * math::cos(angle) + 0.070257 * math::sin(angle) - 0.006758 * math::cos(2 * angle)
		+ 0.000907 * math::sin(2 * angle) - 0.002697 * math::cos(3 * angle) + 0.00148 * math::sin(3 * angle);
}

<*
 Sun times of the local day that contains `unix_us`, at `latitude` and `longitude` (degrees),
 for the elevation thresholds of twilight and daylight (degrees). This is
 `CalculateSunTimesWithTwilight` (suncalc.go:83-136).

 Go converts the longitude offset with `time.Duration(-lon*4) * time.Minute`, which truncates
 the minutes toward zero, and each event with `time.Duration(secs) * time.Second`, which
 truncates the seconds. Both truncations are kept.
*>
fn SunDay sun_times(double latitude, double longitude, double elevation_twilight, double elevation_daylight, long unix_us)
{
	double lat_rad          = latitude * DEG_TO_RAD;
	double twilight_rad     = (HORIZON_ZENITH - elevation_twilight) * DEG_TO_RAD;
	double daylight_rad     = (HORIZON_ZENITH - elevation_daylight) * DEG_TO_RAD;
	long lon_offset_minutes = (long)(-longitude * 4);
	long lon_offset         = lon_offset_minutes * MINUTE_US;
	// The solar day the caller's civil day falls in: local noon, moved by the longitude, read in UTC.
	long noon               = local_instant(local_day_of(unix_us), NOON_MINUTE);
	long reference_day      = floor_div(noon - lon_offset, DAY_US);
	CivilDate date          = civil_from_days(reference_day);
	CivilDate january       = { .year = date.year, .month = 1, .day = 1 };
	long day_of_year        = reference_day - days_from_civil(january) + 1;
	double angle            = orbit_angle(date.year, day_of_year);
	double declination      = sun_declination(angle);
	double equation         = equation_of_time(angle);
	Threshold twilight_state;
	Threshold daylight_state;
	double twilight_hour    = hour_angle(lat_rad, declination, twilight_rad, &twilight_state);
	double daylight_hour    = hour_angle(lat_rad, declination, daylight_rad, &daylight_state);
	if (daylight_state == ALWAYS_ABOVE) return { .condition = MIDNIGHT_SUN };
	if (twilight_state == ALWAYS_BELOW) return { .condition = POLAR_NIGHT };
	long day_start = reference_day * DAY_US;
	long dawn_secs      = (long)hour_angle_seconds(math::abs(twilight_hour), equation);
	long sunrise_secs   = (long)hour_angle_seconds(math::abs(daylight_hour), equation);
	long sunset_secs    = (long)hour_angle_seconds(-math::abs(daylight_hour), equation);
	long night_secs     = (long)hour_angle_seconds(-math::abs(twilight_hour), equation);
	return {
		.condition = NORMAL,
		.times = {
			.dawn = day_start + dawn_secs * SEC_US + lon_offset,
			.sunrise = day_start + sunrise_secs * SEC_US + lon_offset,
			.sunset = day_start + sunset_secs * SEC_US + lon_offset,
			.night = day_start + night_secs * SEC_US + lon_offset,
		},
	};
}

<*
 Location mode (computeLocationSchedule, thememode/manager.go:405-442): the next change of the
 theme at a place, from the sun times of today and, after sunset, of tomorrow.

 @param now : "Unix microseconds"
*>
fn Transition location_change(double latitude, double longitude, double elevation_twilight, double elevation_daylight, long now)
{
	SunDay today = sun_times(latitude, longitude, elevation_twilight, elevation_daylight, now);
	if (today.condition == MIDNIGHT_SUN) return { .light = true, .at = start_of_next_day(now) };
	if (today.condition == POLAR_NIGHT) return { .light = false, .at = start_of_next_day(now) };
	if (now < today.times.sunrise) return { .light = false, .at = today.times.sunrise };
	if (now < today.times.sunset) return { .light = true, .at = today.times.sunset };
	long tomorrow_start = start_of_next_day(now);
	SunDay tomorrow     = sun_times(latitude, longitude, elevation_twilight, elevation_daylight, tomorrow_start);
	if (tomorrow.condition == MIDNIGHT_SUN) return { .light = true, .at = start_of_next_day(tomorrow_start) };
	if (tomorrow.condition == POLAR_NIGHT) return { .light = false, .at = start_of_next_day(tomorrow_start) };
	return { .light = false, .at = tomorrow.times.sunrise };
}
