<*
 The Windows backend: EnumWindows, the Alt-Tab rules, and win-event hooks.

 One worker thread owns the COM apartment (MTA, for IVirtualDesktopManager) and a
 `WINEVENT_OUTOFCONTEXT` hook on the foreground, create, destroy, show, hide, state,
 location, name and cloak events of window objects. The hook's callback only
 enqueues a REFRESH; the worker then enumerates the top-level windows, applies the
 Alt-Tab rules (`win32_rules`), reads each window's title, class, process, geometry
 and state, asks which virtual desktop each one is on, and publishes the state.

 Out-of-context callbacks are delivered through the installing thread's message
 queue, so the worker waits on a poller in window-message mode and calls
 `message_loop::dispatch_pending` after every wait.

 The hook procedure takes no context argument, so the running worker registers its
 hub in a module global. One Windows service per process is supported: a second
 one would replace the first hub.
*>
module bleu::windows::win32_enum @feat(WIN32);
import std::collections::list, std::os::win32, std::time, std::collections::maybe, bleu::error, bleu::availability, bleu::observe, bleu::operation, bleu::rt::poller, bleu::rt::worker, bleu::win::com, bleu::win::com_ptr, bleu::win::errors, bleu::win::guid, bleu::win::hresult, bleu::win::message_loop, bleu::win::text, bleu::windows, bleu::windows::win32_dwm, bleu::windows::win32_proc, bleu::windows::win32_rules, bleu::windows::win32_user, bleu::windows::win32_vdm;

// The poller holds the wake-up only; window messages are a mode of the poller, not a source.
const usz POLLER_CAPACITY = 2;
const usz COMMAND_BATCH   = 16;
// Characters of a window title and of a window class kept; longer text is cut.
const usz TEXT_UNITS      = 512;
// Characters of an image path kept (the Win32 path limit is 32767; typical paths are far shorter).
const usz PATH_UNITS      = 1024;

<* The hub the hook callback enqueues to. Set while the hook is installed, on the worker's thread. *>
WindowsHub* active_hub = null;

<* The state of the backend: the COM desktop manager, when it could be created. *>
struct Session
{
	com_ptr::Com{win32_vdm::IVirtualDesktopManager} manager;
	bool has_manager;
}

const Driver DRIVER = {
	.info = { "win32", "EnumWindows, win-event hooks and IVirtualDesktopManager", 10 },
	.id = Backend.WIN32,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

fn bool probe(Options* options) => true;

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	capabilities.set(
		Cap.LIST_WORKSPACES,
		availability::no(
			availability::Reason.DEGRADED,
			"only virtual desktops that hold a listed window are known: the documented API cannot enumerate desktops"
		)
	);
	capabilities.set(
		Cap.SWITCH_WORKSPACE,
		availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"switching virtual desktops needs the undocumented IVirtualDesktopManagerInternal, which this library does not use"
		)
	);
	capabilities.set(
		Cap.FOCUS_WINDOW,
		availability::no(
			availability::Reason.DEGRADED,
			"SetForegroundWindow is refused when this process may not take focus; the refusal is reported"
		)
	);
	capabilities.set(
		Cap.TOGGLE_FLOATING,
		availability::no(availability::Reason.UNSUPPORTED_OS, "Windows has no floating state for ordinary windows")
	);
	capabilities.set(
		Cap.TOGGLE_FULLSCREEN,
		availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"no documented API makes another process's window fullscreen"
		)
	);
	return alloc::new(allocator, Session);
}

fn void destroy(Allocator allocator, void* state)
{
	alloc::free(allocator, state);
}

