<*
 The settings of the `gamma` module (DMS's `wayland.Config`), and how they become the one
 command bleu_color takes. Pure: no service, no clock.

 Source, DMS master 8be08999: `core/internal/server/wayland/types.go:31-49` (Config),
 `manager.go:600-665` (`recalcSchedule`: the manual times take precedence over the location,
 and a day with no location and no manual times has no schedule), `manager.go:900-942`
 (`applyCurrentTemp`: disabled is the identity ramp, equal low and high is a constant
 temperature, and otherwise the temperature moves between `LowTemp` at night and `HighTemp` in
 daylight: `getTempFromPosition`, `manager.go:782-787`).

 Mapping to bleu_color (see docs/DMSD.md, "gamma"):
 * disabled, or no schedule: `reset()`.
 * low equal to high: `set_temperature(ALL_OUTPUTS, low)`.
 * manual times: a TIMES schedule. DMS ramps from `sunrise - duration` to `sunrise` and from
 `sunset` to `sunset + duration`; bleu_color centres each change on its event, so each edge is
 moved by half the duration (`mod_gamma_settings.c3` `times_schedule`).
 * a location: a SCHEDULE at that place. bleu_color's sun model and its 30-minute change differ
 from DMS's (docs/DMSD.md).
*>
module dmsd::gamma_settings;
import bleu::color, bleu::error, bleu::unit, std::time;

<* Microseconds in a minute and in a day. *>
const long MINUTE_US = 60000000;
const long DAY_US    = 86400000000;

<* The defaults dmsd starts with (not read from DMS: its defaults live in code this port did not fetch). *>
const long DEFAULT_LOW_TEMP                =  4500;
const long DEFAULT_HIGH_TEMP               =  6500;
const double DEFAULT_GAMMA                 =  1.0;
const double DEFAULT_CONTRAST              =  1.0;
// DMS's elevations for twilight and daylight (`thememode` defaults, manager.go:19-20).
const double DEFAULT_ELEVATION_TWILIGHT    = -6.0;
const double DEFAULT_ELEVATION_DAYLIGHT    =  3.0;
// DMS's default length of a manual transition: one hour (manager.go:132, `dur := time.Hour`).
const long DEFAULT_MANUAL_DURATION_MINUTES =  60;

<*
 The settings a client sets. `has_location`, `has_manual` and `has_duration` are DMS's nil
 pointers (`Latitude`, `ManualSunrise`/`ManualSunset`, `ManualDuration`). Manual times are
 minutes after local midnight.
*>
struct GammaSettings
{
	long low_temp;
	long high_temp;
	bool has_location;
	double latitude;
	double longitude;
	bool has_manual;
	long sunrise_minute;
	long sunset_minute;
	bool has_duration;
	long duration_minutes;
	bool use_ip_location;
	bool enabled;
	double gamma;
	double contrast;
	double elevation_twilight;
	double elevation_daylight;
}

<* What the settings ask bleu_color for. *>
enum Plan : char
{
	RESET,    // no ramp: the identity, as DMS shows when the night light is off or has no schedule
	CONSTANT, // one temperature for every display
	TIMES,    // a schedule at fixed local times
	SUN,      // a schedule at a place
}

<* The settings a fresh daemon starts with. *>
fn GammaSettings default_settings()
{
	return {
		.low_temp = DEFAULT_LOW_TEMP,
		.high_temp = DEFAULT_HIGH_TEMP,
		.gamma = DEFAULT_GAMMA,
		.contrast = DEFAULT_CONTRAST,
		.elevation_twilight = DEFAULT_ELEVATION_TWILIGHT,
		.elevation_daylight = DEFAULT_ELEVATION_DAYLIGHT,
	};
}

<* The plan for `settings`, in DMS's order of precedence (`applyCurrentTemp`, `recalcSchedule`). *>
fn Plan plan_of(GammaSettings settings)
{
	if (!settings.enabled) return RESET;
	if (settings.low_temp == settings.high_temp) return CONSTANT;
	if (settings.has_manual) return TIMES;
	if (settings.has_location) return SUN;
	return RESET;
}

<* Wrap a time of day to [0, one day), in microseconds. *>
fn long wrap_day(long us) @inline => ((us % DAY_US) + DAY_US) % DAY_US;

<*
 The TIMES schedule for manual times. Each DMS edge is a ramp of `duration` that ends at the event
 (sunrise) or starts at it (sunset); bleu_color's change is centred on its edge, so the edge is
 placed half a duration away from the DMS event, which gives the same ramp.

 @return "The schedule; the caller validates it"
*>
fn color::Schedule times_schedule(GammaSettings settings)
{
	long minutes  = settings.has_duration ? settings.duration_minutes : DEFAULT_MANUAL_DURATION_MINUTES;
	long duration = minutes * MINUTE_US;
	return {
		.mode = color::Mode.TIMES,
		.sunrise = (Duration)wrap_day(settings.sunrise_minute * MINUTE_US - duration / 2),
		.sunset = (Duration)wrap_day(settings.sunset_minute * MINUTE_US + duration / 2),
		.day = (unit::Kelvin)settings.high_temp,
		.night = (unit::Kelvin)settings.low_temp,
		.transition = (Duration)duration,
	};
}

<* The SCHEDULE for a place. The sun model and the change length are bleu_color's (docs/DMSD.md). *>
fn color::Schedule sun_schedule(GammaSettings settings)
{
	return {
		.mode = color::Mode.SCHEDULE,
		.latitude = settings.latitude,
		.longitude = settings.longitude,
		.day = (unit::Kelvin)settings.high_temp,
		.night = (unit::Kelvin)settings.low_temp,
		.transition = color::DEFAULT_TRANSITION,
	};
}

<* The `Schedule` for a TIMES or SUN plan. The other plans have none. *>
fn color::Schedule schedule_of(GammaSettings settings, Plan plan)
{
	return plan == Plan.TIMES ? times_schedule(settings) : sun_schedule(settings);
}

<*
 Parse a DMS clock value `HH:MM` as Go's `time.Parse("15:04", ...)` reads it: the hour has one
 or two digits, the minutes exactly two, and the ranges are 0-23 and 0-59. Returns minutes after midnight.

 @return? error::INVALID_ARGUMENT : "The text is not a clock value"
*>
fn long? parse_clock(String text)
{
	if (text.len < 4 || text.len > 5) return invalid_clock(text)~;
	sz colon = text.len - 3;
	if (text[colon] != ':') return invalid_clock(text)~;
	long hour = 0;
	for (sz i = 0; i < colon; i++)
	{
		if (text[i] < '0' || text[i] > '9') return invalid_clock(text)~;
		hour = hour * 10 + (long)(text[i] - '0');
	}
	long minute = 0;
	for (sz i = colon + 1; i < text.len; i++)
	{
		if (text[i] < '0' || text[i] > '9') return invalid_clock(text)~;
		minute = minute * 10 + (long)(text[i] - '0');
	}
	if (hour > 23 || minute > 59) return invalid_clock(text)~;
	return hour * 60 + minute;
}

// The error of `parse_clock`: the text is not a clock value.
fn fault invalid_clock(String text) @private
{
	return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "not a clock value: %s", text);
}