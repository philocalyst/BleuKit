<*
 The macOS windows backend: NSWorkspace for the applications, CGWindowList for the
 windows, and the Accessibility API for close and minimize.

 * Windows are the on-screen, layer-0 windows, front to back. The first one of the
 frontmost application is the focused window. Minimized windows are not on screen
 and so are not listed; minimized is therefore not reported.
 * Titles need Screen Recording permission. Without it `State.titles_available` is
 false and every title is "".
 * Accessibility acts on the owning application's focused window: the mapping from a
 window number to its accessibility element is a private API this library does not
 use. Close and minimize need Accessibility permission (PERMISSION_NEEDED otherwise).
 * A change is seen two ways: NSWorkspace's didActivateApplication notification (its
 observer only enqueues a REFRESH) and a poll every REFRESH_INTERVAL, which catches
 every change the notification does not.
 * With `Options.allow_private`, the Space on the focused screen is listed as the one
 workspace (macos_spaces_private.c3). The other Spaces and moving windows between
 them are not done.

 Observed on: NOT RUN. Compiled for macos-aarch64 and macos-x64 only.
*>
module bleu::windows::macos_workspace @feat(DARWIN);
import std::collections::list, std::collections::maybe, std::time, std::os::darwin::objc, bleu::error, bleu::availability, bleu::observe, bleu::rt::poller, bleu::rt::worker, bleu::operation, bleu::objc, bleu::objc::foundation, bleu::objc::notify, bleu::cf, bleu::windows, bleu::windows::macos_cg, bleu::windows::macos_ax, bleu::windows::macos_spaces_private;

// The poller holds the wake-up only.
const usz POLLER_CAPACITY                = 2;
const usz COMMAND_BATCH                  = 16;
// The poll that catches every change the notification does not (1 s, in microseconds).
const Duration REFRESH_INTERVAL          = (Duration)1_000_000;
// NSApplicationActivateIgnoringOtherApps (NSRunningApplication.h): 1 << 1. Single source; UNVERIFIED here.
const ulong ACTIVATE_IGNORING_OTHER_APPS = 2;
// NSWorkspaceDidActivateApplicationNotification (NSWorkspace.h), as the Apple reference names it.
const String DID_ACTIVATE_NOTIFICATION   = "NSWorkspaceDidActivateApplicationNotification";
// kCGNormalWindowLevel (CGWindowLevel.h, objc2-core-graphics CGWindowLevel.rs:15): ordinary windows.
// Menu bars, the dock and overlays sit on other layers.
const long NORMAL_WINDOW_LAYER           = 0;

<* The hub the notification observer enqueues to. Set while observing, on the worker's thread. *>
WindowsHub* active_hub = null;

<* The backend's state: what the permissions allow, and the SkyLight table when it was opened. *>
struct Session
{
	bool trusted;
	bool has_spaces;
	SkyLight spaces;
}

<* A running application: its process id and bundle identifier ("" when it has none). *>
struct App
{
	int pid;
	String bundle;
}