// The worker: COM, the hook, the poller, and one publish per change.
fn void run(void* state, WindowsHub* hub, Host{Command}* host)
{
	Session* session        = (Session*)state;
	com::Apartment? entered = com::enter(com::Model.MULTI_THREADED);
	if (catch err = entered)
	{
		windows::publish_status(hub, error::last().message());
		return;
	}
	com::Apartment apartment = entered;
	defer apartment.leave();
	Poller poller;
	if (catch err = poller.init(mem, host.wakeup(), POLLER_CAPACITY, true))
	{
		windows::publish_status(hub, error::last().message());
		return;
	}
	defer poller.free();
	open_manager(session);
	defer release_manager(session);
	active_hub = hub;
	void* hook = win32_user::set_win_event_hook(
		win32_rules::EVENT_SYSTEM_FOREGROUND,
		win32_rules::EVENT_OBJECT_UNCLOAKED,
		null,
		&hook_proc,
		0,
		0,
		win32_rules::WINEVENT_OUTOFCONTEXT | win32_rules::WINEVENT_SKIPOWNPROCESS
	);
	if (hook == null)
	{
		active_hub = null;
		windows::publish_status(hub, error::last().message());
		return;
	}
	defer uninstall_hook(hook);
	refresh(session, hub);
	Command[COMMAND_BATCH] batch;
	while (!host.stopping())
	{
		poller::Ready[]? ready = poller.wait(time::FOREVER);
		if (catch err = ready)
		{
			windows::publish_status(hub, error::last().message());
			return;
		}
		message_loop::dispatch_pending();
		bool dirty = false;
		usz count  = host.mailbox().take_all(batch[..]);
		for (usz i = 0; i < count; i++)
		{
			Command command = batch[i];
			if (command.kind == CommandKind.REFRESH)
			{
				dirty = true;
				continue;
			}
			run_command(session, &command);
		}
		if (dirty) refresh(session, hub);
	}
	windows::fail_queued(host, batch[..]);
}

// Open the desktop manager. Without it the workspaces are not listed and cannot be moved to.
fn void open_manager(Session* session) @private
{
	com_ptr::Com{win32_vdm::IVirtualDesktopManager}? manager = win32_vdm::open_manager();
	if (catch err = manager)
	{
		session.has_manager = false;
	}
	else
	{
		session.manager = manager;
		session.has_manager = true;
	}
}

// Release the desktop manager, if one was opened.
fn void release_manager(Session* session) @private
{
	if (session.has_manager) session.manager.release();
}

// Stop the hook. The hub is forgotten first so that a late callback enqueues nothing.
fn void uninstall_hook(void* hook) @private
{
	active_hub = null;
	win32_user::unhook_win_event(hook);
}

// Callback of the win-event hook. It runs on the worker's thread and only enqueues.
fn void hook_proc(
	void* hook,
	uint event,
	void* hwnd,
	int id_object,
	int id_child,
	uint thread_id,
	uint event_time
) @private
{
	if (!win32_rules::is_relevant_event(event, id_object)) return;
	WindowsHub* hub = active_hub;
	if (hub == null) return;
	// A full queue loses nothing: a refresh is already waiting, and the next event refreshes again.
	if (catch hub.post({ .kind = CommandKind.REFRESH }))
	{
	}
}

// Read the platform and publish the state if it differs.
fn void refresh(Session* session, WindowsHub* hub) @private
{
	Snapshot{State}* next = hub.begin();
	fill_state(session, &next.value, next.allocator());
	windows::publish_changes(hub, next);
}

// The complete state of the desktop, built into `state` in `allocator`.
fn void fill_state(Session* session, State* state, Allocator allocator) @private
{
	Scan scan;
	scan.init(allocator, session);
	win32_user::enum_windows(&enum_proc, (iptr)&scan);
	state.connection = Connection.CONNECTED;
	state.status = "";
	state.titles_available = true;
	state.windows = scan.windows.array_view();
	state.focused_window_id = "";
	String focused_desktop = "";
	String visible_desktop = "";
	for (sz i = 0; i < scan.windows.len(); i++)
	{
		windows::Window window = scan.windows.get(i);
		if (window.flags.focused)
		{
			state.focused_window_id = window.id;
			focused_desktop = window.workspace_id;
		}
		if (scan.on_current.get(i) && visible_desktop.len == 0) visible_desktop = window.workspace_id;
	}
	state.workspaces = win32_rules::workspaces_of(state.windows, focused_desktop, visible_desktop, allocator);
	state.outputs = { };
}

// The windows of one enumeration, and what each needs to know about the desktops.
struct Scan
{
	Allocator allocator;
	win32_vdm::IVirtualDesktopManager* manager;
	void* foreground;
	List{windows::Window} windows;
	List{bool} on_current;
}

