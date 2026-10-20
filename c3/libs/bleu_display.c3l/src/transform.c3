<*
 Output transforms as plain arithmetic: how a mode's pixels run once the output is rotated,
 and what size that leaves on the desktop once the scale is applied. No platform code.
*>
module bleu::display;
import std::math, std::collections::maybe;

<* A size in whole logical pixels. *>
struct Extent
{
	int width;
	int height;
}

<* True for the transforms that turn the output a quarter turn, which swaps its width and height. *>
fn bool Transform.quarter_turn(
	self
) @inline => self == R90 || self == R270 || self == FLIPPED_R90 || self == FLIPPED_R270;

<* The scale a missing value stands for: the platform default of 1.0. *>
fn ScaleFactor scale_or_default(Maybe{ScaleFactor} scale) @inline => scale.has_value ? scale.value : 1.0;

<*
 Size of an output in logical pixels: its mode, turned for a quarter turn, divided by the
 scale and rounded to the nearest whole pixel.

 @require factor > 0.0 : "A scale factor must be positive"
*>
fn Extent logical_extent(Mode mode, Transform transform, ScaleFactor factor)
{
	uint width  = transform.quarter_turn() ? mode.height : mode.width;
	uint height = transform.quarter_turn() ? mode.width : mode.height;
	return {
		.width = (int)math::round((double)width / factor),
		.height = (int)math::round((double)height / factor),
	};
}

<*
 The scale a compositor implies by reporting a logical width for a mode: the mode's width in the
 output's orientation over that width. Zero when the logical width is unknown, which the caller
 reports as an empty scale.
*>
fn ScaleFactor scale_from_logical_width(Mode mode, Transform transform, uint logical_width)
{
	if (logical_width == 0) return 0.0;
	uint pixels = transform.quarter_turn() ? mode.height : mode.width;
	return (double)pixels / (double)logical_width;
}