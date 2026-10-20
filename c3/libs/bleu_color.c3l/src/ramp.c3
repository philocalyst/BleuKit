<*
 Gamma ramps: the three tables a display maps its values through, computed and encoded.

 A ramp of `size` entries is `3 * size` floats: the red table, then green, then blue, each of
 `size` values in 0.0..1.0. Entry i of a table answers the input level i / (size - 1). The
 value for a channel is

   out(x) = clamp((x * brightness * white[channel]) ^ (1 / gamma), 0, 1)

 where `white` is the multiplier of `kelvin::rgb(temperature)`. That is Redshift's
 `colorramp_fill_float` (src/colorramp.c, `F(Y, C)`), with brightness and gamma as its
 `setting->brightness` and `setting->gamma`. The identity ramp (6500 K, brightness 1, gamma 1) is
 `x` on every channel.

 Platforms take the result as they need it: Windows and Wayland as 16-bit words (`encode_u16`),
 macOS as floats. Any size from 2 entries up is valid: Windows and the usual macOS table use 256,
 Wayland's table size comes from the compositor.
*>
module bleu::color::ramp;
import bleu::error, bleu::unit, bleu::color::kelvin, std::math;

<* The entry count of a Windows `SetDeviceGammaRamp` table and of the usual macOS table. *>
const usz STANDARD_SIZE = 256;

<* The largest 16-bit value: the full scale of an encoded entry. *>
const float U16_FULL_SCALE = 65535.0f;

<*
 Fill a ramp of `size` entries for `temperature`, `brightness` and `gamma`.

 @param out : "Three tables back to back, `3 * size` floats; written in full"
 @param size : "Entries per table, at least 2"
 @param gamma : "Display gamma exponent, above zero; 1.0 is linear"
 @return? error::INVALID_ARGUMENT : "Size below 2, the buffer does not hold three tables, or gamma is not positive"
*>
fn void? fill(float[] out, usz size, Kelvin temperature, Level brightness, double gamma)
{
	if (size < 2 || (usz)out.len != 3 * size)
	{
		return error::raise(
			error::INVALID_ARGUMENT,
			error::Domain.INTERNAL,
			0,
			"a ramp of %d entries needs %d floats and at least 2 entries",
			size,
			3 * size
		)~;
	}
	if (!(gamma > 0.0))
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "gamma must be positive")~;
	}
	kelvin::Rgb white = kelvin::rgb(temperature);
	float[3] multiplier = { white.r, white.g, white.b };
	double exponent = 1.0 / gamma;
	for (usz i = 0; i < size; i++)
	{
		double input = (double)i / (double)(size - 1);
		for (usz channel = 0; channel < 3; channel++)
		{
			double level = input * (double)brightness * (double)multiplier[channel];
			out[channel * size + i] = (float)math::clamp(math::pow(level, exponent), 0.0, 1.0);
		}
	}
}

<*
 Encode floats in 0.0..1.0 as 16-bit words, rounded to the nearest. Out-of-range values are
 clamped. Used for the Wayland and Windows tables; the byte order is the host's, which is what
 the compositor reads from the descriptor.

 @param values : "Floats to encode"
 @param out : "Words to write, the same length as `values`"
 @return? error::INVALID_ARGUMENT : "The lengths differ"
*>
fn void? encode_u16(float[] values, ushort[] out)
{
	if (values.len != out.len)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "%d floats for %d words", values.len, out.len)~;
	}
	for (sz i = 0; i < values.len; i++)
	{
		float clamped = math::clamp(values[i], 0.0f, 1.0f);
		out[i] = (ushort)math::round((double)(clamped * U16_FULL_SCALE));
	}
}