const Driver DRIVER = {
	.info = { "macos", "NSWorkspace, CGWindowList and the Accessibility API", 10 },
	.id = Backend.MACOS,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

fn bool probe(Options* options) => true;

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	Session* session = alloc::new(allocator, Session);
	session.trusted = macos_ax::is_trusted();
	if (options.allow_private)
	{
		if (catch macos_spaces_private::open_skylight(&session.spaces))
		{
		}
		else
		{
			session.has_spaces = true;
		}
	}
	capabilities.init(availability::YES);
	if (!macos_cg::screen_capture_allowed())
	{
		capabilities.set(
			Cap.WINDOW_TITLES,
			availability::no(
				availability::Reason.PERMISSION_NEEDED,
				"Screen Recording permission is needed for window titles (System Settings > Privacy & Security > Screen Recording)"
			)
		);
	}
	if (session.has_spaces)
	{
		capabilities.set(
			Cap.LIST_WORKSPACES,
			availability::no(
				availability::Reason.DEGRADED,
				"only the Space on the focused screen is listed; the other Spaces are not read (private API, unverified shape)"
			)
		);
	}
	else
	{
		capabilities.set(
			Cap.LIST_WORKSPACES,
			availability::no(
				availability::Reason.UNSUPPORTED_BACKEND,
				"Spaces are private API: set Options.allow_private to list the Space on the focused screen"
			)
		);
	}
	capabilities.set(
		Cap.SWITCH_WORKSPACE,
		availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"switching Spaces needs a scripting addition injected into Dock.app, which needs SIP partly disabled"
		)
	);
	capabilities.set(
		Cap.MOVE_WINDOW_TO_WORKSPACE,
		availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"moving a window between Spaces needs the same scripting addition as switching them"
		)
	);
	capabilities.set(
		Cap.TOGGLE_FLOATING,
		availability::no(availability::Reason.UNSUPPORTED_OS, "the public API has no per-window floating state")
	);
	capabilities.set(
		Cap.TOGGLE_FULLSCREEN,
		availability::no(availability::Reason.UNSUPPORTED_BACKEND, "not implemented in this backend")
	);
	capabilities.set(
		Cap.FOCUS_WINDOW,
		availability::no(
			availability::Reason.DEGRADED,
			"activates the owning application; raises its focused window only when Accessibility is granted"
		)
	);
	if (session.trusted)
	{
		capabilities.set(
			Cap.CLOSE_WINDOW,
			availability::no(availability::Reason.DEGRADED, "closes the owning application's focused window")
		);
		capabilities.set(
			Cap.MINIMIZE_WINDOW,
			availability::no(availability::Reason.DEGRADED, "minimizes the owning application's focused window")
		);
	}
	else
	{
		capabilities.set(
			Cap.CLOSE_WINDOW,
			availability::no(
				availability::Reason.PERMISSION_NEEDED,
				"Accessibility permission is needed (System Settings > Privacy & Security > Accessibility); open the service again after granting it"
			)
		);
		capabilities.set(
			Cap.MINIMIZE_WINDOW,
			availability::no(
				availability::Reason.PERMISSION_NEEDED,
				"Accessibility permission is needed (System Settings > Privacy & Security > Accessibility); open the service again after granting it"
			)
		);
	}
	return session;
}

fn void destroy(Allocator allocator, void* state)
{
	Session* session = (Session*)state;
	if (session.has_spaces) session.spaces.close();
	alloc::free(allocator, session);
}

// The worker: a poll, a notification observer, and one publish per change.
fn void run(void* state, WindowsHub* hub, Host{Command}* host)
{
	Session* session = (Session*)state;
	Poller poller;
	if (catch err = poller.init(mem, host.wakeup(), POLLER_CAPACITY))
	{
		windows::publish_status(hub, error::last().message());
		return;
	}
	defer poller.free();
	active_hub = hub;
	notify::BlockSubscription watch;
	bool watching = false;
	Obj name      = notify::name_of(DID_ACTIVATE_NOTIFICATION);
	defer name.close();
	if (try subscribed = notify::observe(notify::CenterKind.WORKSPACE, name.ptr, &on_activate, null))
	{
		watch = subscribed;
		watching = true;
	}
	defer stop_watching(&watch, watching);
	refresh(session, hub);
	Command[COMMAND_BATCH] batch;
	while (!host.stopping())
	{
		if (catch err = poller.wait(REFRESH_INTERVAL))
		{
			// A timeout is the poll coming due; anything else means the wait itself failed.
			if (err != TIMEOUT)
			{
				windows::publish_status(hub, error::last().message());
				return;
			}
		}
		usz count = host.mailbox().take_all(batch[..]);
		for (usz i = 0; i < count; i++)
		{
			Command command = batch[i];
			if (command.kind != CommandKind.REFRESH) run_command(session, &command);
		}
		refresh(session, hub);
	}
	windows::fail_queued(host, batch[..]);
}

// Notification callback. It runs on the posting thread and only enqueues.
fn void on_activate(void* user, ObjId value) @private
{
	objc::@objc_entry()
	{
		WindowsHub* hub = active_hub;
		if (hub != null)
		{
			if (catch hub.post({ .kind = CommandKind.REFRESH }))
			{
			}
		}
	};
}

// Stop observing. The hub is forgotten first, so a late notification enqueues nothing.
fn void stop_watching(notify::BlockSubscription* watch, bool watching) @private
{
	active_hub = null;
	if (watching) watch.close();
}

// Read the platform and publish the state if it differs. Runs inside an Objective-C pool.
fn void refresh(Session* session, WindowsHub* hub) @private
{
	objc::@autorelease_pool()
	{
		@pool()
		{
			Snapshot{State}* next = hub.begin();
			fill_state(session, &next.value, next.allocator());
			windows::publish_changes(hub, next);
		};
	};
}

