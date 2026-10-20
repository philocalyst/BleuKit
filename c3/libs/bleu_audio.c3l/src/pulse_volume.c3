<*
 PulseAudio's volume integers and the balance derived from channel volumes.

 A server sends a volume as a u32 `pa_volume_t`: 0 is silence, 0x10000
 (VOLUME_NORM) is 100 % and the server accepts up to 0x7FFFFFFF
 (VOLUME_MAX; volume.h:117-139, volume.c:340-347 for balance). The slider
 position is value / VOLUME_NORM, which is the `Gain` the model carries.

 Balance follows pa_cvolume_get_balance (volume.c:691-713): the average volume of
 the left channels and of the right channels, then
 left > right  ->  -1 + right / left
 right > left  ->   1 - left / right
 equal         ->   0
 Sources: pulse/volume.c lines 691-713 and 555-561 (on_left, on_right).
 Deliberate difference: a map without a left or a right channel gives no
 balance (empty `Maybe`), where PulseAudio returns 0.0.
*>
module bleu::audio::pulse;
import std::collections::maybe, bleu::unit;

const uint VOLUME_NORM  = 0x10000;  // volume.h:120, 100 %
const uint VOLUME_MUTED = 0;        // volume.h:123, the volume of silence (not the mute flag)
const uint VOLUME_MAX   = 0x7FFFFFFF; // volume.h:126, UINT32_MAX / 2

// Channel positions (pulse/channelmap.h enum, in declaration order, MONO = 0).
const char POSITION_FRONT_LEFT            = 1;
const char POSITION_FRONT_RIGHT           = 2;
const char POSITION_REAR_LEFT             = 5;
const char POSITION_REAR_RIGHT            = 6;
const char POSITION_FRONT_LEFT_OF_CENTER  = 8;
const char POSITION_FRONT_RIGHT_OF_CENTER = 9;
const char POSITION_SIDE_LEFT             = 10;
const char POSITION_SIDE_RIGHT            = 11;

<* The slider position of a raw server volume. *>
fn Gain gain_from_raw(uint raw) @inline => (Gain)((float)raw / (float)VOLUME_NORM);

<*
 The raw server volume of a slider position: rounded to the nearest unit,
 clamped to 0..VOLUME_MAX. NaN is silence.
*>
fn uint raw_from_gain(Gain gain)
{
	if (gain != gain || gain <= (Gain)0.0f) return VOLUME_MUTED;
	float scaled = (float)gain * (float)VOLUME_NORM + 0.5f;
	if (scaled >= (float)VOLUME_MAX) return VOLUME_MAX;
	return (uint)scaled;
}

<* True for the channels pa_cvolume_get_balance averages on the left (volume.c:555). *>
fn bool is_left(char position) @inline
{
	return position == POSITION_FRONT_LEFT || position == POSITION_FRONT_LEFT_OF_CENTER
		|| position == POSITION_REAR_LEFT
		|| position == POSITION_SIDE_LEFT;
}

<* True for the channels pa_cvolume_get_balance averages on the right (volume.c:559). *>
fn bool is_right(char position) @inline
{
	return position == POSITION_FRONT_RIGHT || position == POSITION_FRONT_RIGHT_OF_CENTER
		|| position == POSITION_REAR_RIGHT
		|| position == POSITION_SIDE_RIGHT;
}

<*
 Balance of a channel volume over its map. Mono, or a map with no left or no
 right channel, has no balance.

 @param volume : "per-channel volumes as the server sent them"
 @param map : "channel positions, one per volume"
 @return "-1.0 (all left) .. +1.0 (all right); empty when there is none"
*>
fn Maybe{float} balance_of(CVolume* volume, ChannelMap* map)
{
	if (volume.count != map.count || map.count < 2) return { };
	uint left_sum    = 0;
	uint right_sum   = 0;
	uint left_count  = 0;
	uint right_count = 0;
	for (sz i = 0; i < (sz)map.count; i++)
	{
		if (is_left(map.positions[i]))
		{
			left_sum += volume.values[i];
			left_count++;
		}
		else if (is_right(map.positions[i]))
		{
			right_sum += volume.values[i];
			right_count++;
		}
	}
	if (left_count == 0 || right_count == 0) return { };
	uint left  = left_sum / left_count;
	uint right = right_sum / right_count;
	if (left == right) return maybe::value(0.0f);
	if (left > right) return maybe::value(-1.0f + (float)right / (float)left);
	return maybe::value(1.0f - (float)left / (float)right);
}