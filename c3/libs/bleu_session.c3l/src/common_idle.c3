<*
 Idle thresholds as the worker tracks them, for the backends that measure idle time
 themselves (macOS and Windows). Pure logic: the backend measures the time since the last
 input, and this file decides which IDLE and RESUMED edges that causes.

 A slot is either one of `Options.idle_thresholds` (`configured`, reported in `State.idle`)
 or the threshold of an `IdleWatch` (`watch` is its id). An edge fires when the idle time
 first reaches the threshold, and again when input resets it below the threshold: the same
 alternation that `ext-idle-notify` gives.
*>
module bleu::session;
import std::collections::list, std::time;

<* One threshold the worker watches. *>
struct IdleSlot
{
	ulong watch;
	Duration threshold;
	bool idle;
	bool configured;
}

<* The slots of one worker. Owned by the worker thread. *>
struct IdleRegistry
{
	List{IdleSlot} slots;
}

<* Whether `elapsed` idle time has reached `threshold`. *>
fn bool reached(Duration elapsed, Duration threshold) @inline => elapsed >= threshold;

<*
 Start with one configured slot per threshold, in the order given.

 @param allocator : "Where the slots live until `free`"
 @param thresholds : "The idle thresholds of `Options.idle_thresholds`"
*>
fn void IdleRegistry.init(&self, Allocator allocator, Duration[] thresholds)
{
	self.slots.init(allocator);
	foreach (threshold : thresholds) self.slots.push({ .threshold = threshold, .configured = true });
}

<* Release the slots. *>
fn void IdleRegistry.free(&self) => self.slots.free();

<*
 Start or stop an idle watch. Commands of other kinds are ignored.

 @param command : "A WATCH_IDLE or UNWATCH_IDLE command"
*>
fn void IdleRegistry.apply(&self, Command* command)
{
	if (command.kind == CommandKind.WATCH_IDLE)
	{
		self.slots.push({ .watch = command.watch, .threshold = command.threshold });
		return;
	}
	if (command.kind != CommandKind.UNWATCH_IDLE) return;
	for (sz i = self.slots.len() - 1; i >= 0; i--)
	{
		IdleSlot slot = self.slots.get(i);
		if (!slot.configured && slot.watch == command.watch) self.slots.remove_at(i);
	}
}

<*
 Compare every slot with the idle time `elapsed`, and record an IDLE or RESUMED event for each
 that changed state. The caller announces them after publishing.

 @param pending : "Where the events are appended"
*>
fn void IdleRegistry.advance(&self, Duration elapsed, List{Event}* pending)
{
	for (sz i = 0; i < self.slots.len(); i++)
	{
		IdleSlot* slot = self.slots.get_ref(i);
		bool now = reached(elapsed, slot.threshold);
		if (now == slot.idle) continue;
		slot.idle = now;
		pending.push({ .kind = now ? EventKind.IDLE : EventKind.RESUMED, .watch = slot.watch, .threshold = slot.threshold });
	}
}

const double MICROSECONDS_PER_SECOND = 1.0e6;

<*
 A duration from seconds as a platform reports them. A negative reading (a clock that stepped
 back) is zero: the idle time cannot be negative.
*>
fn Duration duration_of_seconds(double seconds)
{
	if (seconds <= 0.0) return time::DURATION_ZERO;
	return (Duration)(seconds * MICROSECONDS_PER_SECOND);
}

<* A duration in seconds, as a platform API takes it. *>
fn double seconds_of(Duration duration) => (double)duration / MICROSECONDS_PER_SECOND;

<*
 The configured thresholds and whether each is reached, in `Options.idle_thresholds` order.

 @param allocator : "Where the result lives (the snapshot's arena)"
*>
fn IdleStatus[] IdleRegistry.statuses(&self, Allocator allocator)
{
	sz count = 0;
	for (sz i = 0; i < self.slots.len(); i++)
	{
		if (self.slots.get(i).configured) count++;
	}
	if (count == 0) return {};
	IdleStatus[] statuses = alloc::new_array(allocator, IdleStatus, count);
	sz next = 0;
	for (sz i = 0; i < self.slots.len(); i++)
	{
		IdleSlot slot = self.slots.get(i);
		if (!slot.configured) continue;
		statuses[next++] = { .threshold = slot.threshold, .idle = slot.idle };
	}
	return statuses;
}