// The complete state, built into `state` in `allocator`.
fn void fill_state(Session* session, State* state, Allocator allocator) @private
{
	App[] apps   = running_applications(tmem);
	int front    = frontmost_pid();
	cf::Ref list = macos_cg::window_list();
	defer list.close();
	List{windows::Window} listed;
	listed.init(allocator);
	state.focused_window_id = "";
	bool focus_taken = false;
	for (sz i = 0; i < cf::array_count(list.ptr); i++)
	{
		cf::CFTypeRef record = cf::array_at(list.ptr, i);
		if (record_long(record, macos_cg::KCG_WINDOW_LAYER, -1) != NORMAL_WINDOW_LAYER) continue;
		int pid      = (int)record_long(record, macos_cg::KCG_WINDOW_OWNER_PID, 0);
		bool focused = !focus_taken && pid != 0 && pid == front;
		if (focused) focus_taken = true;
		windows::Window window = window_of(record, pid, focused, apps, allocator);
		if (focused) state.focused_window_id = window.id;
		listed.push(window);
	}
	state.connection = Connection.CONNECTED;
	state.status = "";
	state.titles_available = macos_cg::screen_capture_allowed();
	state.windows = listed.array_view();
	state.workspaces = spaces_of(session, allocator);
	state.outputs = { };
}

// The workspace list: the Space on the focused screen when SkyLight is open, otherwise none.
fn windows::Workspace[] spaces_of(Session* session, Allocator allocator) @private
{
	if (!session.has_spaces) return { };
	if (catch err = macos_spaces_private::active_space(&session.spaces))
	{
		return { };
	}
	windows::Workspace[] spaces = alloc::new_array(allocator, windows::Workspace, 1);
	spaces[0] = {
		.id = string::tformat("%d", (long)macos_spaces_private::active_space(&session.spaces) ?? 0)
		.copy(allocator), .name = "", .output_id = "", .active = true, .visible = true, .window_count = 0, };
	return spaces;
}

// One window record of the window server.
fn windows::Window window_of(cf::CFTypeRef record, int pid, bool focused, App[] apps, Allocator allocator) @private
{
	String bundle = bundle_of(apps, pid);
	String owner  = record_text(record, macos_cg::KCG_WINDOW_OWNER_NAME);
	String app_id = bundle.len > 0 ? bundle : owner;
	windows::WindowFlags flags;
	flags.focused = focused;
	windows::WindowFlags reported;
	reported.focused = true;
	Maybe{windows::Rect} geometry = { };
	macos_cg::CgRect bounds;
	if (macos_cg::record_bounds(record, &bounds))
	{
		windows::Rect rect = {
			.x = (int)bounds.x,
			.y = (int)bounds.y,
			.width = (int)bounds.width,
			.height = (int)bounds.height,
		};
		geometry = maybe::value(rect);
	}
	return {
		.id = string::tformat("%d", record_long(record, macos_cg::KCG_WINDOW_NUMBER, 0))
		.copy(allocator), .title = record_text(record, macos_cg::KCG_WINDOW_NAME)
			.copy(
				allocator
			), .app_id = app_id.copy(
				allocator
			), .icon_hint = app_id.copy(
				allocator
			), .pid = pid > 0 ? maybe::value(pid)
				: { }, .workspace_id = "", .output_id = "", .geometry = geometry, .flags = flags, .reported = reported, };
}

// A number from a window record, or `fallback`.
fn long record_long(cf::CFTypeRef record, cf::CFTypeRef key, long fallback) @private
{
	cf::CFTypeRef value = macos_cg::record_value(record, key);
	if (value == null) return fallback;
	return cf::number_long(value) ?? fallback;
}

// A string from a window record, copied into temporary memory; "" when absent.
fn String record_text(cf::CFTypeRef record, cf::CFTypeRef key) @private
{
	cf::CFTypeRef value = macos_cg::record_value(record, key);
	if (value == null) return "";
	return cf::string_value(value, tmem) ?? "";
}

// The running applications, in temporary memory.
fn App[] running_applications(Allocator allocator) @private
{
	List{App} apps;
	apps.init(allocator);
	ObjId workspace = objc::class_named("NSWorkspace").send(ObjId, "sharedWorkspace");
	ObjId running   = workspace.send(ObjId, "runningApplications");
	usz count       = (usz)running.send(ulong, "count");
	for (usz i = 0; i < count; i++)
	{
		ObjId application = foundation::array_at(running, i);
		ObjId identifier  = application.send(ObjId, "bundleIdentifier");
		String bundle     = "";
		if (identifier) bundle = foundation::to_string(identifier, allocator) ?? "";
		apps.push({ .pid = application.send(int, "processIdentifier"), .bundle = bundle });
	}
	return apps.array_view();
}

// The bundle identifier of a process, "" when it has none.
fn String bundle_of(App[] apps, int pid) @private
{
	foreach (app : apps)
	{
		if (app.pid == pid) return app.bundle;
	}
	return "";
}

