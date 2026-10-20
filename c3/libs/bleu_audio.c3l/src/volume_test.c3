// Volume conversions, against the figures in the research (section 2.1.5) and
// the balance examples in PulseAudio's pa_cvolume_get_balance comments.
module bleu::audio::volume_test;
import bleu::audio, bleu::audio::volume, bleu::audio::pulse, bleu::unit, std::math, std::collections::maybe;

fn bool close(float a, float b, float tolerance) @private => math::abs(a - b) <= tolerance;

fn void raw_volumes_map_to_the_slider() @test
{
	assert(pulse::raw_from_gain((Gain)0.5f) == 32768, "50 % is 32768");
	assert(pulse::raw_from_gain((Gain)1.0f) == 65536, "100 % is VOLUME_NORM");
	assert(pulse::raw_from_gain((Gain)1.5f) == 98304, "over-amplification is representable");
	assert(pulse::raw_from_gain((Gain)1.0e9f) == pulse::VOLUME_MAX, "clamped to VOLUME_MAX");
	assert(pulse::raw_from_gain((Gain)-1.0f) == pulse::VOLUME_MUTED, "negative is silence");
	assert(pulse::gain_from_raw(
		52057
	) > (Gain)0.7943f && pulse::gain_from_raw(52057) < (Gain)0.7945f, "79.4 % is 52057");
}

fn void decibels_follow_the_cubic_mapping() @test
{
	// 50 % is amplitude 0.125 = -18.06 dB (research 2.1.5, PulseAudio volume.c:236-291).
	assert(close((float)volume::decibels((Gain)0.5f), -18.06f, 0.01f), "50 % is -18.06 dB");
	assert(close((float)volume::decibels(volume::NOMINAL), 0.0f, 0.0001f), "100 % is 0 dB");
	assert(close((float)volume::decibels(pulse::gain_from_raw(52057)), -6.0f, 0.02f), "79.4 % is -6 dB");
	assert(volume::decibels((Gain)0.0f) == volume::DECIBEL_SILENCE, "silence has the floor");
}

fn void decibels_and_slider_round_trip() @test
{
	assert(close((float)volume::from_decibels((Decibel)-18.0618f), 0.5f, 0.001f), "-18.06 dB is 50 %");
	assert(close((float)volume::from_decibels(volume::decibels((Gain)1.2f)), 1.2f, 0.0005f), "120 % round trips");
	assert((float)volume::from_decibels(volume::DECIBEL_SILENCE) == 0.0f, "the floor is silence");
}

fn void amplitude_is_the_cube() @test
{
	assert(close(volume::amplitude((Gain)0.5f), 0.125f, 0.00001f), "0.5 cubed");
	assert(close((float)volume::from_amplitude(0.125f), 0.5f, 0.0001f), "cube root");
	assert((float)volume::from_amplitude(-1.0f) == 0.0f, "negative amplitude is silence");
}

// Build a stereo volume and its map (front left, front right) and check the balance.
fn Maybe{float} stereo_balance(uint left, uint right) @private
{
	CVolume volume = { .count = 2 };
	volume.values[0] = left;
	volume.values[1] = right;
	ChannelMap map = { .count = 2 };
	map.positions[0] = pulse::POSITION_FRONT_LEFT;
	map.positions[1] = pulse::POSITION_FRONT_RIGHT;
	return pulse::balance_of(&volume, &map);
}

// The examples from pa_cvolume_get_balance (pulse/volume.c:691-713).
fn void balance_matches_the_pulseaudio_examples() @test
{
	assert(close(stereo_balance(65536, 0).value, -1.0f, 0.0001f), "all left is -1");
	assert(close(stereo_balance(0, 65536).value, 1.0f, 0.0001f), "all right is +1");
	assert(close(stereo_balance(32768, 32768).value, 0.0f, 0.0001f), "equal is 0");
	assert(close(stereo_balance(65536, 32768).value, -0.5f, 0.0001f), "1.0, 0.5 is -0.5");
	assert(close(stereo_balance(65536, 16384).value, -0.75f, 0.0001f), "1.0, 0.25 is -0.75");
	assert(close(stereo_balance(16384, 65536).value, 0.75f, 0.0001f), "0.25, 1.0 is +0.75");
}

fn void mono_has_no_balance() @test
{
	CVolume volume = { .count = 1 };
	volume.values[0] = 65536;
	ChannelMap map = { .count = 1 };
	map.positions[0] = 0;
	assert(!pulse::balance_of(&volume, &map).has_value);
}