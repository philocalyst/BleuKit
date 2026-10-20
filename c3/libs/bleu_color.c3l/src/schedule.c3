<*
 The schedule: when the temperature is day and when it is night, and what happens in between.

 Sunrise and sunset come from the NOAA general solar equations (NOAA Earth System Research
 Laboratory, "Solar Calculation Details", https://gml.noaa.gov/grad/solcalc/solareqns.PDF,
 read in full). The sun is taken to rise and set when its centre is 0.833 degrees below the
 horizon (refraction plus the solar radius, the zenith 90.833 of the same document). Accuracy is
 about a minute at mid latitudes, checked against published times in tests/schedule_test.c3.

 The temperature is a daylight fraction `w` in 0..1 times `day - night`, plus `night`. `w` is 1
 in daylight and 0 at night. Around each sunrise and sunset it changes over `transition`,
 centred on the event, along the smoothstep curve 3t^2 - 2t^3. Where the sun does not rise or
 set on any day near `now` (polar day or polar night), `w` is 1 when the sun is above the
 horizon at `now` and 0 when it is not.

 Everything here is pure: `now` and the local offset are arguments.
*>
module bleu::color::schedule;
import bleu::color, bleu::error, bleu::unit, std::math, std::time;

<* Microseconds in one day. Internal arithmetic is in plain microseconds, so `long` throughout. *>
const long DAY_US = 86400000000;

<* Microseconds in one hour: the longest transition the schedule accepts. *>
const long HOUR_US = 3600000000;

<* Julian day number of the Unix epoch, 1970-01-01 00:00 UTC. *>
const double UNIX_EPOCH_JD = 2440587.5;

<* Julian day of 2000-01-01 12:00 TT, the epoch of the NOAA polynomials. *>
const double J2000_JD = 2451545.0;

<* Refraction plus solar radius: the centre of the sun is this far below the horizon at sunrise and sunset. *>
const double SUNRISE_ZENITH = 90.833;

<* The sun's altitude that counts as sunrise and sunset in the polar fallback. *>
const double HORIZON_ALTITUDE = -0.833;

<* Degrees to radians. *>
const double DEG = math::PI / 180.0;

<* The position of the sun at one instant. *>
struct Sun
{
	double declination;      // radians
	double equation_minutes; // equation of time, minutes; apparent minus mean solar time
}

<* Sunrise and sunset on one UTC day. `crosses` is false when the sun does not rise or set that day. *>
struct DayEvents
{
	bool crosses;
	long sunrise;
	long sunset;
}

<* One change of the daylight state: a sunrise (rising) or a sunset (falling). *>
struct Edge
{
	long at;
	bool rising;
}

<*
 The NOAA general solar equations for the sun at Julian day `jd`.

 @param jd : "Julian day, UTC"
*>
fn Sun sun_at(double jd)
{
	double t = (jd - J2000_JD) / 36525.0;
	double mean_longitude = 280.46646 + t * (36000.76983 + t * 0.0003032);
	mean_longitude -= 360.0 * math::floor(mean_longitude / 360.0);
	double mean_anomaly = (357.52911 + t * (35999.05029 - 0.0001537 * t)) * DEG;
	double eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t);
	double centre = math::sin(mean_anomaly) * (1.914602 - t * (0.004817 + 0.000014 * t))
		+ math::sin(2 * mean_anomaly) * (0.019993 - 0.000101 * t)
		+ math::sin(3 * mean_anomaly) * 0.000289;
	double true_longitude = mean_longitude + centre;
	double omega = (125.04 - 1934.136 * t) * DEG;
	double apparent_longitude = (true_longitude - 0.00569 - 0.00478 * math::sin(omega)) * DEG;
	double seconds = 21.448 - t * (46.815 + t * (0.00059 - t * 0.001813));
	double obliquity = (23.0 + (26.0 + seconds / 60.0) / 60.0) + 0.00256 * math::cos(omega);
	double declination = math::asin(math::sin(obliquity * DEG) * math::sin(apparent_longitude));
	double y = math::pow(math::tan(obliquity * DEG / 2.0), 2.0);
	double l0 = mean_longitude * DEG;
	double equation = y * math::sin(2 * l0)
		- 2 * eccentricity * math::sin(mean_anomaly)
		+ 4 * eccentricity * y * math::sin(mean_anomaly) * math::cos(2 * l0)
		- 0.5 * y * y * math::sin(4 * l0)
		- 1.25 * eccentricity * eccentricity * math::sin(2 * mean_anomaly);
	return { .declination = declination, .equation_minutes = 4.0 * equation / DEG };
}

