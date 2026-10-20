<*
 The windows service: open it, read `latest()`, wait for changes, act on windows.

 Windows* windows = windows::open(mem)!;
 defer windows.close();
 if (try snapshot = windows.latest())
 {
 defer snapshot.release();
 // snapshot.value.windows, snapshot.value.workspaces ...
 }

 Actions return an `Operation{bool}*`: the value is `true` once the platform
 accepted the request. The change itself arrives through `latest()` and
 `subscribe()`. An action the backend cannot do is refused at once with
 `error::UNSUPPORTED` (or `PERMISSION_DENIED`), never queued.

 Every method may be called from any thread.
*>
module bleu::windows;
import std::collections::enummap, std::time, bleu::error, bleu::availability, bleu::observe, bleu::stream, bleu::service, bleu::operation;

alias WindowsHub = Hub{State, Command, Event};
alias Capabilities = EnumMap{Cap, Availability};

const Duration DEFAULT_RETRY     = (Duration)1_000_000;  // 1 s, in microseconds
const Duration DEFAULT_RETRY_MAX = (Duration)30_000_000; // 30 s

<* An open windows service. Released by `close`. *>
struct Windows
{
	Allocator allocator;
	WindowsHub hub;
	Driver* driver;
	void* driver_state;
	Capabilities capabilities;
}

<*
 Open the first working backend of this platform (or the one in `options`).

 @param allocator : "Allocator for the service and its snapshots"
 @return? error::UNAVAILABLE : "No backend works here (no compositor, no desktop session)"
 @return? error::UNSUPPORTED : "The requested backend does not exist on this platform"
 @return? error::UNAVAILABLE : "The requested backend exists here but does not work now"
*>
fn Windows*? open(Allocator allocator, Options options = { })
{
	if (options.retry == time::DURATION_ZERO) options.retry = DEFAULT_RETRY;
	if (options.retry_max == time::DURATION_ZERO) options.retry_max = DEFAULT_RETRY_MAX;
	Driver* driver = select_driver(options)!;
	Windows* self  = alloc::new(allocator, Windows);
	self.allocator = allocator;
	self.driver = driver;
	void*? state = driver.create(allocator, options, &self.capabilities);
	if (catch err = state)
	{
		alloc::free(allocator, self);
		return err~;
	}
	self.driver_state = state;
	if (catch err = self.hub.start(
		allocator,
		"windows",
		driver.info.name,
		driver.run,
		self.driver_state,
		service::DEFAULT_QUEUE,
		&cancel_command
	))
	{
		driver.destroy(allocator, self.driver_state);
		alloc::free(allocator, self);
		return err~;
	}
	return self;
}

<* Stop the backend and release everything. Actions still queued fail with `CANCELLED`. *>
fn void Windows.close(&self)
{
	self.hub.stop();
	self.driver.destroy(self.allocator, self.driver_state);
	Allocator allocator = self.allocator;
	alloc::free(allocator, self);
}

<* Name of the backend in use, for diagnostics ("compositor", "win32", "macos"). *>
fn String Windows.backend_name(&self) => self.hub.backend_name;

<* Whether `cap` works with this backend, and if not, why. *>
fn Availability Windows.capability(&self, Cap cap) => self.capabilities.values[cap.ordinal];

<*
 The newest state, retained for the caller (call `release()` on it).

 @return? error::UNAVAILABLE : "The backend has not produced its first reading yet"
*>
fn Snapshot{State}*? Windows.latest(&self) => self.hub.latest();

<*
 Block until a state newer than `seen` exists. Start with `seen = 0`, then pass
 the previous snapshot's `generation`.

 @return? TIMEOUT : "Nothing changed in time"
 @return? error::DISCONNECTED : "The service was closed"
*>
fn Snapshot{State}*? Windows.wait_after(&self, ulong seen, Duration timeout = time::FOREVER)
{
	return self.hub.state.wait_after(seen, timeout);
}

<* Call `listener` on the worker thread for the current and every later state. Quick and non-blocking only. *>
fn WatchId{State} Windows.watch(
	&self,
	Listener{State} listener,
	void* context
) => self.hub.state.watch(listener, context);

<* Remove a listener; when this returns it is not running. Not from inside a listener. *>
fn void Windows.unwatch(&self, WatchId{State} id) => self.hub.state.unwatch(id);

<* Subscribe to transient events (windows opened, focus moved, workspaces changed). *>
fn Reader{Event}*? Windows.subscribe(&self) => self.hub.events.subscribe();

<* Ask the backend to re-read the platform now; returns once the request is queued. *>
fn void? Windows.refresh(&self) => self.hub.post({ .kind = CommandKind.REFRESH });

