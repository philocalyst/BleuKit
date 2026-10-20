<*
 The Windows backend: our own icon in the notification area, with its menu. Shell_NotifyIconW
 (version 4) with a hidden window that receives its callbacks.

 It cannot list other applications' icons: Windows has no public API for that, so `HOST` is
 UNSUPPORTED_OS. The icon, its window and its menu run on the worker thread, which owns the
 window's messages. An icon the shell cannot load is shown as no icon, and `own_published` stays false.
 Explorer restarts drop every notification icon; the TaskbarCreated message re-adds ours.

 Sources: Microsoft Learn Shell_NotifyIconW, NOTIFYICONDATAW, NIM_SETVERSION and the callback
 values (LOWORD(lParam) is the event, GET_X/Y_LPARAM of wParam the anchor); tray-icon 0.21.0
 src/platform_impl/windows/mod.rs (legacy callback, TaskbarCreated re-add), read for lead only.
*>
module bleu::tray::windows_tray @feat(WIN32);
import std::os::win32, std::time, bleu::availability, bleu::error, bleu::rt::poller, bleu::rt::worker, bleu::service, bleu::tray, bleu::tray::convert, bleu::tray::windows_api, bleu::tray::windows_user, bleu::win::errors, bleu::win::message_loop, bleu::win::text, bleu::observe;

// The message the notification icon sends its window. WM_APP + 2, clear of the message loop's WM_APP + 1.
const uint TRAY_MESSAGE           = 0x8002;
// The identifier of our one notification icon.
const uint TRAY_ICON_ID           = 1;
// Bytes of one UTF-16 code unit.
const usz UTF16_UNIT_BYTES        = 2;
// The window's class and window styles: a hidden top-level window (see bleu::win::message_loop).
const uint HIDDEN_WINDOW_STYLE    = 0x80000000;
const uint HIDDEN_WINDOW_EX_STYLE = 0x00000080;
// The messages a window procedure sees first and must not treat as its own.
const uint WM_NCCREATE            = 0x0081;
// How long the worker sleeps between checks for a stop request, in microseconds.
const Duration WAIT_INTERVAL      = (Duration)1_000_000;

struct WinBackend
{
	Allocator allocator;
	bool publish_own;
	tray::OwnItem own;
	TrayHub* hub;
	WideZ class_name;
	void* instance;
	void* window;
	void* icon;
	uint taskbar_message;
	bool own_added;
}

// The create-struct the window procedure receives with WM_NCCREATE; its first field is the parameter.
struct CreateStructW
{
	void* create_params;
}

const Driver DRIVER = {
	.info = { "win32", "Shell_NotifyIconW notification icon", 10 },
	.id = WIN32,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

// Shell_NotifyIconW is always there on Windows.
fn bool probe(Options* options) => true;

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(
		availability::no(
			availability::Reason.UNSUPPORTED_OS,
			"Windows has no public API to list other applications' notification icons"
		)
	);
	if (options.publish_own)
	{
		capabilities.set(tray::Cap.PUBLISH_OWN_ICON, availability::YES);
		capabilities.set(tray::Cap.OWN_MENU, availability::YES);
	}
	else
	{
		capabilities.set(
			tray::Cap.PUBLISH_OWN_ICON,
			availability::no(availability::Reason.DISABLED_BY_POLICY, "publish_own is false")
		);
		capabilities.set(
			tray::Cap.OWN_MENU,
			availability::no(availability::Reason.DISABLED_BY_POLICY, "publish_own is false")
		);
	}
	WinBackend* backend = alloc::new(
		allocator,
		WinBackend,
		{ .allocator = allocator, .publish_own = options.publish_own }
	);
	backend.own = convert::copy_own(options.own, allocator);
	return backend;
}

fn void destroy(Allocator allocator, void* state)
{
	WinBackend* backend = (WinBackend*)state;
	convert::free_own(backend.own, allocator);
	alloc::free(allocator, backend);
}

// The worker: opens the icon, publishes, then dispatches the window's messages until stopped.
fn void run(void* state, TrayHub* hub, Host{tray::Command}* host)
{
	WinBackend* backend = (WinBackend*)state;
	backend.hub = hub;
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 2, true)) return;
	defer poller.free();
	if (backend.publish_own)
	{
		if (catch open_icon(backend))
		{
			// No window, no icon: the state says so, and the loop below still answers a stop.
		}
	}
	publish(backend);
	tray::Command[8] commands;
	while (!host.stopping())
	{
		if (catch poller.wait(WAIT_INTERVAL))
		{
			// TIMEOUT is the normal tick.
		}
		message_loop::dispatch_pending();
		// Nothing is posted to this backend (every item operation is refused), but a refresh is
		// still accepted: drain it so the queue cannot fill.
		usz count = host.mailbox().take_all(commands[..]);
		(void)count;
	}
	close_icon(backend);
}