<* Julian day of a Unix time in microseconds. *>
fn double julian_day(long unix_us) => (double)unix_us / (double)DAY_US + UNIX_EPOCH_JD;

<* The first microsecond of the UTC day that contains `unix_us`. *>
fn long day_start(long unix_us) => unix_us - (((unix_us % DAY_US) + DAY_US) % DAY_US);

<*
 Sunrise and sunset of the UTC day that starts at `day_start_us`, at `longitude` and `latitude`:
 the rise and set on either side of that day's solar noon. East of Greenwich the sunrise can fall
 before `day_start_us`, on the previous UTC date, and west of it the sunset can fall after the day
 ends; `daylight_at` reads the days either side for that reason. The solar noon is refined twice,
 as the NOAA worksheet does, so the equations see the time of day they describe.

 @param latitude : "Degrees north, -90..90"
 @param longitude : "Degrees east, -180..180"
*>
fn DayEvents day_events(Degrees latitude, Degrees longitude, long day_start_us)
{
	double jd0 = julian_day(day_start_us);
	double jd = jd0 + 0.5;
	double noon_minutes = 0.0;
	for (int pass = 0; pass < 2; pass++)
	{
		Sun sun = sun_at(jd);
		noon_minutes = 720.0 - 4.0 * longitude - sun.equation_minutes;
		jd = jd0 + noon_minutes / 1440.0;
	}
	Sun sun = sun_at(jd);
	double lat = latitude * DEG;
	double cos_hour = math::cos(SUNRISE_ZENITH * DEG) / (math::cos(lat) * math::cos(sun.declination))
		- math::tan(lat) * math::tan(sun.declination);
	// Outside [-1, 1] the sun stays above (or below) the horizon all day: no crossing.
	if (!(cos_hour >= -1.0 && cos_hour <= 1.0)) return { .crosses = false };
	double half_day_minutes = 4.0 * math::acos(cos_hour) / DEG;
	return {
		.crosses = true,
		.sunrise = day_start_us + (long)((noon_minutes - half_day_minutes) * 60.0e6),
		.sunset = day_start_us + (long)((noon_minutes + half_day_minutes) * 60.0e6),
	};
}

<*
 Whether the sun is above the horizon at `unix_us` (the polar fallback).
*>
fn bool sun_is_up(Degrees latitude, Degrees longitude, long unix_us)
{
	Sun sun = sun_at(julian_day(unix_us));
	double minutes_utc = (double)(unix_us - day_start(unix_us)) / 60.0e6;
	// True solar time, then the hour angle: noon is 0, measured as 180 degrees from the meridian.
	double solar_minutes = minutes_utc + sun.equation_minutes + 4.0 * longitude;
	double hour_angle = solar_minutes / 4.0 - 180.0;
	double lat = latitude * DEG;
	double sine_altitude = math::sin(lat) * math::sin(sun.declination)
		+ math::cos(lat) * math::cos(sun.declination) * math::cos(hour_angle * DEG);
	double altitude = math::asin(math::clamp(sine_altitude, -1.0, 1.0)) / DEG;
	return altitude > HORIZON_ALTITUDE;
}

<* Sort edges by time; there are at most six. Insertion sort keeps this allocation-free. *>
fn void sort_edges(Edge[] edges)
{
	for (usz i = 1; i < edges.len; i++)
	{
		Edge item = edges[i];
		usz j = i;
		while (j > 0 && edges[j - 1].at > item.at)
		{
			edges[j] = edges[j - 1];
			j--;
		}
		edges[j] = item;
	}
}

