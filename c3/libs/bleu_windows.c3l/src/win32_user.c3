<*
 The user32 functions the Windows backend calls, and the window messages and
 show commands it sends. Declared here because `std::os::win32` does not bind
 every one, and its `DwmGetWindowAttribute` takes the handle by pointer.

 Values: winuser.h, checked against mingw-w64 `winuser_mingw.h` and windows-sys 0.59.0
 `UI/WindowsAndMessaging/mod.rs` (line numbers in docs/research/windows_impl.md).
*>
module bleu::windows::win32_user @feat(WIN32) @link("user32");
import std::os::win32;

// WM_CLOSE asks a window to close, as its close button would.
const uint WM_CLOSE   = 0x0010;
// SW_MINIMIZE minimizes the window and activates the next one.
const int SW_MINIMIZE = 6;

<* The callback EnumWindows calls for each top-level window. Return nonzero to continue. *>
alias EnumWindowsProc = fn win32::Win32_BOOL(void* hwnd, iptr lparam);
<* The callback of SetWinEventHook (WINEVENTPROC). *>
alias WinEventProc = fn void(
	void* hook,
	uint event,
	void* hwnd,
	int id_object,
	int id_child,
	uint thread_id,
	uint event_time
);

extern fn win32::Win32_BOOL enum_windows(EnumWindowsProc callback, iptr lparam) @cname("EnumWindows");
extern fn void* get_ancestor(void* hwnd, uint flags) @cname("GetAncestor");
extern fn void* get_last_active_popup(void* hwnd) @cname("GetLastActivePopup");
extern fn win32::Win32_BOOL is_window_visible(void* hwnd) @cname("IsWindowVisible");
extern fn win32::Win32_BOOL is_window(void* hwnd) @cname("IsWindow");
extern fn win32::Win32_BOOL is_iconic(void* hwnd) @cname("IsIconic");
extern fn win32::Win32_BOOL is_zoomed(void* hwnd) @cname("IsZoomed");
extern fn void* get_foreground_window() @cname("GetForegroundWindow");
extern fn int get_window_text_w(void* hwnd, Char16* text, int max_count) @cname("GetWindowTextW");
extern fn int get_class_name_w(void* hwnd, Char16* text, int max_count) @cname("GetClassNameW");
extern fn uint get_window_thread_process_id(void* hwnd, uint* process_id) @cname("GetWindowThreadProcessId");
extern fn win32::Win32_BOOL get_window_rect(void* hwnd, win32::Win32_RECT* rect) @cname("GetWindowRect");
extern fn iptr get_window_long_ptr_w(void* hwnd, int index) @cname("GetWindowLongPtrW");
extern fn win32::Win32_BOOL set_foreground_window(void* hwnd) @cname("SetForegroundWindow");
extern fn win32::Win32_BOOL show_window(void* hwnd, int command) @cname("ShowWindow");
extern fn win32::Win32_BOOL post_message_w(void* hwnd, uint message, uptr wparam, iptr lparam) @cname("PostMessageW");
extern fn void* set_win_event_hook(
	uint event_min,
	uint event_max,
	void* hmod,
	WinEventProc proc,
	uint process_id,
	uint thread_id,
	uint flags
) @cname("SetWinEventHook");
extern fn win32::Win32_BOOL unhook_win_event(void* hook) @cname("UnhookWinEvent");