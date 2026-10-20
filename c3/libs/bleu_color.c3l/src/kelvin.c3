<*
 Colour temperature as RGB multipliers: the white point of a black body at a temperature.

 `rgb(temperature)` interpolates Redshift's black-body table (kelvin_table.c3) linearly between
 the two 100 K rows around the request. The result multiplies a ramp's channels: 6500 K is
 exactly (1, 1, 1), warmer temperatures lower blue and then green, cooler ones lower red.
 Temperatures outside [MIN, MAX] are clamped. Pure: no I/O.

 Source of the approach: Redshift `src/colorramp.c` (`colorramp_fill`, which interpolates the
 same table by `alpha = (temp % 100) / 100`). Cross-checked against wlsunset's independent
 Planckian-locus and daylight-locus computation in tests/kelvin_test.c3.
*>
module bleu::color::kelvin;
import bleu::unit, std::math;

<* The coolest temperature the table covers, in kelvin. *>
const Kelvin MIN = (Kelvin)1000;

<* The warmest temperature the table covers, in kelvin. *>
const Kelvin MAX = (Kelvin)25000;

<* Full daylight of a display with no colour change: the identity ramp. *>
const Kelvin NEUTRAL = (Kelvin)6500;

<* Width of one table row, in kelvin. Redshift's table is in 100 K steps. *>
const Kelvin STEP = (Kelvin)100;

<* The RGB multipliers of one temperature. Each is in 0.0..1.0 and the largest is 1.0. *>
struct Rgb
{
	float r;
	float g;
	float b;
}

<*
 The multipliers of `temperature`, clamped to [MIN, MAX] and interpolated between table rows.

 @return "Multipliers in 0.0..1.0; 6500 K is (1, 1, 1)"
*>
fn Rgb rgb(Kelvin temperature)
{
	Kelvin t = math::clamp(temperature, MIN, MAX);
	// The row below t, and the fraction of the way from that row to the next one.
	usz row = (usz)((t - MIN) / STEP);
	float alpha = (float)((t - MIN) % STEP) / (float)STEP;
	usz low = row * 3;
	usz high = low + 3;
	return {
		.r = (1.0f - alpha) * BLACKBODY[low] + alpha * BLACKBODY[high],
		.g = (1.0f - alpha) * BLACKBODY[low + 1] + alpha * BLACKBODY[high + 1],
		.b = (1.0f - alpha) * BLACKBODY[low + 2] + alpha * BLACKBODY[high + 2],
	};
}
