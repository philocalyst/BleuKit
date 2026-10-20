<*
 System Media Transport Controls values converted to the media model. Pure: no
 COM, no clock. The Windows backend reads the values (`smtc_backend.c3`); this
 file decides what they mean.

 Sources (windows-rs 0.62.2, the bindings of the Windows Runtime types; the
 numbers are the metadata values):
 * `GlobalSystemMediaTransportControlsSessionPlaybackStatus`: Closed 0, Opened 1,
 Changing 2, Stopped 3, Playing 4, Paused 5 (`src/Windows/Media/Control/mod.rs`).
 * `MediaPlaybackAutoRepeatMode`: None 0, Track 1, List 2 (`src/Windows/Media/mod.rs`).
 * `TimeSpan` is a count of 100-nanosecond ticks; `DateTime.UniversalTime` counts
 100-nanosecond ticks from 1601-01-01 UTC (Microsoft Learn, "DateTime structure"
 for the Windows Runtime `Windows.Foundation.DateTime`).
 * The 1601 to 1970 offset is 11644473600 seconds (Microsoft Learn, "FILETIME").
*>
module bleu::media::smtc_convert;
import std::time, bleu::media;

const int STATUS_STOPPED                 = 3;
const int STATUS_PLAYING                 = 4;
const int STATUS_PAUSED                  = 5;
const int REPEAT_TRACK                   = 1;
const int REPEAT_LIST                    = 2;
const long TICKS_PER_MICRO               = 10;
const long UNIX_EPOCH_IN_MICRO_FROM_1601 = 11644473600000000;

<* The `SessionPlaybackStatus` value as a status. Anything but playing or paused is stopped. *>
fn Playback playback_of_status(int status)
{
	switch (status)
	{
		case STATUS_PLAYING: return Playback.PLAYING;
		case STATUS_PAUSED: return Playback.PAUSED;
		default: return Playback.STOPPED;
	}
}

<* The `MediaPlaybackAutoRepeatMode` value as a loop mode. *>
fn Loop loop_of_repeat(int mode)
{
	switch (mode)
	{
		case REPEAT_TRACK: return Loop.TRACK;
		case REPEAT_LIST: return Loop.PLAYLIST;
		default: return Loop.NONE;
	}
}

<* The `MediaPlaybackAutoRepeatMode` value for a loop mode. *>
fn int repeat_of_loop(Loop loop)
{
	switch (loop)
	{
		case Loop.NONE: return 0;
		case Loop.TRACK: return REPEAT_TRACK;
		case Loop.PLAYLIST: return REPEAT_LIST;
	}
}

<* A `TimeSpan` or `DateTime` tick count as microseconds (ticks are 100 ns). *>
fn Duration micros_of_ticks(long ticks) => (Duration)(ticks / TICKS_PER_MICRO);

<* A tick count in the `TimeSpan` form that the session methods take. *>
fn long ticks_of_micros(Duration micros) => (long)micros * TICKS_PER_MICRO;

// The oldest `LastUpdatedTime` that still describes a playing session (one day, microseconds).
const Duration MAX_STAMP_AGE = (Duration)86_400_000_000;

<*
 How long ago a `LastUpdatedTime` (a `DateTime` in ticks since 1601) was, in
 microseconds, against the wall clock `now_unix_us` (microseconds since 1970).
 A stamp that cannot be a reading is unknown and counts as no age, so the
 position is anchored at the reading time: a stamp before 1970 (a zero or unset
 value is 1601), one in the future, or one older than `MAX_STAMP_AGE`.
*>
fn Duration age_of(long last_updated_ticks, Time now_unix_us)
{
	Duration stamped_unix_us = micros_of_ticks(last_updated_ticks) - UNIX_EPOCH_IN_MICRO_FROM_1601;
	if (stamped_unix_us <= time::DURATION_ZERO) return time::DURATION_ZERO;
	Duration age = (Duration)now_unix_us - stamped_unix_us;
	if (age < time::DURATION_ZERO || age > MAX_STAMP_AGE) return time::DURATION_ZERO;
	return age;
}

<* The controls a session reports, as the backend reads them. *>
struct ReportedControls
{
	bool play;
	bool pause;
	bool toggle;
	bool stop;
	bool next;
	bool previous;
	bool position;
	bool rate;
	bool shuffle;
	bool repeat;
}

<*
 The model's controls from what a session reports. SMTC has no volume, raise
 or quit, so those stay false; play-pause is offered when any of play, pause or
 the toggle is.
*>
fn Controls controls_of(ReportedControls r)
{
	return {
		.play = r.play,
		.pause = r.pause,
		.play_pause = r.toggle || r.play || r.pause,
		.stop = r.stop,
		.next = r.next,
		.previous = r.previous,
		.seek = r.position,
		.set_position = r.position,
		.set_rate = r.rate,
		.set_shuffle = r.shuffle,
		.set_loop = r.repeat,
	};
}