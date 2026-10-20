<*
 DankMaterialShell's brightness arithmetic, as plain functions.

 Every formula here is a transcription of `core/internal/server/brightness/`
 (sysfs.go, ddc.go, handlers.go and manager.go at DMS master 8be08999). The
 Bleu backend reports raw device values and ranges; these functions turn them
 into the percentages and raw values DMS clients see and expect, so a
 `setBrightness` of 50 writes the same raw value DMS would have written.
*>
module dmsd::brightness_math;
import std::math;

<* The device classes DMS reports (brightness/types.go:12-17). *>
enum DmsClass : char
{
	BACKLIGHT, // a panel backlight: sysfs class `backlight`
	LEDS,      // a keyboard LED: sysfs class `leds`
	DDC,       // an external monitor over DDC/CI
}

<* The `class` string on the wire. *>
fn String DmsClass.wire_name(self)
{
	switch (self)
	{
		case BACKLIGHT: return "backlight";
		case LEDS: return "leds";
		case DDC: return "ddc";
	}
}

<* The `backend` string on the wire: the sysfs classes say "sysfs", DDC says "ddc" (sysfs.go:148, ddc.go:363). *>
fn String DmsClass.backend(self)
{
	switch (self)
	{
		case BACKLIGHT: return "sysfs";
		case LEDS: return "sysfs";
		case DDC: return "ddc";
	}
}

<* Sort rank of a class: backlight, ddc, software, leds (manager.go sortDevices). *>
fn int DmsClass.rank(self)
{
	switch (self)
	{
		case BACKLIGHT: return 0;
		case DDC: return 1;
		case LEDS: return 3;
	}
}

// Lowest raw value of a backlight (sysfs.go:60) and of an LED (sysfs.go:63).
const long BACKLIGHT_MIN = 1;
const long LED_MIN = 0;
// Lowest raw value of a DDC/CI monitor (ddc.go percentToValue: `const minValue = 1`).
const long DDC_MIN = 1;
// Exponent of the DDC/CI exponential curve (ddc.go percentToValue). Sysfs uses the request's exponent.
const double DDC_EXPONENT = 2.0;
// Exponent used when a request does not give one (handlers.go: `params.FloatOpt(req.Params, "exponent", 1.2)`).
const double DEFAULT_EXPONENT = 1.2;
// Percent range: 0 to 100, with 1 to 100 spread over 99 steps.
const long PERCENT_MAX = 100;
const double PERCENT_STEPS = 99.0;

<* Lower bound of the class's raw range. *>
fn long DmsClass.min_value(self)
{
	switch (self)
	{
		case BACKLIGHT: return BACKLIGHT_MIN;
		case LEDS: return LED_MIN;
		case DDC: return DDC_MIN;
	}
}

<* `value` limited to [min, max]. *>
fn long clamp_raw(long value, long min_value, long max_value)
{
	if (value < min_value) return min_value;
	if (value > max_value) return max_value;
	return value;
}

<*
 Percent of a sysfs raw value (sysfs.go ValueToPercentWithExponent, linear).
 Any value above the minimum is at least 1 percent; the value at the minimum is 1,
 or 0 for a zero minimum (`LEDS`).
*>
fn long sysfs_percent(long value, long min_value, long max_value)
{
	if (value <= min_value) return (min_value == 0 && value == 0) ? 0 : 1;
	long usable = max_value - min_value;
	if (usable == 0) return PERCENT_MAX;
	long percent = 1 + (long)math::round((double)(value - min_value) * PERCENT_STEPS / (double)usable);
	return percent > PERCENT_MAX ? PERCENT_MAX : percent;
}

<* Percent of a DDC/CI raw value (ddc.go ddcPercentFromRaw). Zero when the maximum is unknown. *>
fn long ddc_percent(long raw, long max_value)
{
	if (max_value <= 0) return 0;
	long percent = (long)math::round((double)(raw * 100) / (double)max_value);
	return percent > PERCENT_MAX ? PERCENT_MAX : percent;
}

<*
 Raw value for a sysfs percent (sysfs.go PercentToValueWithExponent). Zero percent
 is the minimum; the exponential curve is `((p-1)/99)^exponent`; both clamp to the range.
*>
fn long sysfs_value(long percent, long min_value, long max_value, bool exponential, double exponent)
{
	if (percent == 0) return min_value;
	long usable = max_value - min_value;
	long value;
	if (exponential)
	{
		double normalized = (double)(percent - 1) / PERCENT_STEPS;
		value = min_value + (long)math::round(math::pow(normalized, exponent) * (double)usable);
	}
	else
	{
		value = min_value + ((percent - 1) * usable) / 99;
	}
	return clamp_raw(value, min_value, max_value);
}

<*
 Raw value for a DDC/CI percent (ddc.go percentToValue). The exponential curve
 uses DDC_EXPONENT whatever the request says.
*>
fn long ddc_value(long percent, long max_value, bool exponential)
{
	if (percent == 0) return DDC_MIN;
	long usable = max_value - DDC_MIN;
	long value;
	if (exponential)
	{
		double normalized = (double)percent / (double)PERCENT_MAX;
		value = DDC_MIN + (long)math::round(math::pow(normalized, 1.0 / DDC_EXPONENT) * (double)usable);
	}
	else
	{
		value = DDC_MIN + ((percent - 1) * usable) / 99;
	}
	return clamp_raw(value, DDC_MIN, max_value);
}

<* Raw value to write for `percent` on a device of `cls` whose maximum is `max_value`. *>
fn long target_value(DmsClass cls, long percent, long max_value, bool exponential, double exponent)
{
	switch (cls)
	{
		case BACKLIGHT: return sysfs_value(percent, BACKLIGHT_MIN, max_value, exponential, exponent);
		case LEDS: return sysfs_value(percent, LED_MIN, max_value, exponential, exponent);
		case DDC: return ddc_value(percent, max_value, exponential);
	}
}

// Names DMS hides from its device list (sysfs.go:82-101): the network LAN LED and the lock-key LEDs.
const String[6] SUPPRESSED_SUFFIXES = { "::lan", "::scrolllock", "::capslock", "::numlock", "::kana", "::compose" };

<* Whether DMS leaves a sysfs device with this name out of its device list. *>
fn bool suppressed(String name)
{
	foreach (suffix : SUPPRESSED_SUFFIXES)
	{
		if (name.ends_with(suffix)) return true;
	}
	return false;
}

<* Clamp a request's percent to 0..100, as `IncrementBrightnessWithExponent` does. *>
fn long clamp_percent(long percent)
{
	return clamp_raw(percent, 0, PERCENT_MAX);
}
