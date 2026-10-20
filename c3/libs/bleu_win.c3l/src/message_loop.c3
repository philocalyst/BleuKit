<*
 A hidden window whose messages are dispatched on one thread and turned into
 typed `Event`s for the owner's callback.

 Why a hidden *top-level* window and not `HWND_MESSAGE`: a message-only window
 "does not receive broadcast messages" (Microsoft Learn, "Window Features",
 Message-Only Windows), and `WM_DISPLAYCHANGE` is "only sent to top-level
 windows" (Learn, WM_DISPLAYCHANGE). The window is a `WS_POPUP` that is never
 shown.

 Threads: the window and its messages belong to the thread that calls `open`.
 Callbacks run on that thread inside `@foreign_entry`, so they may use temporary
 memory. `Loop.post_wake` is the only call that may come from another thread.
 Pumping is in `message_loop_pump.c3`, power and device registrations in
 `message_loop_watch.c3`, clipboard-listener and hot-key registrations in
 `message_loop_register.c3`. Window message numbers are in `message_codes.c3`.

 Sources: winuser.h (mingw-w64; Wine `include/winuser.h`), dbt.h, and the Learn
 pages cited beside each constant (docs/research/bleu_win.md, section 7).
*>
module bleu::win::message_loop @feat(WIN32) @link("user32");
import std::os::win32, std::core::string, std::collections::list;
import bleu::error, bleu::rt::foreign;
import bleu::win::errors, bleu::win::guid, bleu::win::hresult, bleu::win::message_codes, bleu::win::session, bleu::win::text;

<* `WM_NCCREATE`: sent first; `lParam` is the `CREATESTRUCTW`. winuser.h. *>
const uint WM_NCCREATE          = 0x0081;
<* `WM_SETTINGCHANGE` (= `WM_WININICHANGE`): a system setting changed. winuser.h. *>
const uint WM_SETTINGCHANGE     = 0x001a;
<* `WM_DEVICECHANGE`: a device was added or removed, or the device tree changed. winuser.h. *>
const uint WM_DEVICECHANGE      = 0x0219;
<* `WM_POWERBROADCAST`: a power state or a registered power setting changed. winuser.h. *>
const uint WM_POWERBROADCAST    = 0x0218;
<* `WM_WTSSESSION_CHANGE`: a session was locked, unlocked, logged on or off. wtsapi32.h. *>
const uint WM_WTSSESSION_CHANGE = 0x02b1;

<* `PBT_POWERSETTINGCHANGE`: a registered power setting changed (wParam). winuser.h. *>
const uint PBT_POWERSETTINGCHANGE   = 0x8013;
<* `PBT_APMSUSPEND`: the system is suspending. winuser.h. *>
const uint PBT_APMSUSPEND           = 0x0004;
<* `PBT_APMRESUMESUSPEND`: the system resumed because of user input. winuser.h. *>
const uint PBT_APMRESUMESUSPEND     = 0x0007;
<* `PBT_APMRESUMEAUTOMATIC`: the system resumed without user input. winuser.h. *>
const uint PBT_APMRESUMEAUTOMATIC   = 0x0012;
<* `PBT_APMPOWERSTATUSCHANGE`: the AC or battery state changed. winuser.h. *>
const uint PBT_APMPOWERSTATUSCHANGE = 0x000a;

<* `DBT_DEVICEARRIVAL`: a device interface arrived (wParam of `WM_DEVICECHANGE`). dbt.h. *>
const uint DBT_DEVICEARRIVAL          = 0x8000;
<* `DBT_DEVICEREMOVECOMPLETE`: a device interface was removed. dbt.h. *>
const uint DBT_DEVICEREMOVECOMPLETE   = 0x8004;
<* `DBT_DEVNODES_CHANGED`: the device tree changed without naming a device. dbt.h. *>
const uint DBT_DEVNODES_CHANGED       = 0x0007;
<* `DBT_DEVTYP_DEVICEINTERFACE`: the broadcast block describes a device interface. dbt.h. *>
const uint DBT_DEVTYP_DEVICEINTERFACE = 0x00000005;

