<*
 The Win32 calls of the Windows backend: the workstation lock, the time since the last input,
 and the Terminal Services notifications of this session. The session calls themselves are in
 `bleu::win::session`; this file gives them the names the backend uses.

 Sources: LockWorkStation (user32.dll; Microsoft Learn "LockWorkStation": a nonzero result means
 the lock was started, not that it finished). GetLastInputInfo (user32.dll; Learn
 "GetLastInputInfo" and "LASTINPUTINFO": `cbSize` then `dwTime`, a tick count that is specific
 to the session). GetTickCount (kernel32.dll; a 32-bit millisecond count). Session notifications:
 `bleu::win::session`, and the WM_WTSSESSION_CHANGE codes below.
*>
module bleu::session::windows_native @feat(WIN32) @link("user32");
import std::os::win32, bleu::error, bleu::win::errors, bleu::win::session, bleu::win::process;

// WM_WTSSESSION_CHANGE, wParam: the session was locked or unlocked. Single source: Learn,
// "WM_WTSSESSION_CHANGE" (see docs/research/session_windows_input.md, section 2 "Windows").
const uint WTS_SESSION_LOCK   = 0x7;
const uint WTS_SESSION_UNLOCK = 0x8;

// LASTINPUTINFO (winuser.h): the size of the structure, and the tick count of the last input.
struct LastInputInfo
{
	uint size;
	uint last_input_tick;
}

$assert(LastInputInfo::size == 8);

extern fn Win32_BOOL lockWorkStation() @cname("LockWorkStation");
extern fn Win32_BOOL getLastInputInfo(LastInputInfo* info) @cname("GetLastInputInfo");
extern fn uint getTickCount() @cname("GetTickCount") @link("kernel32");

<*
 Start the workstation lock. The call returns when the lock has been started; the screen locks
 a moment later.

 @return? error::BACKEND_FAILURE : "LockWorkStation refused"
*>
fn void? lock_work_station()
{
	if (lockWorkStation() == 0) return errors::raise_last("LockWorkStation")~;
}

<*
 Milliseconds since the last keyboard, mouse or other input on this session's desktop.

 @return? error::BACKEND_FAILURE : "GetLastInputInfo failed"
*>
fn long? idle_milliseconds()
{
	LastInputInfo info = { .size = LastInputInfo::size };
	if (getLastInputInfo(&info) == 0) return errors::raise_last("GetLastInputInfo")~;
	// Both values are tick counts. Unsigned subtraction is the difference across one wrap of the
	// 32-bit counter (every 49.7 days), so the result is never negative.
	uint now = getTickCount();
	return (long)(now - info.last_input_tick);
}

<* Whether the workstation of this session is locked. Windows 8 and later (see `bleu::win::session`). *>
fn bool? is_session_locked()
{
	return session::is_locked(session::WTS_CURRENT_SESSION);
}

<* The Terminal Services session id of this process. *>
fn uint? current_session_id()
{
	return process::wts_session_id();
}

<* Ask for the session's lock and unlock messages on `window`. *>
fn void? register_session(void* window)
{
	session::register(window)!;
}

<* Stop the session's messages for `window`. *>
fn void? unregister_session(void* window)
{
	session::unregister(window)!;
}