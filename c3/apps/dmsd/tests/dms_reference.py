"""An independent port of DankMaterialShell's theme schedule, for checking dmsd.

Written from the Go sources, not from dmsd's C3 code, so that a mistake in one is not copied into
the other:

* `core/internal/server/wayland/suncalc.go` (CalculateSunTimesWithTwilight, the solar equations),
  DMS master 8be08999, lines 1-136;
* `core/internal/server/thememode/manager.go` (computeTimeSchedule, computeLocationSchedule,
  startOfNextDay), lines 361-447.

Times are aware datetimes. The local zone is the process's zone (TZ), as Go's time.Local is.
Go's `time.Duration(x)` of a float truncates toward zero, which `trunc` does here.
"""
import datetime
import math

DEG = math.pi / 180.0
RAD_TO_DEG = 180.0 / math.pi
UTC = datetime.timezone.utc


def trunc(x):
    return int(x)  # Go's float-to-integer conversion truncates toward zero


def days_in_year(year):
    return 366 if (year % 4 == 0 and year % 100 != 0) or year % 400 == 0 else 365


def orbit_angle(day_start):
    """dateOrbitAngle (suncalc.go:35-37) for the UTC day `day_start`."""
    return 2 * math.pi / days_in_year(day_start.year) * (day_start.timetuple().tm_yday - 1)


def equation_of_time(a):
    """equationOfTime (suncalc.go:39-45), in minutes."""
    return 4 * (0.000075 + 0.001868 * math.cos(a) - 0.032077 * math.sin(a)
                - 0.014615 * math.cos(2 * a) - 0.040849 * math.sin(2 * a))


def sun_declination(a):
    """sunDeclination (suncalc.go:47-55), in radians."""
    return (0.006918 - 0.399912 * math.cos(a) + 0.070257 * math.sin(a) - 0.006758 * math.cos(2 * a)
            + 0.000907 * math.sin(2 * a) - 0.002697 * math.cos(3 * a) + 0.00148 * math.sin(3 * a))


def sun_hour_angle(lat_rad, decl, target_rad):
    """sunHourAngle (suncalc.go:65-77): (hour angle, state)."""
    cos_h = math.cos(target_rad) / (math.cos(lat_rad) * math.cos(decl)) - math.tan(lat_rad) * math.tan(decl)
    if cos_h < -1:
        return math.pi, "above"
    if cos_h > 1:
        return 0.0, "below"
    return math.acos(cos_h), "crosses"


def hour_angle_seconds(ha, eqtime):
    """hourAngleToSeconds (suncalc.go:79-81)."""
    return RAD_TO_DEG * (4.0 * math.pi - 4 * ha - eqtime) * 60


def sun_times(lat, lon, now, elev_twilight, elev_daylight):
    """CalculateSunTimesWithTwilight (suncalc.go:83-136) for the local day of `now`.

    Returns ("normal", {dawn, sunrise, sunset, night}) or ("midnight_sun" | "polar_night", None).
    """
    lat_rad = lat * DEG
    twilight_rad = (90.833 - elev_twilight) * DEG
    daylight_rad = (90.833 - elev_daylight) * DEG
    lon_offset = datetime.timedelta(minutes=trunc(-lon * 4))
    local_day = now.astimezone().date()
    local_noon = datetime.datetime(local_day.year, local_day.month, local_day.day, 12).astimezone()
    ref = (local_noon.astimezone(UTC) - lon_offset).date()
    day_start = datetime.datetime(ref.year, ref.month, ref.day, tzinfo=UTC)
    angle = orbit_angle(day_start)
    decl = sun_declination(angle)
    eq = equation_of_time(angle)
    ha_tw, state_tw = sun_hour_angle(lat_rad, decl, twilight_rad)
    ha_dl, state_dl = sun_hour_angle(lat_rad, decl, daylight_rad)
    if state_dl == "above":
        return "midnight_sun", None
    if state_tw == "below":
        return "polar_night", None

    def at(seconds):
        return day_start + datetime.timedelta(seconds=trunc(seconds)) + lon_offset

    return "normal", {
        "dawn": at(hour_angle_seconds(abs(ha_tw), eq)),
        "sunrise": at(hour_angle_seconds(abs(ha_dl), eq)),
        "sunset": at(hour_angle_seconds(-abs(ha_dl), eq)),
        "night": at(hour_angle_seconds(-abs(ha_tw), eq)),
    }


def local_at(day, hour, minute):
    """time.Date(y, m, d, h, min, 0, 0, Local) for the local date `day`."""
    return datetime.datetime(day.year, day.month, day.day, hour, minute).astimezone()


def start_of_next_day(t):
    """startOfNextDay (manager.go:444-447)."""
    nxt = (t + datetime.timedelta(hours=24)).astimezone()
    return datetime.datetime(nxt.year, nxt.month, nxt.day).astimezone()


def time_schedule(now, start_hour, start_minute, end_hour, end_minute):
    """computeTimeSchedule (manager.go:370-403): (isLight, next transition) for the local clock."""
    local = now.astimezone()
    start_minutes = start_hour * 60 + start_minute
    end_minutes = end_hour * 60 + end_minute
    current = local.hour * 60 + local.minute
    start_time = local_at(local.date(), start_hour, start_minute)
    end_time = local_at(local.date(), end_hour, end_minute)
    if start_minutes == end_minutes:
        nxt = start_time
        if not nxt > now:
            nxt = nxt + datetime.timedelta(hours=24)
        return True, nxt
    if start_minutes < end_minutes:
        if current < start_minutes:
            return True, start_time
        if current >= end_minutes:
            return True, start_time + datetime.timedelta(hours=24)
        return False, end_time
    if current >= start_minutes:
        return False, end_time + datetime.timedelta(hours=24)
    if current < end_minutes:
        return False, end_time
    return True, start_time


def location_schedule(now, lat, lon, elev_twilight, elev_daylight):
    """computeLocationSchedule (manager.go:405-442) with the IP location unavailable: (isLight, next)."""
    cond, times = sun_times(lat, lon, now, elev_twilight, elev_daylight)
    if cond == "midnight_sun":
        return True, start_of_next_day(now)
    if cond == "polar_night":
        return False, start_of_next_day(now)
    if now < times["sunrise"]:
        return False, times["sunrise"]
    if now < times["sunset"]:
        return True, times["sunset"]
    next_day = start_of_next_day(now)
    cond2, times2 = sun_times(lat, lon, next_day, elev_twilight, elev_daylight)
    if cond2 == "midnight_sun":
        return True, start_of_next_day(next_day)
    if cond2 == "polar_night":
        return False, start_of_next_day(next_day)
    return False, times2["sunrise"]


def theme_state(now, config):
    """updateState's inputs for an enabled config (manager.go:263-278): (isLight, nextTransition)."""
    if config["mode"] == "location":
        return location_schedule(now, config["latitude"], config["longitude"],
                                 config["elevationTwilight"], config["elevationDaylight"])
    return time_schedule(now, config["startHour"], config["startMinute"], config["endHour"], config["endMinute"])
