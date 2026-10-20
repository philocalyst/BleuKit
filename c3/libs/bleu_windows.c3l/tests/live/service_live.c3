// Live driver for the windows service on Linux (run.sh). It goes through the path a
// shell takes: open, the first state, events, actions, a refused action, and, with
// the `reconnect` argument, a lost compositor and its return. Output lines are
// `key=value` so run.sh can check them.
module service_live;
import bleu::windows, bleu::error, bleu::stream, bleu::observe, bleu::operation, std::io, std::time;

const Duration FIRST_STATE_WAIT = (Duration)8_000_000;
const Duration EVENT_WAIT       = (Duration)200_000;
const Duration ACTION_WAIT      = (Duration)3_000_000;
const int EVENT_ROUNDS          = 10;

fn String connection_name(windows::Connection connection) @private
{
	switch (connection)
	{
		case windows::Connection.CONNECTED: return "CONNECTED";
		case windows::Connection.DISCONNECTED: return "DISCONNECTED";
	}
}

fn String event_name(windows::EventKind kind) @private
{
	switch (kind)
	{
		case windows::EventKind.WINDOW_OPENED: return "WINDOW_OPENED";
		case windows::EventKind.WINDOW_CLOSED: return "WINDOW_CLOSED";
		case windows::EventKind.WINDOW_CHANGED: return "WINDOW_CHANGED";
		case windows::EventKind.FOCUS_CHANGED: return "FOCUS_CHANGED";
		case windows::EventKind.WORKSPACE_ADDED: return "WORKSPACE_ADDED";
		case windows::EventKind.WORKSPACE_REMOVED: return "WORKSPACE_REMOVED";
		case windows::EventKind.WORKSPACE_CHANGED: return "WORKSPACE_CHANGED";
		case windows::EventKind.CONNECTION_CHANGED: return "CONNECTION_CHANGED";
	}
}

fn String focused_title(windows::State* state) @private
{
	foreach (window : state.windows)
	{
		if (window.id == state.focused_window_id) return window.title;
	}
	return "none";
}

fn void summarize(String label, windows::State* state) @private
{
	io::printfn(
		"%s connection=%s windows=%d workspaces=%d outputs=%d focused=%s status=%s",
		label,
		connection_name(state.connection),
		(int)state.windows.len,
		(int)state.workspaces.len,
		(int)state.outputs.len,
		focused_title(state),
		state.status.len > 0 ? state.status : "none"
	);
}

// Wait for a state newer than `seen` that satisfies `want`; prints the timeout otherwise.
fn Snapshot{windows::State}*? wait_for_connection(windows::Windows* service, ulong seen, windows::Connection want, Duration limit) @private
{
	ulong generation = seen;
	while (true)
	{
		Snapshot{windows::State}* snapshot = service.wait_after(generation, limit)!;
		if (snapshot.value.connection == want) return snapshot;
		generation = snapshot.generation;
		snapshot.release();
	}
}

fn void report_action(String name, Operation{bool}* request) @private
{
	if (catch err = request.wait(ACTION_WAIT))
	{
		io::printfn("%s=failed %s (%s)", name, error::last().message(), err);
	}
	else
	{
		io::printfn("%s=ok", name);
	}
	request.release();
}

fn int main(int argc, char** argv)
{
	bool reconnect = argc > 1;
	DynamicArenaAllocator arena;
	arena.init(mem, 65536);
	defer arena.free();
	Allocator allocator = &arena;

	windows::Windows*? opened = windows::open(allocator);
	if (catch err = opened)
	{
		io::printfn("open=failed %s (%s)", error::last().message(), err);
		return 0;
	}
	windows::Windows* service = opened;
	defer service.close();
	io::printfn("open=ok backend=%s", service.backend_name());

	Snapshot{windows::State}* first = service.wait_after(0, FIRST_STATE_WAIT)!!;
	summarize("first", &first.value);
	ulong seen = first.generation;
	first.release();

	stream::Reader{windows::Event}* reader = service.subscribe()!!;
	defer reader.release();
	for (int round = 0; round < EVENT_ROUNDS; round++)
	{
		stream::Packet{windows::Event}*? next = reader.next(EVENT_WAIT);
		if (catch err = next)
		{
			// Nothing in this slice; keep listening.
			continue;
		}
		else
		{
			io::printfn("event=%s id=%s", event_name(next.value.kind), next.value.id);
			next.release();
		}
	}

	Snapshot{windows::State}* now = service.latest()!!;
	summarize("now", &now.value);
	if (now.value.windows.len == 0 || now.value.workspaces.len == 0)
	{
		// Nothing to act on: the backend could not read the platform.
		now.release();
		io::printfn("no-targets");
		return 0;
	}
	// The actions name what the platform reported, so every backend gets its own ids.
	String target = now.value.windows[0].id.copy(allocator);
	String destination = now.value.workspaces[now.value.workspaces.len - 1].id.copy(allocator);
	io::printfn("target=%s destination=%s", target, destination);
	now.release();

	report_action("focus_window", service.focus_window(target)!!);
	report_action("close_window", service.close_window(target)!!);
	report_action("switch_workspace", service.switch_workspace(destination)!!);
	report_action("move_window", service.move_window_to_workspace(target, destination)!!);
	report_action("toggle_floating", service.toggle_floating(target)!!);
	report_action("toggle_fullscreen", service.toggle_fullscreen(target)!!);
	report_action("focus_window_not_an_id", service.focus_window("0x1 0x2")!!);
	if (catch err = service.minimize_window(target))
	{
		io::printfn("minimize_window=refused %s (%s)", service.capability(windows::Cap.MINIMIZE_WINDOW).note, err);
	}
	else
	{
		io::printfn("minimize_window=unexpected-accept");
	}

	if (reconnect)
	{
		// The runner kills the compositor after the first state; wait for the loss, then for the return.
		Snapshot{windows::State}* lost = wait_for_connection(service, seen, windows::Connection.DISCONNECTED, (Duration)15_000_000)!!;
		summarize("lost", &lost.value);
		seen = lost.generation;
		lost.release();
		report_action("action_while_down", service.focus_window(target)!!);
		io::printfn("runner=restart-compositor");
		Snapshot{windows::State}* back = wait_for_connection(service, seen, windows::Connection.CONNECTED, (Duration)15_000_000)!!;
		summarize("back", &back.value);
		back.release();
	}
	return 0;
}
