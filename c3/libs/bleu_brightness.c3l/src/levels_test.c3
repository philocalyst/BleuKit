module bleu::brightness::levels_test;
import std::collections::maybe, std::time, bleu::brightness, bleu::unit;

fn void ramp_interpolates_in_time() @test
{
	Level half = brightness::ramp_level((Level)0.0f, (Level)1.0f, (Duration)50_000, (Duration)100_000);
	assert((float)half > 0.49f && (float)half < 0.51f, "halfway through a ramp is halfway between the levels");
	assert((float)brightness::ramp_level((Level)0.2f, (Level)0.8f, time::DURATION_ZERO, (Duration)100_000) == 0.2f);
	assert((float)brightness::ramp_level((Level)0.2f, (Level)0.8f, (Duration)100_000, (Duration)100_000) == 0.8f);
	assert((float)brightness::ramp_level((Level)0.2f, (Level)0.8f, (Duration)300_000, (Duration)100_000) == 0.8f, "past the end is the target");
	assert((float)brightness::ramp_level((Level)0.2f, (Level)0.8f, (Duration)5, time::DURATION_ZERO) == 0.8f, "a zero ramp is the target at once");
}

fn void ramp_is_done_at_its_end() @test
{
	assert(!brightness::ramp_done((Duration)99_999, (Duration)100_000));
	assert(brightness::ramp_done((Duration)100_000, (Duration)100_000));
	assert(brightness::ramp_done(time::DURATION_ZERO, time::DURATION_ZERO));
}

fn void applied_reports_the_quantised_level() @test
{
	// 0.5 on a 0..96000 range is raw 48000; a 0..3 LED rounds 0.5 to 2/3 by raw 2.
	Applied a = brightness::applied_at(BACKLIGHT, (Level)0.5f, 48_000, 0, 96_000, { });
	assert(a.raw == 48_000 && a.mechanism == BACKLIGHT && !a.read_back.has_value);
	assert((float)a.applied > 0.49f && (float)a.applied < 0.51f);
	Applied led = brightness::applied_at(KEYBOARD_LED, (Level)0.5f, 2, 0, 3, maybe::value((Level)0.66f));
	assert(led.raw == 2 && led.read_back.has_value);
	assert((float)led.applied > 0.66f && (float)led.applied < 0.67f, "the applied level is the raw value mapped back");
}

fn void same_level_compares_empties() @test
{
	assert(brightness::same_level({ }, { }));
	assert(!brightness::same_level(maybe::value((Level)0.1f), { }));
	assert(brightness::same_level(maybe::value((Level)0.1f), maybe::value((Level)0.1f)));
	assert(!brightness::same_level(maybe::value((Level)0.1f), maybe::value((Level)0.2f)));
}
