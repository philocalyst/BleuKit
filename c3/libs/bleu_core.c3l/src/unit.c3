<*
 Strongly typed physical quantities.

 Every quantity a desktop service reports is its own type, so a brightness
 level cannot be handed to an API that wants a volume, and a raw DDC register
 value cannot be mistaken for a percentage.
*>
module bleu::unit;
import std::math;

<*
 A normalised amount in the closed range 0.0 ..= 1.0: volume, brightness,
 charge, signal quality. 1.0 is "everything the device can do", which is not
 necessarily 100 % of anything physical (see `Nits` for that).
*>
typedef Level = float;

const Level LEVEL_MIN = (Level)0.0f;
const Level LEVEL_MAX = (Level)1.0f;

<* Clamp any float into a valid level. NaN becomes zero. *>
fn Level level(float value) @inline
{
	if (value != value) return LEVEL_MIN;
	return (Level)math::clamp(value, 0.0f, 1.0f);
}

fn Level from_percent(float percent) @inline => level(percent / 100.0f);
fn Level from_ratio(double value, double max) @inline => max > 0 ? level((float)(value / max)) : LEVEL_MIN;

fn float Level.percent(self) @inline => (float)self * 100.0f;
fn bool Level.is_zero(self) @inline => (float)self <= 0.0f;

<*
 Map onto a device's native integer register range, rounding to nearest.

 @require max > min : "The range must be non-degenerate"
*>
fn long Level.to_raw(self, long min, long max)
{
	double span = (double)(max - min);
	return min + (long)(math::round((double)(float)self * span));
}

<*
 Inverse of `to_raw`; values outside [min, max] saturate.

 @require max > min : "The range must be non-degenerate"
*>
fn Level from_raw(long raw, long min, long max)
{
	return level((float)(raw - min) / (float)(max - min));
}

<* Linear interpolation between two levels. *>
fn Level Level.lerp(self, Level to, float t) @inline
{
	float a = (float)self;
	return level(a + ((float)to - a) * t);
}

<* Luminance in candela per square metre. Only ever *estimated* or read, never assumed. *>
typedef Nits = float;

<* Temperature in degrees Celsius. *>
typedef Celsius = float;

<* Electrical power in milliwatts. *>
typedef MilliWatt = long;

<* Energy in milliwatt-hours. *>
typedef MilliWattHour = long;

<* Colour temperature in kelvin. *>
typedef Kelvin = int;

<* Signal strength in dBm (negative; closer to zero is stronger). *>
typedef Dbm = short;

<*
 Rough quality of a Wi-Fi/Bluetooth link derived from its dBm, in the manner of
 NetworkManager and Windows (-100 dBm = 0, -50 dBm = 1).
*>
fn Level Dbm.quality(self) @inline => level(((float)(short)self + 100.0f) / 50.0f);