// Publish the state: our icon is either added or not.
fn void publish(WinBackend* backend)
{
	Snapshot{tray::State}* snapshot = backend.hub.begin();
	snapshot.value = { .own_published = backend.own_added };
	backend.hub.publish_if_changed(snapshot);
}

<*
 Register the window class, create the hidden window, load the icon, and add the notification icon.
 On failure everything created so far is released.
*>
fn void? open_icon(WinBackend* backend)
{
	backend.instance = win32::getModuleHandleW(null);
	backend.taskbar_message = windows_user::taskbar_created_message()!;
	String name = string::format(mem, "bleu.tray.%x", (uptr)backend);
	defer alloc::free(mem, name.ptr);
	backend.class_name = text::to_wide(backend.allocator, name)!;
	win32::Win32_WNDCLASSEXW wc = {
		.cbSize = win32::Win32_WNDCLASSEXW::size,
		.lpfnWndProc = &window_proc,
		.hInstance = backend.instance,
		.lpszClassName = backend.class_name.as_wstring(),
	};
	if (win32::registerClassExW(&wc) == 0)
	{
		fault failure = errors::raise_last("RegisterClassExW");
		backend.class_name.free();
		return failure~;
	}
	void* window = win32::createWindowExW(
		HIDDEN_WINDOW_EX_STYLE,
		backend.class_name.as_wstring(),
		null,
		HIDDEN_WINDOW_STYLE,
		0,
		0,
		0,
		0,
		null,
		null,
		backend.instance,
		backend
	);
	if (window == null)
	{
		fault failure = errors::raise_last("CreateWindowExW");
		win32::unregisterClassW(backend.class_name.as_wstring(), backend.instance);
		backend.class_name.free();
		return failure~;
	}
	backend.window = window;
	backend.icon = load_icon(backend.own.icon, backend.allocator);
	add_icon(backend)!;
}

// The icon file as an HICON, or null when it cannot be loaded (the icon is then shown empty).
fn void* load_icon(String path, Allocator allocator)
{
	if (path.len == 0) return null;
	if (try wide = text::to_wide(allocator, path))
	{
		defer wide.free();
		return windows_user::loadImageW(
			null,
			wide.as_wstring(),
			windows_user::IMAGE_ICON,
			0,
			0,
			windows_user::LR_LOADFROMFILE | windows_user::LR_DEFAULTSIZE
		);
	}
	return null;
}

// Add the notification icon and select version 4 for its callbacks. NIM_SETVERSION follows NIM_ADD.
fn void? add_icon(WinBackend* backend)
{
	windows_api::NotifyIconDataW data = icon_data(backend);
	uint flags                        = windows_api::NIF_MESSAGE | windows_api::NIF_TIP;
	if (backend.icon != null) flags |= windows_api::NIF_ICON;
	data.flags = flags;
	shell_icon(windows_api::NIM_ADD, &data)!;
	data.version = windows_api::NOTIFYICON_VERSION_4;
	shell_icon(windows_api::NIM_SETVERSION, &data)!;
	backend.own_added = true;
}

// The NOTIFYICONDATAW that names our icon, with the tooltip (the title) and the callback.
fn windows_api::NotifyIconDataW icon_data(WinBackend* backend)
{
	windows_api::NotifyIconDataW data = {
		.cb_size = windows_api::NotifyIconDataW::size,
		.hwnd = backend.window,
		.id = TRAY_ICON_ID,
		.callback_message = TRAY_MESSAGE,
		.icon = backend.icon,
	};
	if (try tip = text::to_wide(mem, backend.own.title))
	{
		sz room  = (sz)windows_api::TIP_UNITS - 1;
		sz units = tip.len() < room ? tip.len() : room;
		mem::copy(&data.tip[0], tip.units.ptr, (usz)units * UTF16_UNIT_BYTES);
		tip.free();
	}
	return data;
}

