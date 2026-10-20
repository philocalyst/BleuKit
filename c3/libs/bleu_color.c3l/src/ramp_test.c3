module bleu::color::ramp_test;
import bleu::error, bleu::unit, bleu::color::kelvin, bleu::color::ramp, std::math;

fn bool near(float a, float b, float tolerance) @inline => math::abs(a - b) <= tolerance;

fn void identity_ramp_is_linear_at_any_size() @test
{
	usz[3] sizes = { 2, 17, 256 };
	foreach (size : sizes)
	{
		float[768] storage;
		float[] buffer = storage[0 : 3 * size];
		ramp::fill(buffer, size, kelvin::NEUTRAL, (Level)1.0f, 1.0)!!;
		for (usz channel = 0; channel < 3; channel++)
		{
			for (usz i = 0; i < size; i++)
			{
				float expected = (float)i / (float)(size - 1);
				assert(near(buffer[channel * size + i], expected, 1e-6f), "6500 K, brightness 1 and gamma 1 is the identity");
			}
		}
	}
}

fn void brightness_scales_every_entry() @test
{
	float[768] storage;
	float[] buffer = storage[..];
	ramp::fill(buffer, 256, kelvin::NEUTRAL, (Level)0.5f, 1.0)!!;
	assert(near(buffer[255], 0.5f, 1e-6f), "full scale halves at brightness 0.5");
	assert(near(buffer[256 + 128], 0.5f * 128.0f / 255.0f, 1e-6f), "green is halved too");
}

fn void gamma_exponent_applies_after_brightness() @test
{
	float[768] storage;
	float[] buffer = storage[..];
	ramp::fill(buffer, 256, kelvin::NEUTRAL, (Level)1.0f, 2.2)!!;
	float expected = (float)math::pow(128.0 / 255.0, 1.0 / 2.2);
	assert(near(buffer[128], expected, 1e-5f), "output is x^(1/gamma)");
}

fn void warm_ramp_ends_at_the_table_multipliers() @test
{
	float[768] storage;
	float[] buffer = storage[..];
	ramp::fill(buffer, 256, (Kelvin)2700, (Level)1.0f, 1.0)!!;
	kelvin::Rgb w = kelvin::rgb((Kelvin)2700);
	assert(near(buffer[255], w.r, 1e-6f), "red full scale is the multiplier");
	assert(near(buffer[511], w.g, 1e-6f), "green full scale is the multiplier");
	assert(near(buffer[767], w.b, 1e-6f), "blue full scale is the multiplier");
}

fn void rejects_bad_shapes() @test
{
	float[768] storage;
	float[] buffer = storage[..];
	assert(@catch(ramp::fill(buffer, 1, kelvin::NEUTRAL, (Level)1.0f, 1.0)) == error::INVALID_ARGUMENT, "one entry is not a ramp");
	assert(@catch(ramp::fill(buffer, 255, kelvin::NEUTRAL, (Level)1.0f, 1.0)) == error::INVALID_ARGUMENT, "buffer must hold three tables");
	assert(@catch(ramp::fill(buffer, 256, kelvin::NEUTRAL, (Level)1.0f, 0.0)) == error::INVALID_ARGUMENT, "gamma must be positive");
}

fn void encodes_to_sixteen_bits() @test
{
	float[5] values = { 0.0f, 1.0f, 0.5f, 2.0f, -0.5f };
	ushort[5] words;
	ramp::encode_u16(values[..], words[..])!!;
	assert(words[0] == 0 && words[1] == 65535, "full scale is 65535");
	assert(words[2] == 32768, "one half rounds to 32768");
	assert(words[3] == 65535 && words[4] == 0, "out-of-range values are clamped");
}
