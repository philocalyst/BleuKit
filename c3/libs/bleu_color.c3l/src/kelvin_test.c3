module bleu::color::kelvin_test;
import bleu::unit, bleu::color::kelvin, std::math;

// Two independent computations of the same white point, as wlsunset's color.c computes them
// (its Planckian locus and daylight locus, with the sRGB-style 1/2.2 gamma of xyz_to_rgb) and
// as the table above interpolates them. Values from docs/research/color_impl.md, section 4.
fn bool near(float a, float b, float tolerance) @inline => math::abs(a - b) <= tolerance;

fn void neutral_is_the_identity() @test
{
	kelvin::Rgb w = kelvin::rgb(kelvin::NEUTRAL);
	assert(w.r == 1.0f && w.g == 1.0f && w.b == 1.0f, "6500 K is (1, 1, 1)");
}

fn void every_row_has_a_channel_at_full_scale() @test
{
	for (usz row = 0; row < kelvin::TABLE_ROWS; row++)
	{
		float r       = kelvin::BLACKBODY[row * 3];
		float g       = kelvin::BLACKBODY[row * 3 + 1];
		float b       = kelvin::BLACKBODY[row * 3 + 2];
		float largest = math::max(r, math::max(g, b));
		assert(largest == 1.0f, "every row is normalised so its largest channel is 1");
	}
}

fn void matches_the_reference_at_2700_6500_and_10000() @test
{
	// wlsunset: 2700 K -> (1.0000, 0.6726, 0.3519)
	kelvin::Rgb warm = kelvin::rgb((Kelvin)2700);
	assert(warm.r == 1.0f, "warm light keeps red at full scale");
	assert(near(warm.g, 0.6726f, 0.01f), "2700 K green within 0.01 of wlsunset");
	assert(near(warm.b, 0.3519f, 0.01f), "2700 K blue within 0.01 of wlsunset");
	// wlsunset: 6500 K -> (1.0000, 1.0000, 1.0000)
	kelvin::Rgb neutral = kelvin::rgb((Kelvin)6500);
	assert(near(neutral.g, 1.0f, 0.0f) && near(neutral.b, 1.0f, 0.0f), "6500 K agrees with wlsunset");
	// wlsunset: 10000 K -> (0.7851, 0.8617, 1.0000)
	kelvin::Rgb cool = kelvin::rgb((Kelvin)10000);
	assert(near(cool.r, 0.7851f, 0.01f), "10000 K red within 0.01 of wlsunset");
	assert(near(cool.g, 0.8617f, 0.01f), "10000 K green within 0.01 of wlsunset");
	assert(cool.b == 1.0f, "10000 K keeps blue at full scale");
}

fn void interpolates_linearly_between_rows() @test
{
	// 2750 K is halfway between the 2700 K and 2800 K rows.
	usz low         = 17;
	usz high        = 18;
	kelvin::Rgb mid = kelvin::rgb((Kelvin)2750);
	assert(near(
		mid.g,
		(kelvin::BLACKBODY[low * 3 + 1] + kelvin::BLACKBODY[high * 3 + 1]) / 2.0f,
		1e-6f
	), "green is the average");
	assert(near(
		mid.b,
		(kelvin::BLACKBODY[low * 3 + 2] + kelvin::BLACKBODY[high * 3 + 2]) / 2.0f,
		1e-6f
	), "blue is the average");
}

fn void clamps_outside_the_table() @test
{
	kelvin::Rgb coolest = kelvin::rgb(kelvin::MIN);
	kelvin::Rgb below   = kelvin::rgb((Kelvin)500);
	assert(below.r == coolest.r && below.g == coolest.g && below.b == coolest.b, "below 1000 K is 1000 K");
	kelvin::Rgb warmest = kelvin::rgb(kelvin::MAX);
	kelvin::Rgb above   = kelvin::rgb((Kelvin)40000);
	assert(above.r == warmest.r && above.g == warmest.g && above.b == warmest.b, "above 25000 K is 25000 K");
}

fn void warmer_lowers_blue_then_cooler_lowers_red() @test
{
	// Along the table, blue never falls as the temperature rises, and red never rises above 6500 K.
	float previous_blue = 0.0f;
	float previous_red  = 1.0f;
	for (Kelvin t = kelvin::MIN; t <= kelvin::MAX; t += kelvin::STEP)
	{
		kelvin::Rgb w = kelvin::rgb(t);
		assert(w.b >= previous_blue - 1e-6f, "blue is non-decreasing with temperature");
		previous_blue = w.b;
		if (t > kelvin::NEUTRAL)
		{
			assert(w.r <= previous_red + 1e-6f, "red is non-increasing above 6500 K");
			previous_red = w.r;
		}
	}
}