<*
 Windows poller: WaitForMultipleObjects, or MsgWaitForMultipleObjects when
 window messages must be pumped on this thread.

 Sources:
 - WaitForMultipleObjects,
 https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-waitformultipleobjects
 nCount at most MAXIMUM_WAIT_OBJECTS (64); the return value minus WAIT_OBJECT_0 is
 the index of the object that satisfied the wait; WAIT_TIMEOUT and WAIT_FAILED.
 - MsgWaitForMultipleObjects,
 https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-msgwaitformultipleobjects
 nCount at most MAXIMUM_WAIT_OBJECTS minus one; WAIT_OBJECT_0 + nCount means
 input of the kind named by dwWakeMask is available.
 - QS_ALLINPUT = (QS_INPUT | QS_POSTMESSAGE | QS_TIMER | QS_PAINT | QS_HOTKEY | QS_SENDMESSAGE)
 (the formula on https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getqueuestatus),
 with the QS_* values from Wine's include/winuser.h (QS_KEY 0x0001, QS_MOUSEMOVE 0x0002,
 QS_MOUSEBUTTON 0x0004, QS_POSTMESSAGE 0x0008, QS_TIMER 0x0010, QS_PAINT 0x0020,
 QS_SENDMESSAGE 0x0040, QS_HOTKEY 0x0080, QS_RAWINPUT 0x0400, QS_TOUCH 0x0800,
 QS_POINTER 0x1000), which gives 0x1CFF on current SDKs.

 A waitable object does not say whether it became readable, writable or hung up,
 so each signalled object is reported as readable. Sockets are not waitable
 handles: a socket source is an event handle associated with it by
 WSAEventSelect, which the caller creates.
*>
module bleu::rt::poller @feat(WIN32);
import std::os::win32, std::time, bleu::rt, bleu::deadline, bleu::error, bleu::rt::wakeup;

<* A waitable handle, as WaitForMultipleObjects takes it. *>
alias NativeWait = Win32_HANDLE;

<* MAXIMUM_WAIT_OBJECTS: the most handles one wait call accepts (winnt.h, 64). *>
const usz MAXIMUM_WAIT_OBJECTS = 64;

<* Window-message mode accepts one handle fewer than a plain wait (MsgWaitForMultipleObjects). *>
const usz MESSAGE_WAIT_OBJECTS = MAXIMUM_WAIT_OBJECTS - 1;

// Queue status flags (Wine winuser.h, see the sources above).
const Win32_DWORD QS_KEY         = 0x0001;
const Win32_DWORD QS_MOUSEMOVE   = 0x0002;
const Win32_DWORD QS_MOUSEBUTTON = 0x0004;
const Win32_DWORD QS_POSTMESSAGE = 0x0008;
const Win32_DWORD QS_TIMER       = 0x0010;
const Win32_DWORD QS_PAINT       = 0x0020;
const Win32_DWORD QS_SENDMESSAGE = 0x0040;
const Win32_DWORD QS_HOTKEY      = 0x0080;
const Win32_DWORD QS_RAWINPUT    = 0x0400;
const Win32_DWORD QS_TOUCH       = 0x0800;
const Win32_DWORD QS_POINTER     = 0x1000;
const Win32_DWORD QS_INPUT       = QS_MOUSEMOVE | QS_MOUSEBUTTON | QS_KEY | QS_RAWINPUT | QS_TOUCH | QS_POINTER;
const Win32_DWORD QS_ALLINPUT    = QS_INPUT | QS_POSTMESSAGE | QS_TIMER | QS_PAINT | QS_HOTKEY | QS_SENDMESSAGE;

<* bWaitAll = FALSE: return when any one handle is signalled. *>
const Win32_BOOL WAIT_FOR_ANY = 0;

fn void? native_check_limits(usz capacity, bool window_messages) @private
{
	usz limit = window_messages ? MESSAGE_WAIT_OBJECTS : MAXIMUM_WAIT_OBJECTS;
	// The wake-up takes one handle of the limit.
	if (capacity + 1 > limit)
	{
		return error::raise(
			error::OUT_OF_RANGE,
			error::Domain.INTERNAL,
			0,
			"a Windows wait holds at most %d handles",
			limit
		)~;
	}
}

fn usz? native_wait(Poller* self, Deadline deadline) @private
{
	usz handles = self.count + 1;
	self.entries[0] = self.wakeup.read_end;
	for (usz i = 0; i < self.count; i++) self.entries[i + 1] = self.sources[i].handle;
	while (true)
	{
		Win32_DWORD timeout = wait_timeout_ms(deadline);
		Win32_DWORD result  = self.window_messages ? win32::msgWaitForMultipleObjects(
			(Win32_DWORD)handles,
			self.entries.ptr,
			WAIT_FOR_ANY,
			timeout,
			QS_ALLINPUT
		)
			: win32::waitForMultipleObjects((Win32_DWORD)handles, self.entries.ptr, WAIT_FOR_ANY, timeout);
		if (result == win32::WAIT_FAILED)
		{
			return error::raise(
				error::BACKEND_FAILURE,
				error::Domain.WIN32,
				(int)win32::getLastError(),
				"wait failed"
			)~;
		}
		if (result == win32::WAIT_TIMEOUT)
		{
			if (deadline.expired()) return TIMEOUT~;
			continue;
		}
		return collect_ready(self, (usz)(result - win32::WAIT_OBJECT_0));
	}
}

// Milliseconds left for the wait; INFINITE for an unbounded one.
fn Win32_DWORD wait_timeout_ms(Deadline deadline) @private
{
	Duration left = deadline.remaining();
	if (left == time::FOREVER) return win32::INFINITE;
	return (Win32_DWORD)min(duration_ceil_ms(left), (long)win32::INFINITE - 1);
}

// Report the object (or window messages) that satisfied the wait, then sweep the
// others with a zero timeout so that every signalled object is reported once.
fn usz? collect_ready(Poller* self, usz index) @private
{
	usz handles = self.count + 1;
	usz n       = 0;
	if (self.window_messages && index == handles)
	{
		self.ready[n++] = { .tag = WINDOW_MESSAGES_TAG, .events = readable() };
	}
	else if (index >= handles)
	{
		return error::raise(
			error::BACKEND_FAILURE,
			error::Domain.WIN32,
			0,
			"wait returned index %d of %d",
			index,
			handles
		)~;
	}
	for (usz i = 0; i < handles; i++)
	{
		bool signalled = i == index || win32::waitForSingleObject(self.entries[i], 0) == win32::WAIT_OBJECT_0;
		if (!signalled) continue;
		usz tag = i == 0 ? WAKEUP_TAG : self.sources[i - 1].tag;
		self.ready[n++] = { .tag = tag, .events = readable() };
	}
	return n;
}

fn Interest readable() @private
{
	Interest events;
	events.readable = true;
	return events;
}