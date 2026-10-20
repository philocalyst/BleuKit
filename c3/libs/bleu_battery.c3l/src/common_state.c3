<*
 Rules shared by every platform backend: how a battery's charge state is named,
 how health and time-at-rate are computed, how a reading is classified, and what
 changed between two readings. Pure (no I/O), so every host runs the tests in
 `common_test.c3`.
*>
module bleu::battery;
import std::collections::list, std::collections::maybe, std::time, bleu::availability, bleu::unit;

<*
 The charge state of one battery from its mains connection and its flags.

 On mains: CHARGING, FULL, or NOT_CHARGING (plugged in and held, by a charge limit or
 heat). On battery: EMPTY at zero charge, otherwise DISCHARGING. The on-battery rule
 follows starship-battery 0.10.0 `darwin/device.rs`; the on-mains split is the same
 reading applied to the IOPowerSources and Windows flags.
*>
fn ChargeState charge_state(bool on_mains, bool charging, bool fully_charged, bool charge_is_zero)
{
	if (!on_mains) return charge_is_zero ? EMPTY : DISCHARGING;
	if (charging) return CHARGING;
	return fully_charged ? FULL : NOT_CHARGING;
}

<*
 Health as full capacity over design capacity, both in mWh. Empty when the design
 capacity is not reported.
*>
fn Maybe{Level} health_from(MilliWattHour full, MilliWattHour design)
{
	if (design <= (MilliWattHour)0) return { };
	return maybe::value(unit::from_ratio((double)full, (double)design));
}

<*
 Time to empty (discharging) or to full (charging) for `energy` mWh at a flow of
 `rate` mW in either direction. Empty when the flow is zero.
*>
fn Maybe{Duration} time_at_rate(MilliWattHour energy, MilliWatt rate)
{
	if (rate == (MilliWatt)0) return { };
	double magnitude = rate < (MilliWatt)0 ? -(double)rate : (double)rate;
	// mWh / mW = hours; the result is in microseconds.
	return maybe::value((Duration)((double)energy / magnitude * 3600.0 * 1.0e6));
}

<* Reading note: some devices could not be read and are left out of the sources. *>
const String DEGRADED_NOTE = "Some power sources could not be read and are left out";
<* Reading note: the newest read failed, so the sources are the last good reading. *>
const String STALE_NOTE = "The newest reading failed; the sources are the last good reading";

<*
 An available capability with a caveat: it works, and `note` says what does not.
 `availability::no` would read as unavailable, and `ok()` is true for DEGRADED.
*>
fn Availability degraded(String note) @inline => { .reason = availability::Reason.DEGRADED, .note = note };

<*
 The reading state after a read that left out `skipped` devices. AVAILABLE when none were skipped.
*>
fn Availability reading_after(usz skipped)
{
	if (skipped == 0) return availability::YES;
	return degraded(DEGRADED_NOTE);
}

<* The reading state of a state kept from the last good reading, after a failed read. *>
fn Availability stale_reading() @inline => availability::no(availability::Reason.BACKEND_STOPPED, STALE_NOTE);

<*
 Sort sources by id, so every snapshot lists them in the same order and equal states
 compare equal. Insertion sort: a machine has a handful of supplies or devices.
*>
fn void sort_by_id(Source[] sources)
{
	for (sz i = 1; i < sources.len; i++)
	{
		Source key = sources[i];
		sz j       = i - 1;
		while (j >= 0 && sources[j].id.compare_to(key.id) > 0)
		{
			sources[j + 1] = sources[j];
			j--;
		}
		sources[j + 1] = key;
	}
}

<* The source with `id` in `sources`, or null when there is none. *>
fn Source* find_source(Source[] sources, String id)
{
	foreach (&source : sources)
	{
		if (source.id == id) return source;
	}
	return null;
}

<*
 The transients between two readings, appended to `out`: a source that appeared or
 vanished, a mains line that changed, and a source whose charge state changed. The
 events borrow their `source_id` from the two states, so copy them before either is
 released. Pure: every backend publishes through this one diff.

 @param [&in] before : "The reading published last"
 @param [&in] after : "The reading about to be published"
 @param [&inout] out : "Receives the events in order"
*>
fn void changes(State* before, State* after, List{Event}* out)
{
	if (before.on_mains != after.on_mains)
	{
		out.push({ .kind = MAINS_CHANGED, .source_id = "" });
	}
	foreach (&old : before.sources)
	{
		Source* now = find_source(after.sources, old.id);
		if (now == null)
		{
			out.push({ .kind = SOURCE_REMOVED, .source_id = old.id });
			continue;
		}
		if (now.state != old.state)
		{
			out.push({ .kind = STATE_CHANGED, .source_id = now.id });
		}
	}
	foreach (&now : after.sources)
	{
		if (find_source(before.sources, now.id) == null)
		{
			out.push({ .kind = SOURCE_ADDED, .source_id = now.id });
		}
	}
}

// A copy of `text` in `allocator`; the empty string needs no allocation.
fn String copy_text(String text, Allocator allocator)
{
	if (text.len == 0) return "";
	return text.copy(allocator);
}

fn Source copy_source(Source* from, Allocator allocator)
{
	Source source = *from;
	source.id     = copy_text(from.id, allocator);
	source.vendor = copy_text(from.vendor, allocator);
	source.model  = copy_text(from.model, allocator);
	source.serial = copy_text(from.serial, allocator);
	return source;
}

<*
 A deep copy of `from` in `allocator`, so that a state can be published again after
 the snapshot it came from has been released.
*>
fn State copy_state(State* from, Allocator allocator)
{
	State state = { .on_mains = from.on_mains, .adapter_watts = from.adapter_watts, .reading = from.reading };
	if (from.sources.len == 0) return state;
	state.sources = alloc::new_array(allocator, Source, from.sources.len);
	foreach (i, &source : from.sources)
	{
		state.sources[i] = copy_source(source, allocator);
	}
	return state;
}
</content>
