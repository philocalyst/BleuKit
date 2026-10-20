<*
 Windows display numbers as the display types: rotation values, and refresh rates as fractions.
 Pure arithmetic, so it is tested on every host; the constants are from wingdi.h (DISPLAYCONFIG_ROTATION).
*>
module bleu::display::win_convert;
import bleu::display;

// DISPLAYCONFIG_ROTATION: the identity is 1 and each quarter turn adds one.
const uint ROTATION_IDENTITY = 1;
const uint ROTATION_90 = 2;
const uint ROTATION_180 = 3;
const uint ROTATION_270 = 4;

<* A fraction, as DISPLAYCONFIG_RATIONAL holds a frequency: numerator over denominator, in Hz. *>
struct Fraction
{
	uint numerator;
	uint denominator;
}

<*
 The transform a DISPLAYCONFIG_ROTATION names. Windows has no flipped rotation: those values, and any
 unknown one, read as NORMAL.
*>
fn display::Transform transform_from_rotation(uint rotation)
{
	if (rotation == ROTATION_90) return display::Transform.R90;
	if (rotation == ROTATION_180) return display::Transform.R180;
	if (rotation == ROTATION_270) return display::Transform.R270;
	return display::Transform.NORMAL;
}

<*
 The DISPLAYCONFIG_ROTATION for a transform. False for the flipped transforms, which Windows cannot set.
*>
fn bool rotation_of(display::Transform transform, uint* rotation)
{
	switch (transform) {
		case NORMAL:
			*rotation = ROTATION_IDENTITY;
			return true;
		case R90:
			*rotation = ROTATION_90;
			return true;
		case R180:
			*rotation = ROTATION_180;
			return true;
		case R270:
			*rotation = ROTATION_270;
			return true;
		default:
			return false;
	}
}

<* A refresh rate in millihertz from a fraction of hertz, rounded to the nearest millihertz; 0 when the denominator is 0. *>
fn display::RefreshMilliHz refresh_from_fraction(uint numerator, uint denominator)
{
	if (denominator == 0) return 0;
	return (display::RefreshMilliHz)(((ulong)numerator * 1000 + denominator / 2) / denominator);
}

<* The fraction of hertz that holds a refresh rate given in millihertz (exact: the denominator is 1000). *>
fn Fraction fraction_from_refresh(display::RefreshMilliHz millihertz) => { .numerator = millihertz, .denominator = 1000 };