fn void Scan.init(&self, Allocator allocator, Session* session)
{
	*self = { .allocator = allocator, .foreground = win32_user::get_foreground_window() };
	self.windows.init(allocator);
	self.on_current.init(allocator);
	if (session.has_manager) self.manager = session.manager.ptr;
}

// EnumWindows callback: lists the windows the Alt-Tab rules admit.
fn win32::Win32_BOOL enum_proc(void* hwnd, iptr lparam) @private
{
	Scan* scan = (Scan*)lparam;
	if (win32_rules::is_alt_tab_window(facts_of(hwnd)))
	{
		scan.add(hwnd);
	}
	return 1;
}

fn void Scan.add(&self, void* hwnd)
{
	bool current   = false;
	String desktop = "";
	if (self.manager != null)
	{
		if (try now_current = win32_vdm::on_current_desktop(self.manager, hwnd)) current = now_current;
		if (try desktop_id = win32_vdm::desktop_of(self.manager, hwnd)) desktop = desktop_id.format(self.allocator);
	}
	self.windows.push(window_of(hwnd, self, desktop));
	self.on_current.push(current);
}

// The facts the Alt-Tab rules need, read from the window.
fn win32_rules::WindowFacts facts_of(void* hwnd) @private
{
	uint style = (uint)get_style(hwnd);
	bool app   = (style & win32_rules::WS_EX_APPWINDOW) != 0;
	return {
		.visible = win32_user::is_window_visible(hwnd) != 0,
		.cloaked = is_cloaked(hwnd),
		.tool_window = (style & win32_rules::WS_EX_TOOLWINDOW) != 0,
		.app_window = app,
		.owner_is_self = app || owner_chain_ends_at(hwnd),
	};
}

fn iptr get_style(void* hwnd) @private
{
	return win32_user::get_window_long_ptr_w(hwnd, win32_rules::GWL_EXSTYLE);
}

// Whether DWM hides the window (another desktop, or the shell). A failed query means
// the attribute is not supported on this system; then nothing is treated as cloaked.
fn bool is_cloaked(void* hwnd) @private
{
	uint cloaked = 0;
	uint hr = win32_dwm::dwm_get_window_attribute(hwnd, win32_rules::DWMWA_CLOAKED, &cloaked, win32_rules::DWORD_BYTES);
	return hr == hresult::S_OK && cloaked != 0;
}

// Walk the owner chain the way Raymond Chen's Alt+Tab code does: the root owner, then
// its last active visible popup, until the walk settles. True when it ends at `hwnd`.
fn bool owner_chain_ends_at(void* hwnd) @private
{
	void* walk = null;
	void* next = get_root_owner(hwnd);
	while (next != walk)
	{
		walk = next;
		next = win32_user::get_last_active_popup(walk);
		if (win32_user::is_window_visible(next) != 0) break;
	}
	return walk == hwnd;
}

fn void* get_root_owner(void* hwnd) @private
{
	return win32_user::get_ancestor(hwnd, win32_rules::GA_ROOTOWNER);
}

// The allocator of a scan's strings.
fn Allocator allocator_of(Scan* scan) @private => scan.allocator;

// The window record for `hwnd`, with its strings in the scan's allocator.
fn windows::Window window_of(void* hwnd, Scan* scan, String desktop) @private
{
	uint process_id = 0;
	win32_user::get_window_thread_process_id(hwnd, &process_id);
	windows::WindowFlags flags;
	flags.focused = hwnd == scan.foreground;
	flags.minimized = win32_user::is_iconic(hwnd) != 0;
	flags.maximized = win32_user::is_zoomed(hwnd) != 0;
	windows::WindowFlags reported;
	reported.focused = true;
	reported.minimized = true;
	reported.maximized = true;
	Maybe{int} pid = { };
	if (process_id != 0) pid = maybe::value((int)process_id);
	return {
		.id = win32_rules::format_handle((ulong)(uptr)hwnd, scan.allocator),
		.title = window_text(hwnd, allocator_of(scan)),
		.app_id = class_name(hwnd, allocator_of(scan)),
		.icon_hint = image_name(process_id, scan.allocator),
		.pid = pid,
		.workspace_id = desktop,
		.output_id = "",
		.geometry = geometry_of(hwnd),
		.flags = flags,
		.reported = reported,
	};
}

