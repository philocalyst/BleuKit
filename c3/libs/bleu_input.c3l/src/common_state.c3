<*
 Helpers every backend uses: publishing a snapshot with its change events, finishing a switch, and
 finding a layout by id. Platform-neutral; runs on the worker thread.
*>
module bleu::input;
import bleu::error, bleu::observe, bleu::service, bleu::operation, bleu::equal, bleu::rt::worker;

alias InputHub = Hub{State, Command, Event};

<*
 The position of the layout called `id` in `layouts`, or -1 when there is none.
*>
fn sz index_of(Layout[] layouts, String id)
{
	foreach (i, &layout : layouts)
	{
		if (layout.id == id) return (sz)i;
	}
	return -1;
}

<*
 The id of the active layout in `state`, "" when none is known.
*>
fn String current_id(State* state)
{
	if (!state.current.has_value) return "";
	uint index = state.current.value;
	if (index >= state.layouts.len) return "";
	return state.layouts[index].id;
}

<*
 Publish `snapshot` if it differs from the latest one, announcing the changes as events first. A
 snapshot equal to the latest is dropped. Consumes the caller's reference either way.
*>
fn void publish_state(InputHub* hub, Snapshot{State}* snapshot)
{
	if (try previous = hub.latest())
	{
		defer previous.release();
		if (equal::deep(previous.value, snapshot.value))
		{
			snapshot.release();
			return;
		}
		// Publish first, then announce: a subscriber woken by an event must find the new state. Our own
		// reference is kept for the comparison the announcement makes.
		snapshot.retain();
		hub.publish(snapshot);
		announce(hub, &previous.value, &snapshot.value);
		snapshot.release();
		return;
	}
	hub.publish(snapshot);
}

// The transients that turn `before` into `after`.
fn void announce(InputHub* hub, State* before, State* after) @private
{
	if (!equal::deep(before.layouts, after.layouts)) emit(hub, LAYOUTS_CHANGED, "");
	String now = current_id(after);
	if (!equal::deep(current_id(before), now)) emit(hub, CURRENT_CHANGED, now);
}

fn void emit(InputHub* hub, EventKind kind, String layout_id) @private
{
	Snapshot{Event}* packet = hub.emit_begin();
	packet.value = { .kind = kind, .layout_id = layout_id.copy(packet.allocator()) };
	hub.emit(packet);
}

<* Complete a switch as handed over. Releases the worker's reference. *>
fn void succeed_switch(SwitchOperation* operation, SwitchOutcome outcome)
{
	operation.succeed(outcome);
	operation.release();
}

<* Complete a switch with the fault it failed with. Releases the worker's reference. *>
fn void fail_switch(SwitchOperation* operation, fault failure)
{
	operation.fail(failure);
	operation.release();
}

<*
 Whether a backend's switch route, once connected, can change the layout here: the layout list must
 hold two or more entries for "next" to mean anything.
*>
fn bool can_switch_now(bool route_open, sz layout_count) => route_open && layout_count > 1;
<*
 Complete a request the worker did not run, when the backend stops or bails out before taking it: a
 switch fails with CANCELLED, so no caller waits for an operation nobody will run. Registered with
 `Hub.start`; runs on the worker thread after the backend's run function has returned.
*>
fn void abandon_command(void* backend, Command* command)
{
	if (command.kind != CommandKind.SWITCH_TO) return;
	fail_switch(
		command.operation,
		error::raise(error::CANCELLED, error::Domain.INTERNAL, 0, "the service closed before the request ran")
	);
}