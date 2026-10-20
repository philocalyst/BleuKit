<*
 The Windows backend: the installed keyboard layouts and the layout of the foreground window, polled.

 Calls (Windows SDK, winuser.h and winnls.h as in the mingw-w64 headers, read 2026-10-20; Learn pages for the
 semantics):
 GetKeyboardLayoutList(int, HKL*) -> int: the input locale identifiers installed in the session.
 GetForegroundWindow() -> HWND, GetWindowThreadProcessId(HWND, LPDWORD) -> DWORD (thread id).
 GetKeyboardLayout(DWORD thread) -> HKL: "the input locale identifier for the thread" (bound by std::os::win32).
 LCIDToLocaleName(LCID, LPWSTR, int, DWORD) and GetLocaleInfoEx(LPCWSTR, LCTYPE, LPWSTR, int) for the BCP-47
 tag and the English display name; LOCALE_SENGLISHDISPLAYNAME = 0x72 (winnls.h).
 PostMessageW(HWND, WM_INPUTLANGCHANGEREQUEST = 0x0050, wParam = 0, lParam = HKL): DefWindowProc then activates
 the locale on that window's thread and sends WM_INPUTLANGCHANGE (Learn, WM_INPUTLANGCHANGEREQUEST).

 Per thread, honestly: a keyboard layout belongs to a thread, not to the system. The layout reported here is the
 one of the thread that owns the foreground window, which is the one that receives the keys. Another process's
 layout is changed only by asking its window to do it (PostMessageW). ActivateKeyboardLayout is not used: it
 changes the calling thread's (or, with KLF_SETFORPROCESS, this process's) layout and cannot reach another
 application.

 Change detection is a poll: WM_INPUTLANGCHANGE is delivered only to the focused window's thread, which this
 service does not own. The poll interval is the latency of a change made outside this process. After a switch
 the next read follows after FOLLOW_UP.

 Not verified on Windows (compiled only): the behaviour of the foreground window's thread after the post.
*>
module bleu::input::windows_klayout @feat(WIN32);
import std::os::win32, std::time, bleu::availability, bleu::error, bleu::input, bleu::input::hkl, bleu::input::names, bleu::observe, bleu::operation, bleu::rt::poller, bleu::rt::worker, bleu::service, bleu::win::errors, bleu::win::text;

// WM_INPUTLANGCHANGEREQUEST (winuser.h).
const uint WM_INPUTLANGCHANGEREQUEST  = 0x0050;
// LOCALE_SENGLISHDISPLAYNAME (winnls.h): the English display name of a locale, "German (Germany)".
const uint LOCALE_SENGLISHDISPLAYNAME = 0x72;
// LOCALE_NAME_MAX_LENGTH (winnt.h): room for a locale name with its terminating NUL.
const usz LOCALE_NAME_CAPACITY        = 85;
// Commands the worker takes in one pass.
const usz COMMAND_BATCH               = 8;
// How long after a switch the next read waits, so the window has processed the request.
const Duration FOLLOW_UP              = (Duration)100_000;

extern fn int get_keyboard_layout_list(int capacity, Win32_HKL* list) @cname("GetKeyboardLayoutList") @link("user32");
extern fn Win32_HWND get_foreground_window() @cname("GetForegroundWindow") @link("user32");
extern fn Win32_DWORD get_window_thread_process_id(
	Win32_HWND window,
	Win32_DWORD* process
) @cname("GetWindowThreadProcessId") @link("user32");
extern fn int lcid_to_locale_name(
	Win32_DWORD lcid,
	Win32_WCHAR* name,
	int capacity,
	Win32_DWORD flags
) @cname("LCIDToLocaleName") @link("kernel32");
extern fn int get_locale_info_ex(
	Win32_WCHAR* locale,
	Win32_DWORD info_type,
	Win32_WCHAR* data,
	int capacity
) @cname("GetLocaleInfoEx") @link("kernel32");

<* The backend's state. There is nothing to open: every read is a call. *>
struct KeyboardBackend
{
	Allocator allocator;
	Duration poll;
}

const Driver DRIVER = {
	.info = {
		"win32",
		"keyboard layouts through user32 (GetKeyboardLayoutList and the foreground window's layout)",
		10
	},
	.id = Backend.WIN32,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

// The user32 calls exist on every Windows this targets: nothing to test.
fn bool probe(Options* options) => true;

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	capabilities.set(
		Cap.CURRENT,
		availability::no(
			availability::Reason.DEGRADED,
			"The layout of the foreground window's thread; read at each poll, so a change shows after one interval"
		)
	);
	capabilities.set(
		Cap.SWITCH,
		availability::no(
			availability::Reason.DEGRADED,
			"Asks the foreground window to change its layout; the window may ignore it, and the change shows at the next poll"
		)
	);
	capabilities.set(
		Cap.EVENTS,
		availability::no(
			availability::Reason.DEGRADED,
			"Polled: WM_INPUTLANGCHANGE reaches only the focused window's thread, which this service does not own"
		)
	);
	KeyboardBackend* backend = alloc::new(allocator, KeyboardBackend, { .allocator = allocator, .poll = options.poll });
	return backend;
}

fn void destroy(Allocator allocator, void* state)
{
	alloc::free(allocator, state);
}

<* The installed input locale identifiers, in the order Windows lists them. Empty when the call fails. *>
fn Win32_HKL[] installed(Allocator allocator) @private
{
	int total = get_keyboard_layout_list(0, null);
	if (total <= 0) return { };
	Win32_HKL[] handles = alloc::new_array(allocator, Win32_HKL, (sz)total);
	int copied          = get_keyboard_layout_list(total, handles.ptr);
	if (copied <= 0) return { };
	return handles[0:(sz)copied];
}

