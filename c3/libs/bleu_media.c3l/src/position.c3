<*
 Extrapolating a player's position between reads.

 Players do not push their position on Linux (MPRIS sends no change signal for
 it) and on Windows they push it only with a timestamp. So every read is an
 anchor, and the position at any later moment is computed from it:

 playing, rate != 0 : anchor.position + (now - anchor.taken_at) * rate
 paused, or rate 0  : anchor.position
 stopped            : 0

 The result is clamped to [0, length] when the length is known. Quickshell and
 the Rust `mpris` crate do not clamp; this one does, because a position past
 the end of a track is never a true position.
*>
module bleu::media;
import std::collections::maybe, std::time, std::time::clock;

<*
 The service's monotonic clock in microseconds. Anchors are stamped with it,
 and `Player.position_now` expects its `now` on the same clock.
*>
fn Duration monotonic_now() => (Duration)((ulong)clock::now() / NANOS_PER_MICRO);

const ulong NANOS_PER_MICRO = 1000;

// The largest position the arithmetic produces: about 285 years, far beyond any track. Bounds the float-to-integer cast.
const double MAX_POSITION_US = 9.0e15;

// How far a fresh reading may differ from the extrapolated position before the anchor is replaced (500 ms).
const Duration DRIFT_TOLERANCE = (Duration)500_000;

<*
 A playback rate made safe for arithmetic: NaN and infinities become normal speed,
 and a magnitude beyond `MAX_RATE` is clamped. Peers report rates; nothing else
 should trust them.
*>
fn PlaybackRate sane_rate(PlaybackRate rate)
{
	// For a finite value `rate - rate` is 0; for NaN and the infinities it is NaN.
	if (rate - rate != 0.0) return 1.0;
	if (rate > MAX_RATE) return MAX_RATE;
	if (rate < -MAX_RATE) return -MAX_RATE;
	return rate;
}

<*
 The position of a player at `now`, from its anchor.

 @param anchor : "The last reading of the position and when it was taken"
 @param status : "Playing, paused or stopped, as of the anchor's reading"
 @param rate : "Playback speed; 0 is treated as paused; made safe by `sane_rate`"
 @param length : "Track length, when known; the result never exceeds it"
 @param now : "The current monotonic time, from `monotonic_now`"
*>
fn Duration position_at(Anchor anchor, Playback status, PlaybackRate rate, Maybe{Duration} length, Duration now)
{
	double at    = status == STOPPED ? 0.0 : (double)anchor.position;
	double speed = sane_rate(rate);
	if (status == PLAYING && speed != 0.0)
	{
		// A clock that went backwards (the anchor is from after `now`) counts as no time elapsed.
		double elapsed = now > anchor.taken_at ? (double)(now - anchor.taken_at) : 0.0;
		at += elapsed * speed;
	}
	// Clamp in floating point, before the integer conversion, so no out-of-range value reaches it.
	if (at < 0.0) at = 0.0;
	if (at > MAX_POSITION_US) at = MAX_POSITION_US;
	Duration result = (Duration)(long)at;
	if (length.has_value && result > length.value) result = length.value;
	return result;
}

<*
 Whether a fresh reading `fresh` should replace the anchor `current`. It should
 only when the anchor no longer predicts where the player is, by more than
 `DRIFT_TOLERANCE`: a reading that agrees leaves the state unchanged, so
 consumers are not woken for nothing.
*>
fn bool needs_reanchor(Maybe{Anchor} current, Anchor fresh, Playback status, PlaybackRate rate, Maybe{Duration} length)
{
	if (!current.has_value) return true;
	Duration predicted = position_at(current.value, status, rate, length, fresh.taken_at);
	Duration drift     = fresh.position > predicted ? fresh.position - predicted : predicted - fresh.position;
	return drift > DRIFT_TOLERANCE;
}

<*
 Where the player is at `now`, or nothing when the player has never reported
 a position.

 @param now : "The current monotonic time, from `monotonic_now`"
*>
fn Maybe{Duration} Player.position_now(&self, Duration now)
{
	if (!self.position.has_value) return { };
	return maybe::value(position_at(self.position.value, self.status, self.rate, self.track.length, now));
}