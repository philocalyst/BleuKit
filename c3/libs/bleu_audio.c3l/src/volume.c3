<*
 Converting the slider scale of `Gain` to amplitude and decibels.

 A `Gain` here is a slider position: 1.0 is the nominal 100 % position. PulseAudio
 maps it to amplitude with a cube, not a logarithm: amplitude = gain^3 and
 decibels = 20 * log10(amplitude) = 60 * log10(gain). So 50 % is an amplitude of
 0.125 (-18.06 dB), 79.4 % is -6.00 dB and 100 % is 0 dB
 (pulsecore/volume.c:236-291 and pulse/volume.c:260-291, read in the research).
 The other backends (CoreAudio, WASAPI) use their own slider scales; use the
 decibel value they report when they report one.
*>
module bleu::audio::volume;
import std::math, bleu::unit;

<* A level in decibels. Plain float; the scale is the usual dB scale. *>
typedef Decibel = float;

<*
 The decibel value reported for silence (amplitude zero). PulseAudio has its
 own "minus infinity" constant; its value was not read, so this is a floor.
*>
const Decibel DECIBEL_SILENCE = (Decibel)-150.0f;

<* The slider position of 0 dB: amplitude 1.0. *>
const Gain NOMINAL = (Gain)1.0f;

<*
 Decibels of a slider position. Zero and below are silence.

 @return "dB relative to nominal, DECIBEL_SILENCE for zero"
*>
fn Decibel decibels(Gain gain)
{
	if (gain <= (Gain)0.0f) return DECIBEL_SILENCE;
	return (Decibel)(60.0 * math::log10((double)gain));
}

<* Slider position of a decibel value (the inverse of `decibels`); values at or below the floor are silence. *>
fn Gain from_decibels(Decibel decibels)
{
	if (decibels <= DECIBEL_SILENCE) return (Gain)0.0f;
	return (Gain)math::pow(10.0, (double)decibels / 60.0);
}

<* Linear amplitude of a slider position: the cube of the position. *>
fn float amplitude(Gain gain) @inline => (float)gain * (float)gain * (float)gain;

<* Slider position of a linear amplitude: the cube root. Negative amplitudes are silence. *>
fn Gain from_amplitude(float linear)
{
	if (linear <= 0.0f) return (Gain)0.0f;
	return (Gain)math::pow((double)linear, 1.0 / 3.0);
}