<*
 The layout of the thread that owns the foreground window, as an HKL value. False when there is no foreground
 window or its thread is gone.
*>
fn bool foreground_layout(uint* value) @private
{
	Win32_HWND window = get_foreground_window();
	if (window == null) return false;
	Win32_DWORD thread = get_window_thread_process_id(window, null);
	if (thread == 0) return false;
	*value = (uint)(usz)win32::getKeyboardLayout(thread);
	return true;
}

<*
 The BCP-47 tag of the locale a language identifier names, written into `buffer` (NUL-terminated). "" when
 Windows has no locale for it.
*>
fn String locale_tag(uint lcid, Win32_WCHAR[] buffer, Allocator allocator) @private
{
	int written = lcid_to_locale_name((Win32_DWORD)lcid, &buffer[0], (int)buffer.len, 0);
	if (written <= 1) return "";
	return text::from_wide_units(allocator, buffer[0:(sz)(written - 1)]) ?? "";
}

<* The English display name of the locale in `locale` (NUL-terminated). "" when Windows has none. *>
fn String locale_display_name(Win32_WCHAR* locale, Allocator allocator) @private
{
	Win32_WCHAR[LOCALE_NAME_CAPACITY] buffer;
	int written = get_locale_info_ex(locale, LOCALE_SENGLISHDISPLAYNAME, &buffer[0], (int)buffer.len);
	if (written <= 1) return "";
	return text::from_wide_units(allocator, buffer[0:(sz)(written - 1)]) ?? "";
}

<*
 The Layout for one input locale identifier. The id is its KLID text (hkl.c3). Callers hold a `@pool()`.
*>
fn Layout layout_of(Win32_HKL handle, Allocator allocator) @private
{
	uint value      = (uint)(usz)handle;
	Win32_WCHAR[LOCALE_NAME_CAPACITY] buffer;
	String language = locale_tag(hkl::lcid_of(value), buffer[..], allocator);
	// The display name is read from the buffer the tag lookup filled. After a failed lookup that buffer holds
	// no locale, so the name is not looked up at all.
	String name = language.len > 0 ? locale_display_name(&buffer[0], allocator) : "";
	return {
		.id = hkl::klid_text(value, allocator),
		.name = name.len > 0 ? name : language.copy(allocator),
		.short_code = names::short_code_from_tag(language, allocator),
		.language = language,
		.variant = "".copy(allocator),
	};
}

<* The state now. Empty when the list cannot be read. Its text is allocated in `allocator`. *>
fn State read_state(Allocator allocator) @private
{
	State state;
	@pool()
	{
		Win32_HKL[] handles = installed(tmem);
		Layout[] layouts    = alloc::new_array(allocator, Layout, handles.len);
		for (sz i = 0; i < handles.len; i++)
		{
			layouts[i] = layout_of(handles[i], allocator);
		}
		state.layouts = layouts;
		uint active = 0;
		if (foreground_layout(&active))
		{
			String active_id = hkl::klid_text(active, tmem);
			sz index         = input::index_of(layouts, active_id);
			if (index >= 0) state.current = { .value = (uint)index, .has_value = true };
		}
	};
	state.can_switch = input::can_switch_now(true, state.layouts.len);
	return state;
}

// Publish the layouts now.
fn void refresh(InputHub* hub) @private
{
	Snapshot{State}* snapshot = hub.begin();
	snapshot.value = read_state(snapshot.allocator());
	input::publish_state(hub, snapshot);
}

<*
 Ask the foreground window to switch to the layout whose KLID text is `id`. The window applies it when it
 processes the message.

 @return? NOT_FOUND : "No installed layout has that id"
 @return? error::UNAVAILABLE : "There is no foreground window to ask"
 @return? error::BACKEND_FAILURE : "PostMessageW failed, for instance because the window is gone"
*>
fn void? switch_to(String id) @private
{
	Win32_HWND window = get_foreground_window();
	if (window == null) return error::raise(
		error::UNAVAILABLE,
		error::Domain.INTERNAL,
		0,
		"no foreground window to ask"
	)~;
	uint wanted = 0;
	bool found  = false;
	@pool()
	{
		Win32_HKL[] handles = installed(tmem);
		for (sz i = 0; i < handles.len && !found; i++)
		{
			uint value = (uint)(usz)handles[i];
			if (hkl::klid_text(value, tmem) == id)
			{
				wanted = value;
				found = true;
			}
		}
	};
	if (!found) return NOT_FOUND~;
	if (win32::postMessageW(window, WM_INPUTLANGCHANGEREQUEST, (Win32_WPARAM)0, (Win32_LPARAM)(long)wanted) == 0)
	{
		return errors::raise_last("PostMessageW")~;
	}
}

fn void run(void* state, InputHub* hub, Host{Command}* host)
{
	KeyboardBackend* backend = (KeyboardBackend*)state;
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 1)) return;
	defer poller.free();
	refresh(hub);
	Command[COMMAND_BATCH] commands;
	Duration wait = backend.poll;
	while (!host.stopping())
	{
		// A timeout is normal: the layout is read at each poll interval.
		if (catch poller.wait(wait))
		{
			// Nothing ready.
		}
		wait = backend.poll;
		usz count = host.mailbox().take_all(commands[..]);
		for (usz i = 0; i < count; i++)
		{
			if (commands[i].kind != CommandKind.SWITCH_TO) continue;
			SwitchOperation* operation = commands[i].operation;
			if (catch err = switch_to(commands[i].id))
			{
				input::fail_switch(operation, err);
			}
			else
			{
				// The window applies the request on its own thread: the change is read again shortly.
				input::succeed_switch(operation, SwitchOutcome.QUEUED);
				wait = FOLLOW_UP;
			}
		}
		refresh(hub);
	}
}