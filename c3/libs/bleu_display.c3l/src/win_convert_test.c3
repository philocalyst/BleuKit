module bleu::display::win_convert_test;
import bleu::display, bleu::display::win_convert;

fn void rotations_map_both_ways() @test
{
	assert(win_convert::transform_from_rotation(win_convert::ROTATION_IDENTITY) == display::Transform.NORMAL);
	assert(win_convert::transform_from_rotation(win_convert::ROTATION_270) == display::Transform.R270);
	uint rotation = 0;
	assert(win_convert::rotation_of(display::Transform.R180, &rotation) && rotation == win_convert::ROTATION_180);
	assert(!win_convert::rotation_of(display::Transform.FLIPPED, &rotation));
}

fn void ntsc_rates_keep_their_fraction() @test
{
	// 60000/1001 Hz is 59.94 Hz: 59940 mHz after rounding, not 60000.
	assert(win_convert::refresh_from_fraction(60000, 1001) == 59940);
	assert(win_convert::refresh_from_fraction(60, 1) == 60000);
	assert(win_convert::refresh_from_fraction(1, 0) == 0);
	win_convert::Fraction f = win_convert::fraction_from_refresh(59940);
	assert(win_convert::refresh_from_fraction(f.numerator, f.denominator) == 59940);
}