<* `WS_POPUP`: the hidden window's style. A pop-up that is never shown is not in the taskbar. *>
const uint HIDDEN_WINDOW_STYLE    = 0x80000000;
<* `WS_EX_TOOLWINDOW`: keeps the hidden window out of the task switcher. *>
const uint HIDDEN_WINDOW_EX_STYLE = 0x00000080;

<* What happened. Each kind sets the `Event` fields documented beside it. *>
enum EventKind : char
{
	POWER_SETTING,     // guid: the setting; code: its first data DWORD
	POWER_STATE,       // code: the PBT_* value (suspend, resume, power source change)
	DISPLAY_CHANGE,    // code: bits per pixel; width, height: the new resolution
	DEVICE_CHANGE,     // code: the DBT_* value; text: the device interface path, if any
	SESSION_CHANGE,    // code: the WTS_SESSION_* value; session: the session it concerns
	SETTING_CHANGE,    // code: the SPI_* value; text: the changed section name, or empty
	DPI_CHANGE,        // width, height: the new horizontal and vertical DPI
	WAKE,              // `Loop.post_wake` was called, from any thread
	CUSTOM_MESSAGE,    // message, wparam, lparam: a message from `Loop.allocate_message`, as posted
	CLIPBOARD_UPDATED, // the clipboard contents changed; after `Loop.add_clipboard_listener`
	HOTKEY,            // hotkey_id, modifiers, vk: a hot key from `Loop.register_hotkey` was pressed
}

<*
 One notification. Valid only during the callback: `text` lives in temporary
 memory, so copy it to keep it.
*>
struct Event
{
	EventKind kind;
	uint code;
	uint width;
	uint height;
	uint session;
	Guid guid;
	String text;
	uint message; // CUSTOM_MESSAGE: the id `Loop.allocate_message` returned
	uptr wparam; // CUSTOM_MESSAGE: the WPARAM the message was posted with
	iptr lparam; // CUSTOM_MESSAGE: the LPARAM the message was posted with
	uint hotkey_id; // HOTKEY: the id given to `Loop.register_hotkey` (WM_HOTKEY wParam)
	uint modifiers; // HOTKEY: the MOD_* flags held with the key (WM_HOTKEY lParam, low word)
	uint vk; // HOTKEY: the virtual-key code (WM_HOTKEY lParam, high word)
}

<*
 The owner's callback. `context` is the pointer given to `Loop.open`; `event`
 is valid only for the duration of the call.
*>
alias Handler = fn void(void* context, Event* event);

<*
 A hidden window and its registrations. Heap-allocated, because the window
 keeps a pointer to it: a `Loop` must not move between `open` and `close`.
*>
struct Loop
{
	Allocator allocator;
	void* window;
	void* instance;
	WideZ class_name;
	Handler handler;
	void* context;
	message_codes::CustomMessages custom;
	bool clipboard_listening;
	// The hot-key ids this loop registered and has not unregistered.
	List{uint} hotkeys;
}

<*
 The `CREATESTRUCTW` that `WM_NCCREATE` receives in `lParam` (winuser.h). Only
 `create_params` is read; the rest is kept so the layout is complete.
*>
struct CreateStructW
{
	void* create_params;
	void* instance;
	void* menu;
	void* parent;
	int height;
	int width;
	int y;
	int x;
	int style;
	WString name;
	WString class_name;
	uint extended_style;
}

<*
 `POWERBROADCAST_SETTING` (winuser.h): the setting's GUID, a DWORD length, then
 the data at offset 20.
*>
struct PowerBroadcastSetting
{
	Guid power_setting;
	uint data_length;
	char[1] data;
}

<*
 `DEV_BROADCAST_DEVICEINTERFACE_W` (dbt.h): the class GUID, then the
 NUL-terminated device path at offset 28.