<*
 The daylight fraction at `unix_us` for a SCHEDULE or TIMES schedule, in 0.0..1.0.

 @param utc_offset_us : "The local time zone's offset from UTC in effect at `unix_us`, in microseconds; used by TIMES"
*>
fn float daylight_at(Schedule schedule, long unix_us, long utc_offset_us)
{
	Edge[6] edges;
	usz count = 0;
	for (int d = -1; d <= 1; d++)
	{
		if (schedule.mode == Mode.SCHEDULE)
		{
			DayEvents events = day_events(schedule.latitude, schedule.longitude, day_start(unix_us) + (long)d * DAY_US);
			if (!events.crosses) continue;
			edges[count] = { .at = events.sunrise, .rising = true };
			edges[count + 1] = { .at = events.sunset, .rising = false };
			count += 2;
		}
		else
		{
			// Local midnight of the local day `d` days from today, as a UTC instant.
			long local_midnight = day_start(unix_us + utc_offset_us) + (long)d * DAY_US - utc_offset_us;
			edges[count] = { .at = local_midnight + (long)schedule.sunrise, .rising = true };
			edges[count + 1] = { .at = local_midnight + (long)schedule.sunset, .rising = false };
			count += 2;
		}
	}
	if (count == 0) return sun_is_up(schedule.latitude, schedule.longitude, unix_us) ? 1.0f : 0.0f;
	sort_edges(edges[0:count]);
	long half = (long)schedule.transition / 2;
	// Before the first edge the daylight state is the opposite of what that edge sets.
	float level = edges[0].rising ? 0.0f : 1.0f;
	for (usz i = 0; i < count; i++)
	{
		float after = edges[i].rising ? 1.0f : 0.0f;
		long start = edges[i].at - half;
		long end = edges[i].at + half;
		if (unix_us < start) return level;
		if (unix_us < end)
		{
			float p = (float)(unix_us - start) / (float)(end - start);
			float s = p * p * (3.0f - 2.0f * p);
			return level + (after - level) * s;
		}
		level = after;
	}
	return level;
}

<*
 The colour temperature the schedule asks for at `now`: `night` at night, `day` in daylight, and
 the smoothstep between them during each transition. Rounded to the nearest kelvin.

 @param now : "A Unix time in microseconds, UTC"
 @param utc_offset : "The local offset from UTC in effect at `now`, for TIMES"
 @require schedule.mode != Mode.MANUAL : "A MANUAL schedule has no temperature of its own"
*>
fn Kelvin temperature_at(Schedule schedule, Time now, Duration utc_offset)
{
	float w = daylight_at(schedule, (long)now, (long)utc_offset);
	double night = (double)schedule.night;
	double day = (double)schedule.day;
	return (Kelvin)math::round(night + (day - night) * (double)w);
}

<*
 Check a schedule before it is queued. MANUAL is always valid.

 @return? error::INVALID_ARGUMENT : "A latitude or longitude is out of range, a time of day is outside one day, or the transition exceeds one hour"
*>
fn void? validate(Schedule schedule)
{
	if (schedule.mode == Mode.MANUAL) return;
	if (!((long)schedule.transition >= 0 && (long)schedule.transition <= HOUR_US))
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "transition must be 0 to one hour")~;
	}
	if (schedule.mode == Mode.SCHEDULE)
	{
		if (!(schedule.latitude >= -90.0 && schedule.latitude <= 90.0))
		{
			return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "latitude must be -90 to 90 degrees")~;
		}
		if (!(schedule.longitude >= -180.0 && schedule.longitude <= 180.0))
		{
			return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "longitude must be -180 to 180 degrees")~;
		}
		return;
	}
	if (!((long)schedule.sunrise >= 0 && (long)schedule.sunrise < DAY_US && (long)schedule.sunset >= 0 && (long)schedule.sunset < DAY_US))
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "sunrise and sunset must be times of day")~;
	}
}
