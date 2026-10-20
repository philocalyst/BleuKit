<*
 Turning one published state into the next, and the events that describe the
 difference. Pure: the backends call `publish_changes` and the tests call
 `changes` on hand-built states.
*>
module bleu::windows;
import std::collections::list, bleu::equal, bleu::observe, bleu::stream, bleu::service;

<*
 Publish `next` if it differs from the latest state, then emit one event for
 each difference. Consumes the caller's reference to `next`, as `Hub.publish` does.

 A backend builds the complete state each time it reads the platform, so this
 is the only place that decides what changed.
*>
fn void publish_changes(WindowsHub* hub, Snapshot{State}* next)
{
	Snapshot{State}* before = null;
	if (try latest = hub.latest()) before = latest;
	if (before != null && equal::deep(before.value, next.value))
	{
		before.release();
		next.release();
		return;
	}
	// The first state is compared with nothing: every window and workspace is new.
	State nothing   = { .connection = DISCONNECTED };
	State* previous = before != null ? &before.value : &nothing;
	Event[] events  = changes(previous, &next.value, next.allocator());
	hub.publish(next);
	foreach (event : events)
	{
		Packet{Event}* packet = hub.emit_begin();
		packet.value = { .kind = event.kind, .id = event.id.copy(packet.allocator()) };
		hub.emit(packet);
	}
	if (before != null) before.release();
}

<*
 The events that turn `before` into `after`, allocated in `allocator`.

 Windows and workspaces are matched by id. Output changes are not events in v1:
 read `State.outputs` when a bar needs them.

 @param allocator : "Allocator for the event array (the snapshot of `after` in `publish_changes`)"
*>
fn Event[] changes(State* before, State* after, Allocator allocator)
{
	List{Event} events;
	events.init(allocator);
	if (before.connection != after.connection) events.push({ .kind = CONNECTION_CHANGED });
	window_changes(before, after, &events);
	if (!equal::deep(before.focused_window_id, after.focused_window_id))
	{
		events.push({ .kind = FOCUS_CHANGED, .id = after.focused_window_id });
	}
	workspace_changes(before, after, &events);
	return events.array_view();
}

fn void window_changes(State* before, State* after, List{Event}* events) @private
{
	foreach (window : before.windows)
	{
		if (find_window(after, window.id) < 0) events.push({ .kind = WINDOW_CLOSED, .id = window.id });
	}
	foreach (window : after.windows)
	{
		sz index = find_window(before, window.id);
		if (index < 0)
		{
			events.push({ .kind = WINDOW_OPENED, .id = window.id });
		}
		else if (!equal::deep(before.windows[index], window))
		{
			events.push({ .kind = WINDOW_CHANGED, .id = window.id });
		}
	}
}

fn void workspace_changes(State* before, State* after, List{Event}* events) @private
{
	foreach (workspace : before.workspaces)
	{
		if (find_workspace(after, workspace.id) < 0) events.push({ .kind = WORKSPACE_REMOVED, .id = workspace.id });
	}
	foreach (workspace : after.workspaces)
	{
		sz index = find_workspace(before, workspace.id);
		if (index < 0)
		{
			events.push({ .kind = WORKSPACE_ADDED, .id = workspace.id });
		}
		else if (!equal::deep(before.workspaces[index], workspace))
		{
			events.push({ .kind = WORKSPACE_CHANGED, .id = workspace.id });
		}
	}
}

<* Index of the window with `id` in `state`, or -1. *>
fn sz find_window(State* state, String id)
{
	foreach (i, window : state.windows)
	{
		if (window.id == id) return (sz)i;
	}
	return -1;
}

<* Index of the workspace with `id` in `state`, or -1. *>
fn sz find_workspace(State* state, String id)
{
	foreach (i, workspace : state.workspaces)
	{
		if (workspace.id == id) return (sz)i;
	}
	return -1;
}

<*
 Publish a state that says nothing can be read, and why. The lists stay empty:
 nothing is known. Used when a worker cannot start or cannot keep its platform.
*>
fn void publish_status(WindowsHub* hub, String reason)
{
	Snapshot{State}* next = hub.begin();
	next.value.connection = Connection.DISCONNECTED;
	next.value.status = reason.copy(next.allocator());
	publish_changes(hub, next);
}