*>
struct DeviceInterfaceBroadcast
{
	uint size;
	uint device_type;
	uint reserved;
	Guid class_guid;
	Char16[1] name;
}

<*
 Create the hidden window for this thread and register it for session
 notifications. The callback receives every event this module reports.

 @param allocator : "Where the `Loop` lives until `close`"
 @param handler : "Receives the events, on this thread"
 @param context : "Passed back to `handler` unchanged"
 @return "The loop, to be closed on this thread"
 @return? error::BACKEND_FAILURE : "A Win32 call failed; the error is in `error::last()`"
*>
fn Loop*? open(Allocator allocator, Handler handler, void* context)
{
	Loop* loop = alloc::new(allocator, Loop);
	loop.allocator = allocator;
	loop.handler = handler;
	loop.context = context;
	loop.custom.next = message_codes::FIRST_CUSTOM_MESSAGE;
	loop.clipboard_listening = false;
	loop.instance = win32::getModuleHandleW(null);
	// The class is unique per loop: it holds this loop's window procedure address.
	String name = string::format(tmem, "bleu.win.message_loop.%x", (uptr)loop);
	loop.class_name = text::to_wide(allocator, name)!!;
	win32::Win32_WNDCLASSEXW wc = {
		.cbSize = win32::Win32_WNDCLASSEXW::size,
		.lpfnWndProc = &window_proc,
		.hInstance = loop.instance,
		.lpszClassName = loop.class_name.as_wstring(),
	};
	if (win32::registerClassExW(&wc) == 0)
	{
		fault failure = errors::raise_last("RegisterClassExW");
		loop.class_name.free();
		alloc::free(allocator, loop);
		return failure~;
	}
	void* window = win32::createWindowExW(
		HIDDEN_WINDOW_EX_STYLE,
		loop.class_name.as_wstring(),
		null,
		HIDDEN_WINDOW_STYLE,
		0,
		0,
		0,
		0,
		null,
		null,
		loop.instance,
		loop
	);
	if (!window)
	{
		fault failure = errors::raise_last("CreateWindowExW");
		win32::unregisterClassW(loop.class_name.as_wstring(), loop.instance);
		loop.class_name.free();
		alloc::free(allocator, loop);
		return failure~;
	}
	loop.window = window;
	loop.hotkeys.init(allocator);
	if (catch failure = session::register(window))
	{
		loop.close();
		return failure~;
	}
	return loop;
}

<*
 Undo the registrations, destroy the window and free the loop. Must run on the
 thread that opened it. The loop must not be used afterwards.
*>
fn void Loop.close(&self)
{
	// Clear the owner pointer first: messages sent while the window is destroyed
	// must not reach a loop that is about to be freed.
	win32::setWindowLongPtrW(self.window, win32::GWLP_USERDATA, 0);
	// A failed removal leaves nothing behind that the destroyed window could still
	// receive, so the failure is not worth stopping the teardown for.
	if (self.clipboard_listening)
	{
		if (catch self.remove_clipboard_listener())
		{
		}
	}
	self.release_hotkeys();
	// Same reasoning for the session notifications.
	if (catch session::unregister(self.window))
	{
	}
	win32::destroyWindow(self.window);
	win32::unregisterClassW(self.class_name.as_wstring(), self.instance);
	self.class_name.free();
	self.hotkeys.free();
	Allocator allocator = self.allocator;
	alloc::free(allocator, self);
}

<*
 Post a `WAKE` event to the loop's thread. Safe from any thread: `PostMessageW`
 is the one window call that may be made across threads.

 @return? error::BACKEND_FAILURE : "PostMessageW failed, for instance because the window is gone"
*>
fn void? Loop.post_wake(&self)
{
	if (win32::postMessageW(self.window, message_codes::WM_WAKE, 0, 0) == 0) return errors::raise_last("PostMessageW")~;
}