// Remove the icon and destroy the window, its class and its icon. Safe when nothing was opened.
fn void close_icon(WinBackend* backend)
{
	if (backend.own_added)
	{
		windows_api::NotifyIconDataW data = icon_data(backend);
		if (catch shell_icon(windows_api::NIM_DELETE, &data))
		{
		}
		backend.own_added = false;
	}
	if (backend.window != null)
	{
		win32::setWindowLongPtrW(backend.window, win32::GWLP_USERDATA, 0);
		win32::destroyWindow(backend.window);
		win32::unregisterClassW(backend.class_name.as_wstring(), backend.instance);
		backend.class_name.free();
		backend.window = null;
	}
	if (backend.icon != null)
	{
		win32::destroyIcon(backend.icon);
		backend.icon = null;
	}
}

fn void? shell_icon(uint message, windows_api::NotifyIconDataW* data)
{
	if (windows_api::shellNotifyIconW(message, data) == 0) return errors::raise_last("Shell_NotifyIconW")~;
}

// The window procedure: the icon's callbacks, the shell's restart message, and everything else by default.
fn Win32_LRESULT window_proc(void* window, uint message, uptr wparam, iptr lparam)
{
	if (message == WM_NCCREATE)
	{
		CreateStructW* create = (CreateStructW*)lparam;
		win32::setWindowLongPtrW(window, win32::GWLP_USERDATA, (iptr)create.create_params);
	}
	WinBackend* backend = (WinBackend*)win32::getWindowLongPtrW(window, win32::GWLP_USERDATA);
	if (backend != null)
	{
		handle(backend, window, message, wparam, lparam);
	}
	return win32::defWindowProcW(window, message, wparam, lparam);
}

fn void handle(WinBackend* backend, void* window, uint message, uptr wparam, iptr lparam)
{
	if (message == TRAY_MESSAGE)
	{
		callback(backend, window, wparam, lparam);
		return;
	}
	if (backend.taskbar_message != 0 && message == backend.taskbar_message)
	{
		// Explorer restarted and took our icon with it: add it again.
		if (catch add_icon(backend)) backend.own_added = false;
		publish(backend);
	}
}

// The version 4 callback: LOWORD(lParam) is the event, and wParam holds the anchor (x, y).
fn void callback(WinBackend* backend, void* window, uptr wparam, iptr lparam)
{
	uint event = (uint)((ulong)lparam & 0xFFFF);
	int x      = (int)(short)((ulong)wparam & 0xFFFF);
	int y      = (int)(short)(((ulong)wparam >> 16) & 0xFFFF);
	switch (event)
	{
		case windows_api::NIN_SELECT:
			emit(backend, tray::EventKind.OWN_ACTIVATED, 0, x, y);
		case windows_user::WM_CONTEXTMENU:
			show_menu(backend, window, x, y);
		default:
			return;
	}
}

// Show our menu at the anchor. The chosen entry, if any, is an event.
fn void show_menu(WinBackend* backend, void* window, int x, int y)
{
	if (backend.own.menu.len == 0) return;
	void*? menu = windows_user::create_menu();
	if (catch menu) return;
	defer windows_user::destroyMenu(menu);
	for (sz i = 0; i < backend.own.menu.len; i++)
	{
		append_entry(menu, backend.own.menu[i]);
	}
	win32::setForegroundWindow(window);
	int chosen = windows_user::track_menu(menu, x, y, window);
	if (chosen > 0) emit(backend, tray::EventKind.OWN_MENU_CLICKED, chosen, 0, 0);
}

// Deliver one event to the subscribers. Called on the worker thread, which owns the window.
fn void emit(WinBackend* backend, tray::EventKind kind, int menu_id, int x, int y)
{
	Snapshot{tray::Event}* packet = backend.hub.emit_begin();
	packet.value = { .kind = kind, .item_id = "", .menu_id = menu_id, .x = x, .y = y };
	backend.hub.emit(packet);
}

// Add one entry to the menu. An entry the system refuses is left out.
fn void append_entry(void* menu, tray::OwnMenuEntry entry)
{
	@pool()
	{
		String label = convert::win32_label(entry.label, tmem);
		if (try wide = text::to_wide(tmem, label))
		{
			uint flags = entry.enabled ? windows_user::MF_STRING : windows_user::MF_STRING | windows_user::MF_GRAYED;
			if (entry.is_separator)
			{
				if (catch windows_user::append_menu(menu, windows_user::MF_SEPARATOR, 0, null))
				{
				}
			}
			else
			{
				if (catch windows_user::append_menu(menu, flags, entry.id, wide.as_wstring()))
				{
				}
			}
		}
	};
}