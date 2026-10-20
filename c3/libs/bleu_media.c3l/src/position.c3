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

<*
 The position of a player at `now`, from its anchor.

 @param anchor : "The last reading of the position and when it was taken"
 @param status : "Playing, paused or stopped, as of the anchor's reading"
 @param rate : "Playback speed; 0 is treated as paused"
 @param length : "Track length, when known; the result never exceeds it"
 @param now : "The current monotonic time, from `monotonic_now`"
*>
fn Duration position_at(Anchor anchor, Playback status, PlaybackRate rate, Maybe{Duration} length, Duration now)
{
	Duration at = anchor.position;
	if (status == STOPPED) at = 0;
	if (status == PLAYING && (double)rate != 0.0)
	{
		// A clock that went backwards (the anchor is from after `now`) counts as no time elapsed.
		Duration elapsed = now > anchor.taken_at ? now - anchor.taken_at : 0;
		at = anchor.position + (Duration)((double)elapsed * (double)rate);
	}
	if (at < 0) at = 0;
	if (length.has_value && at > length.value) at = length.value;
	return at;
}

<*
 Where the player is at `now`, or nothing when the player has never reported
 a position.

 @param now : "The current monotonic time, from `monotonic_now`"
*>
fn Maybe{Duration} Player.position_now(&self, Duration now)
{
	if (!self.position.has_value) return {};
	return maybe::value(position_at(self.position.value, self.status, self.rate, self.track.length, now));
}