<*
 Focus a window, and show its workspace.

 @param window_id : "A `Window.id` from the current state"
 @return? error::UNSUPPORTED : "The backend cannot focus windows"
 @return? error::PERMISSION_DENIED : "The OS refuses this process the action (Accessibility on macOS)"
*>
fn Operation{bool}*? Windows.focus_window(&self, String window_id)
{
	return send_request(self, Cap.FOCUS_WINDOW, window_id, "");
}

<*
 Ask a window to close, as its close button would.

 @param window_id : "A `Window.id` from the current state"
 @return? error::UNSUPPORTED : "The backend cannot close windows"
*>
fn Operation{bool}*? Windows.close_window(&self, String window_id)
{
	return send_request(self, Cap.CLOSE_WINDOW, window_id, "");
}

<*
 Minimize a window to the taskbar or dock.

 @param window_id : "A `Window.id` from the current state"
 @return? error::UNSUPPORTED : "The backend cannot minimize windows"
*>
fn Operation{bool}*? Windows.minimize_window(&self, String window_id)
{
	return send_request(self, Cap.MINIMIZE_WINDOW, window_id, "");
}

<*
 Show a workspace on its output.

 @param workspace_id : "A `Workspace.id` from the current state"
 @return? error::UNSUPPORTED : "The backend cannot switch workspaces"
*>
fn Operation{bool}*? Windows.switch_workspace(&self, String workspace_id)
{
	return send_request(self, Cap.SWITCH_WORKSPACE, workspace_id, "");
}

<*
 Move a window to another workspace without changing focus.

 @param window_id : "A `Window.id` from the current state"
 @param workspace_id : "A `Workspace.id` from the current state"
 @return? error::UNSUPPORTED : "The backend cannot move windows between workspaces"
*>
fn Operation{bool}*? Windows.move_window_to_workspace(&self, String window_id, String workspace_id)
{
	return send_request(self, Cap.MOVE_WINDOW_TO_WORKSPACE, window_id, workspace_id);
}

<*
 Toggle floating for a window.

 @param window_id : "A `Window.id` from the current state"
 @return? error::UNSUPPORTED : "The backend cannot float windows"
*>
fn Operation{bool}*? Windows.toggle_floating(&self, String window_id)
{
	return send_request(self, Cap.TOGGLE_FLOATING, window_id, "");
}

<*
 Toggle fullscreen for a window.

 @param window_id : "A `Window.id` from the current state"
 @return? error::UNSUPPORTED : "The backend cannot make windows fullscreen"
*>
fn Operation{bool}*? Windows.toggle_fullscreen(&self, String window_id)
{
	return send_request(self, Cap.TOGGLE_FULLSCREEN, window_id, "");
}

// The one path every action takes: refuse what the backend cannot do, else copy
// the arguments into the operation's arena and queue the command.
fn Operation{bool}*? send_request(Windows* self, Cap cap, String target, String destination) @private
{
	Availability availability = self.capabilities.values[cap.ordinal];
	if (!availability.ok()) return availability.refusal()~;
	Operation{bool}* op = operation::begin{bool}(self.allocator);
	Allocator arena     = op.allocator();
	CommandKind kind    = command_kind(cap);
	// One reference for the caller, one for the queued command (released by the worker).
	op.retain();
	if (catch err = self.hub.post(
		{ .kind = kind, .target = target.copy(arena), .destination = destination.copy(arena), .request = op }
	))
	{
		op.release();
		op.release();
		return err~;
	}
	return op;
}

// The command that a capability's action sends to the worker.
fn CommandKind command_kind(Cap cap) @private
{
	switch (cap)
	{
		case Cap.LIST_WINDOWS: unreachable("listing is not an action");
		case Cap.LIST_WORKSPACES: unreachable("listing is not an action");
		case Cap.WINDOW_TITLES: unreachable("titles are not an action");
		case Cap.FOCUS_WINDOW: return CommandKind.FOCUS_WINDOW;
		case Cap.CLOSE_WINDOW: return CommandKind.CLOSE_WINDOW;
		case Cap.MINIMIZE_WINDOW: return CommandKind.MINIMIZE_WINDOW;
		case Cap.SWITCH_WORKSPACE: return CommandKind.SWITCH_WORKSPACE;
		case Cap.MOVE_WINDOW_TO_WORKSPACE: return CommandKind.MOVE_WINDOW_TO_WORKSPACE;
		case Cap.TOGGLE_FLOATING: return CommandKind.TOGGLE_FLOATING;
		case Cap.TOGGLE_FULLSCREEN: return CommandKind.TOGGLE_FULLSCREEN;
	}
}