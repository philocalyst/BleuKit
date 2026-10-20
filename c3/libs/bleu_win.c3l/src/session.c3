<*
 Terminal Services sessions: session change notifications for a window, and
 whether a session's workstation is locked.

 Sources: wtsapi32.h (mingw-w64; Wine `include/wtsapi32.h`), winuser.h
 (`WTS_SESSION_*` values), and Microsoft Learn "WTSRegisterSessionNotification"
 (Library Wtsapi32.lib), "WM_WTSSESSION_CHANGE", "WTSINFOEX_LEVEL1_W" and
 "WTS_SESSIONSTATE" (see docs/research/bleu_win.md, section 6).
*>
module bleu::win::session @feat(WIN32) @link("wtsapi32");
import std::os::win32;
import bleu::error, bleu::win::errors;

<* `NOTIFY_FOR_THIS_SESSION`: only events for the session the window is attached to. *>
const uint NOTIFY_FOR_THIS_SESSION = 0;
<* `WTS_CURRENT_SESSION`: the session the caller runs in. *>
const uint WTS_CURRENT_SESSION = 0xffffffff;
<* `WTSSessionInfoEx` (the `WTS_INFO_CLASS` value 25, wtsapi32.h). *>
const uint WTS_INFO_CLASS_SESSION_INFO_EX = 25;
<* `WTS_SESSIONSTATE_LOCK`: the session is locked (value 0; Windows 8 and later). *>
const uint WTS_SESSIONSTATE_LOCK = 0x00000000;
<* `WTS_SESSIONSTATE_UNLOCK`: the session is unlocked (value 1). *>
const uint WTS_SESSIONSTATE_UNLOCK = 0x00000001;

extern fn Win32_BOOL wtsRegisterSessionNotification(void* window, uint flags) @cname("WTSRegisterSessionNotification");
extern fn Win32_BOOL wtsUnRegisterSessionNotification(void* window) @cname("WTSUnRegisterSessionNotification");
extern fn Win32_BOOL wtsQuerySessionInformationW(void* server, uint session, uint info_class, void** buffer, uint* bytes) @cname("WTSQuerySessionInformationW");
extern fn void wtsFreeMemory(void* memory) @cname("WTSFreeMemory");

<*
 The part of `WTSINFOEXW` (level 1) that this module reads. The union that
 follows `Level` holds `LARGE_INTEGER`s, so it starts at offset 8, not 4.
 Offsets: Level 0; union 8 (session id 8, connect state 12, session flags 16).
*>
struct WtsInfoEx
{
	uint level;
	uint union_alignment;
	uint session_id;
	int connect_state;
	int session_flags;
}

<*
 Ask `wnd` to receive `WM_WTSSESSION_CHANGE` for its own session. Undo with
 `unregister`. A window may be registered only once.

 @param window : "A window owned by the calling thread"
 @return? error::BACKEND_FAILURE : "WTSRegisterSessionNotification failed"
*>
fn void? register(void* window)
{
	if (wtsRegisterSessionNotification(window, NOTIFY_FOR_THIS_SESSION) == 0) return errors::raise_last("WTSRegisterSessionNotification")~;
}

<*
 Stop session notifications for `window`. Failures are reported but the window
 is still usable: the caller is about to destroy it anyway.

 @param window : "A window registered with `register`"
*>
fn void? unregister(void* window)
{
	if (wtsUnRegisterSessionNotification(window) == 0) return errors::raise_last("WTSUnRegisterSessionNotification")~;
}

<*
 Whether the workstation of `session` is locked.

 @param session : "A session id, such as `WTS_CURRENT_SESSION`"
 @return "True when the session is locked, false when unlocked"
 @return? error::UNAVAILABLE : "The system reports the lock state as unknown"
*>
fn bool? is_locked(uint session)
{
	void* buffer = null;
	uint bytes = 0;
	if (wtsQuerySessionInformationW(null, session, WTS_INFO_CLASS_SESSION_INFO_EX, &buffer, &bytes) == 0)
	{
		return errors::raise_last("WTSQuerySessionInformation(WTSSessionInfoEx)")~;
	}
	defer wtsFreeMemory(buffer);
	if (bytes < WtsInfoEx.size) return error::raise(error::PROTOCOL, error::Domain.WIN32, 0, "WTSSessionInfoEx is %d bytes", bytes)~;
	WtsInfoEx* info = (WtsInfoEx*)buffer;
	switch (info.session_flags)
	{
		case (int)WTS_SESSIONSTATE_LOCK:   return true;
		case (int)WTS_SESSIONSTATE_UNLOCK: return false;
		default:
			return error::raise(error::UNAVAILABLE, error::Domain.WIN32, info.session_flags,
				"the lock state of session %d is unknown", session)~;
	}
}