<*
 Hand out a window message for this loop's own use, such as the callback message of a
 notification icon (`Shell_NotifyIconW`). Ids come from the application range, starting
 at `WM_APP` plus two, and are never reused. A message posted to this loop's window with
 an id from here is delivered as a `CUSTOM_MESSAGE` event. Call it on the thread that
 opened the loop.

 @return? CAPACITY_EXCEEDED : "Every id in the application range is in use"
*>
fn uint? Loop.allocate_message(&self) => self.custom.allocate();

<*
 Window procedure of every loop. `WM_NCCREATE` stores the owner's pointer in
 the window; every later message is turned into an `Event` and handed to the
 callback inside `@foreign_entry`. Everything else goes to `DefWindowProcW`.
*>
fn Win32_LRESULT window_proc(void* window, uint message, uptr wparam, iptr lparam)
{
	if (message == WM_NCCREATE)
	{
		CreateStructW* create = (CreateStructW*)lparam;
		win32::setWindowLongPtrW(window, win32::GWLP_USERDATA, (iptr)create.create_params);
	}
	Loop* loop = (Loop*)win32::getWindowLongPtrW(window, win32::GWLP_USERDATA);
	if (loop)
	{
		foreign::@foreign_entry()
		{
			dispatch(loop, message, wparam, lparam);
		};
	}
	return win32::defWindowProcW(window, message, wparam, lparam);
}

<* Translate one message into an `Event` and deliver it, if it is one this module reports. *>
fn void dispatch(Loop* loop, uint message, uptr wparam, iptr lparam) @local
{
	Event event;
	switch (message)
	{
		case WM_POWERBROADCAST:
			if (wparam != PBT_POWERSETTINGCHANGE)
			{
				event.kind = POWER_STATE;
				event.code = (uint)wparam;
				break;
			}
			PowerBroadcastSetting* setting = (PowerBroadcastSetting*)lparam;
			event.kind = POWER_SETTING;
			event.guid = setting.power_setting;
			event.code = setting.data_length >= 4 ? *(uint*)&setting.data[0] : 0;
		case win32::WM_DISPLAYCHANGE:
			event.kind = DISPLAY_CHANGE;
			event.code = (uint)wparam;
			event.width = (uint)lparam & 0xffff;
			event.height = ((uint)lparam >> 16) & 0xffff;
		case WM_DEVICECHANGE:
			event.kind = DEVICE_CHANGE;
			event.code = (uint)wparam;
			if (lparam != 0 && ((DeviceInterfaceBroadcast*)lparam).device_type == DBT_DEVTYP_DEVICEINTERFACE)
			{
				// A path the system wrote is valid UTF-16; an unreadable one is left empty.
				event.text = text::from_wide(tmem, (WString)&((DeviceInterfaceBroadcast*)lparam).name) ?? "";
			}
		case WM_SETTINGCHANGE:
			event.kind = SETTING_CHANGE;
			event.code = (uint)wparam;
			event.text = lparam != 0 ? text::from_wide(tmem, (WString)lparam) ?? "" : "";
		case win32::WM_DPICHANGED:
			event.kind = DPI_CHANGE;
			event.width = (uint)wparam & 0xffff;
			event.height = ((uint)wparam >> 16) & 0xffff;
		case WM_WTSSESSION_CHANGE:
			event.kind = SESSION_CHANGE;
			event.code = (uint)wparam;
			event.session = (uint)lparam;
		case message_codes::WM_HOTKEY:
			event.kind = HOTKEY;
			event.hotkey_id = (uint)wparam;
			event.modifiers = message_codes::low_word(lparam);
			event.vk = message_codes::high_word(lparam);
		case message_codes::WM_CLIPBOARDUPDATE:
			event.kind = CLIPBOARD_UPDATED;
		case message_codes::WM_WAKE:
			event.kind = WAKE;
		default:
			// Only the ids this loop handed out are the owner's; anything else is not reported.
			if (!loop.custom.owns(message)) return;
			event.kind = CUSTOM_MESSAGE;
			event.message = message;
			event.wparam = wparam;
			event.lparam = lparam;
	}
	loop.handler(loop.context, &event);
}