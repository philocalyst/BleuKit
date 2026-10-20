<*
 The state of a backend that measures what it needs itself (macOS and Windows): the lock state
 and the sleep state it observes, the idle thresholds it watches, and the changes recorded
 since the last snapshot.

 The worker records what it sees (a poll, a notification, a window message) with `record` and
 `observe_idle`, then calls `settle`, which applies the changes, publishes one snapshot and
 announces the events. Recording a change the state already has does nothing, so a repeated
 notification does not produce a repeated event.
*>
module bleu::session;
import std::collections::list, std::collections::maybe, std::time, bleu::observe;

<* The worker-owned state of a polling backend. *>
struct Polled
{
	Maybe{bool} locked;
	bool sleeping;
	IdleRegistry idle;
	List{Event} pending;
}

<*
 Start with the given idle thresholds configured.

 @param allocator : "Where the slots and events live until `free`"
 @param thresholds : "The idle thresholds of `Options.idle_thresholds`"
*>
fn void Polled.init(&self, Allocator allocator, Duration[] thresholds)
{
	self.idle.init(allocator, thresholds);
	self.pending.init(allocator);
}

<* Release the slots and the pending events. *>
fn void Polled.free(&self)
{
	self.idle.free();
	self.pending.free();
}

<*
 Record a change: LOCKED, UNLOCKED, WILL_SLEEP or DID_WAKE. It is ignored when the state, counting
 the changes already recorded, has that value.
*>
fn void Polled.record(&self, EventKind kind)
{
	bool lock    = kind == EventKind.LOCKED || kind == EventKind.UNLOCKED;
	bool target  = kind == EventKind.LOCKED || kind == EventKind.WILL_SLEEP;
	bool known   = lock ? self.locked.has_value : true;
	bool current = lock ? self.locked.has_value && self.locked.value : self.sleeping;
	// The latest recorded change of the same pair decides the value the state will have.
	for (sz i = self.pending.len(); i > 0; i--)
	{
		EventKind recorded = self.pending.get(i - 1).kind;
		bool same_pair     = lock ? recorded == EventKind.LOCKED || recorded == EventKind.UNLOCKED
			: recorded == EventKind.WILL_SLEEP || recorded == EventKind.DID_WAKE;
		if (!same_pair) continue;
		known = true;
		current = recorded == EventKind.LOCKED || recorded == EventKind.WILL_SLEEP;
		break;
	}
	if (known && current == target) return;
	self.pending.push({ .kind = kind });
}

<* Advance the idle thresholds to the idle time `elapsed`, recording the edges. *>
fn void Polled.observe_idle(&self, Duration elapsed) => self.idle.advance(elapsed, &self.pending);

<* Apply a WATCH_IDLE or UNWATCH_IDLE command to the thresholds. *>
fn void Polled.apply_command(&self, Command* command) => self.idle.apply(command);

<*
 Apply the recorded changes, publish the state, and announce the events.

 @param current_id : "The id of the session this process runs in; \"\" when the platform has none"
*>
fn void Polled.settle(&self, SessionHub* hub, String current_id)
{
	apply_pending(&self.pending, &self.locked, &self.sleeping);
	Snapshot{State}* snapshot = hub.begin();
	snapshot.value = {
		.locked = self.locked,
		.sleeping = self.sleeping,
		.current = { .id = current_id.len > 0 ? current_id.copy(snapshot.allocator()) : "" },
		.idle = self.idle.statuses(snapshot.allocator()),
	};
	hub.publish_if_changed(snapshot);
	announce(&self.pending, hub);
}