// The title and the class of a window, "" when it has none or the text is not valid UTF-16.
fn String window_text(void* hwnd, Allocator allocator) @private
{
	Char16[TEXT_UNITS] buffer;
	int count = win32_user::get_window_text_w(hwnd, &buffer[0], (int)TEXT_UNITS);
	if (count <= 0) return "";
	return text::from_wide_units(allocator, buffer[0:(sz)count]) ?? "";
}

fn String class_name(void* hwnd, Allocator allocator) @private
{
	Char16[TEXT_UNITS] buffer;
	int count = win32_user::get_class_name_w(hwnd, &buffer[0], (int)TEXT_UNITS);
	if (count <= 0) return "";
	return text::from_wide_units(allocator, buffer[0:(sz)count]) ?? "";
}

// The executable's base name for a process, "" when it cannot be read (another user's
// elevated process, a process that has gone).
fn String image_name(uint process_id, Allocator allocator) @private
{
	if (process_id == 0) return "";
	void* process = win32_proc::open_process(win32_proc::PROCESS_QUERY_LIMITED_INFORMATION, 0, process_id);
	if (process == null) return "";
	defer close_process(process);
	Char16[PATH_UNITS] buffer;
	uint size = PATH_UNITS;
	if (win32_proc::query_full_process_image_name_w(
		process,
		win32_proc::PROCESS_NAME_WIN32,
		&buffer[0],
		&size
	) == 0) return "";
	@pool()
	{
		String path = text::from_wide_units(tmem, buffer[0:(sz)size]) ?? "";
		return win32_rules::executable_name(path).copy(allocator);
	};
}

fn void close_process(void* process) @private
{
	win32_proc::close_handle(process);
}

// The rectangle of a window in screen pixels.
fn Maybe{windows::Rect} geometry_of(void* hwnd) @private
{
	win32::Win32_RECT bounds;
	if (win32_user::get_window_rect(hwnd, &bounds) == 0) return { };
	windows::Rect rect = {
		.x = bounds.left,
		.y = bounds.top,
		.width = bounds.right - bounds.left,
		.height = bounds.bottom - bounds.top,
	};
	return maybe::value(rect);
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
		case CommandKind.FOCUS_WINDOW: return focus(window_handle(command.target)!);
		case CommandKind.CLOSE_WINDOW: return close_window(window_handle(command.target)!);
		case CommandKind.MINIMIZE_WINDOW: return minimize(window_handle(command.target)!);
		case CommandKind.MOVE_WINDOW_TO_WORKSPACE: return move_window(session, command);
		case CommandKind.SWITCH_WORKSPACE:
			return error::raise(
				error::UNSUPPORTED,
				error::Domain.INTERNAL,
				0,
				"switching virtual desktops is not supported"
			)~;
		case CommandKind.TOGGLE_FLOATING:
			return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "Windows has no floating state")~;
		case CommandKind.TOGGLE_FULLSCREEN:
			return error::raise(
				error::UNSUPPORTED,
				error::Domain.INTERNAL,
				0,
				"no documented API makes a window fullscreen"
			)~;
	}
}

// The HWND named by a window id.
fn void*? window_handle(String id) @private
{
	ulong value = win32_rules::parse_handle(id)!;
	return (void*)(uptr)value;
}

fn void? focus(void* hwnd) @private
{
	if (win32_user::set_foreground_window(hwnd) == 0) return errors::raise_last("SetForegroundWindow")~;
}

fn void? close_window(void* hwnd) @private
{
	if (win32_user::post_message_w(hwnd, win32_user::WM_CLOSE, 0, 0) == 0) return errors::raise_last("PostMessageW")~;
}

fn void minimize(void* hwnd) @private
{
	win32_user::show_window(hwnd, win32_user::SW_MINIMIZE);
}

fn void? move_window(Session* session, Command* command) @private
{
	if (!session.has_manager)
	{
		return error::raise(
			error::UNAVAILABLE,
			error::Domain.INTERNAL,
			0,
			"the virtual desktop manager is not available"
		)~;
	}
	void* hwnd   = window_handle(command.target)!;
	Guid desktop = guid::parse(command.destination)!;
	win32_vdm::move_to_desktop(session.manager.ptr, hwnd, desktop)!;
}