// The process id of the frontmost application, 0 when there is none.
fn int frontmost_pid() @private
{
	ObjId workspace = objc::class_named("NSWorkspace").send(ObjId, "sharedWorkspace");
	ObjId front     = workspace.send(ObjId, "frontmostApplication");
	if (!front) return 0;
	return front.send(int, "processIdentifier");
}

// The process that owns the window with `number`.
fn int? pid_of(long number) @private
{
	cf::Ref list = macos_cg::window_list();
	defer list.close();
	for (sz i = 0; i < cf::array_count(list.ptr); i++)
	{
		cf::CFTypeRef record = cf::array_at(list.ptr, i);
		if (record_long(record, macos_cg::KCG_WINDOW_NUMBER, -1) == number)
		{
			return (int)record_long(record, macos_cg::KCG_WINDOW_OWNER_PID, 0);
		}
	}
	return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "no on-screen window %d", number)~;
}

// Carry out one action. The request is started, completed and released here.
fn void run_command(Session* session, Command* command) @private
{
	Operation{bool}* request = command.request;
	request.start();
	if (catch err = act(session, command))
	{
		request.fail(err);
	}
	else
	{
		request.succeed(true);
	}
	request.release();
}

fn void? act(Session* session, Command* command) @private
{
	switch (command.kind)
	{
		case CommandKind.REFRESH: return;
		case CommandKind.FOCUS_WINDOW: return focus(session, window_ids::number_of(command.target)!);
		case CommandKind.CLOSE_WINDOW: return close_window(session, window_ids::number_of(command.target)!);
		case CommandKind.MINIMIZE_WINDOW: return minimize(session, window_ids::number_of(command.target)!);
		case CommandKind.SWITCH_WORKSPACE:
			return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "switching Spaces is not supported")~;
		case CommandKind.MOVE_WINDOW_TO_WORKSPACE:
			return error::raise(
				error::UNSUPPORTED,
				error::Domain.INTERNAL,
				0,
				"moving windows between Spaces is not supported"
			)~;
		case CommandKind.TOGGLE_FLOATING:
			return error::raise(
				error::UNSUPPORTED,
				error::Domain.INTERNAL,
				0,
				"there is no per-window floating state"
			)~;
		case CommandKind.TOGGLE_FULLSCREEN:
			return error::raise(
				error::UNSUPPORTED,
				error::Domain.INTERNAL,
				0,
				"fullscreen is not implemented on macOS"
			)~;
	}
}

// Activate the owning application and, when trusted, raise its focused window.
fn void? focus(Session* session, long number) @private
{
	int pid = pid_of(number)!;
	ObjId application = objc::class_named("NSRunningApplication")
		.send(ObjId, "runningApplicationWithProcessIdentifier:", pid);
	if (!application)
	{
		return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "process %d is not running", pid)~;
	}
	bool activated = application.send(bool, "activateWithOptions:", ACTIVATE_IGNORING_OTHER_APPS);
	if (!activated)
	{
		return error::raise(
			error::BACKEND_FAILURE,
			error::Domain.INTERNAL,
			0,
			"the system refused to activate process %d",
			pid
		)~;
	}
	if (session.trusted)
	{
		cf::Ref window = macos_ax::focused_window(pid)!;
		defer window.close();
		macos_ax::perform(window.ptr, macos_ax::ACTION_RAISE)!;
	}
}

// Press the close button of the owning application's focused window.
fn void? close_window(Session* session, long number) @private
{
	accessibility_granted(session)!;
	int pid        = pid_of(number)!;
	cf::Ref window = macos_ax::focused_window(pid)!;
	defer window.close();
	cf::Ref button = macos_ax::copy_attribute(window.ptr, macos_ax::ATTRIBUTE_CLOSE_BUTTON)!;
	defer button.close();
	macos_ax::perform(button.ptr, macos_ax::ACTION_PRESS)!;
}

// Set AXMinimized on the owning application's focused window.
fn void? minimize(Session* session, long number) @private
{
	accessibility_granted(session)!;
	int pid        = pid_of(number)!;
	cf::Ref window = macos_ax::focused_window(pid)!;
	defer window.close();
	macos_ax::set_flag(window.ptr, macos_ax::ATTRIBUTE_MINIMIZED, true)!;
}

fn void? accessibility_granted(Session* session) @private
{
	if (!session.trusted)
	{
		return error::raise(
			error::PERMISSION_DENIED,
			error::Domain.INTERNAL,
			0,
			"Accessibility permission is not granted"
		)~;
	}
}