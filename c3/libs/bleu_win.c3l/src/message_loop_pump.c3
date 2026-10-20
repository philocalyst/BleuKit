<*
 Pumping the calling thread's message queue. Part of `bleu::win::message_loop`.

 `pump` is the blocking wait a thread uses when it has nothing else to do; it
 wakes for messages and for its timeout. `dispatch_pending` drains the queue
 without waiting, for a worker that learned from `bleu::rt`'s poller that
 messages are waiting (window-message mode).

 Source: `MsgWaitForMultipleObjectsEx` and `DispatchMessageW` (winuser.h;
 Learn: MsgWaitForMultipleObjectsEx, DispatchMessage). `QS_ALLINPUT` is
 computed from its definition in winuser.h, the same value bleu::rt uses.
*>
module bleu::win::message_loop @feat(WIN32) @link("user32");
import std::os::win32, std::time;
import bleu::error;
import bleu::win::errors;

<* `QS_ALLINPUT` (winuser.h): every queue status bit that counts as input or posted work: 0x1CFF. *>
const uint QS_ALLINPUT                  = 0x1cff;
<* `MWMO_INPUTAVAILABLE` (winuser.h): return when input exists, even if already seen. *>
const uint MWMO_INPUTAVAILABLE          = 0x0004;
<* Microseconds in a millisecond, to convert a `Duration` for the Win32 wait. *>
const long MICROSECONDS_PER_MILLISECOND = 1000;

extern fn uint msgWaitForMultipleObjectsEx(
	uint count,
	void* handles,
	uint milliseconds,
	uint wake_mask,
	uint flags
) @cname("MsgWaitForMultipleObjectsEx");
extern fn Win32_LRESULT dispatchMessageW(win32::Win32_MSG* message) @cname("DispatchMessageW");

<* Dispatch every message already queued on the calling thread. Returns when the queue is empty. *>
fn void dispatch_pending()
{
	win32::Win32_MSG message;
	while (win32::peekMessageW(&message, null, 0, 0, win32::PM_REMOVE) != 0)
	{
		win32::translateMessage(&message);
		dispatchMessageW(&message);
	}
}

<*
 Wait for input on the calling thread's queue for up to `timeout`, dispatch
 what arrived, and return. Sub-millisecond timeouts round up to a millisecond.

 @param timeout : "How long to wait; `time::FOREVER` waits without limit"
 @return "True when messages were dispatched, false when the timeout passed first"
 @return? error::BACKEND_FAILURE : "MsgWaitForMultipleObjectsEx failed"
*>
fn bool? pump(time::Duration timeout)
{
	uint milliseconds = timeout == time::FOREVER ? win32::INFINITE : wait_milliseconds(timeout);
	uint result       = msgWaitForMultipleObjectsEx(0, null, milliseconds, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
	if (result == win32::WAIT_FAILED) return errors::raise_last("MsgWaitForMultipleObjectsEx")~;
	if (result == win32::WAIT_TIMEOUT) return false;
	dispatch_pending();
	return true;
}

<* A `Duration` as a Win32 wait, in milliseconds, rounded up and clamped below `INFINITE`. *>
fn uint wait_milliseconds(time::Duration timeout) @local
{
	long microseconds = (long)timeout;
	if (microseconds <= 0) return 0;
	long milliseconds = (microseconds + MICROSECONDS_PER_MILLISECOND - 1) / MICROSECONDS_PER_MILLISECOND;
	if (milliseconds >= win32::INFINITE) return win32::INFINITE - 1;
	return (uint)milliseconds;
}