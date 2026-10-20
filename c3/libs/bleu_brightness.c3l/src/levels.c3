<*
 Pure arithmetic for levels: raw device numbers, the quantised value a write
 really produces, and the ramp of a smooth transition. No I/O.
*>
module bleu::brightness;
import std::collections::maybe, std::time, bleu::error, bleu::unit;

<*
 The result of writing `requested` to a control whose raw range is
 `raw_min`..`raw_max`: the raw value is `raw`, the level the device will show
 is `raw` mapped back, and `read_back` is what it reported afterwards.

 @require raw_max > raw_min : "The range must be non-degenerate"
*>
fn Applied applied_at(
	Mechanism mechanism,
	Level requested,
	long raw,
	long raw_min,
	long raw_max,
	Maybe{Level} read_back
)
{
	return {
		.mechanism = mechanism,
		.requested = requested,
		.applied = unit::from_raw(raw, raw_min, raw_max),
		.raw = raw,
		.read_back = read_back,
	};
}

<*
 The level a transition shows `elapsed` into a ramp of `total` from `from` to
 `to`. Linear in time; a zero or elapsed-out ramp is `to`.
*>
fn Level ramp_level(Level from, Level to, Duration elapsed, Duration total) @inline
{
	if (total <= time::DURATION_ZERO || elapsed >= total) return to;
	if (elapsed <= time::DURATION_ZERO) return from;
	return from.lerp(to, (float)(long)elapsed / (float)(long)total);
}

<*
 Whether `elapsed` is at or past the end of a ramp of `total`. A zero ramp is
 finished at once.
*>
fn bool ramp_done(Duration elapsed, Duration total) @inline => elapsed >= total;

<* Largest disagreement, in device steps, between a write and the device's own report that still counts as taken. *>
const long READ_BACK_TOLERANCE = 1;

<*
 Check the device's own report after a write: it must agree with the raw value written, to
 within `READ_BACK_TOLERANCE` steps. An empty report cannot disagree, because the device gave
 no answer to compare; such a control is written without a check.

 @return? error::BACKEND_FAILURE : "The device reports another value: it did not take the write"
*>
fn void? confirm_read_back(String device_id, long raw, long raw_min, long raw_max, Maybe{Level} read_back)
{
	if (!read_back.has_value) return;
	long reported   = read_back.value.to_raw(raw_min, raw_max);
	long difference = reported - raw;
	if (difference < 0) difference = -difference;
	if (difference > READ_BACK_TOLERANCE)
	{
		return error::raise(
			error::BACKEND_FAILURE,
			error::Domain.INTERNAL,
			0,
			"'%s' did not take the value: wrote %d, the device reports %d",
			device_id,
			raw,
			reported
		)~;
	}
}

<*
 Whether two levels are the same reading: both empty, or both present and equal.
*>
fn bool same_level(Maybe{Level} a, Maybe{Level} b) @inline
{
	if (a.has_value != b.has_value) return false;
	return !a.has_value || a.value == b.value;
}