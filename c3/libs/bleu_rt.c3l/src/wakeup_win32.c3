<*
 Windows wake-up: a manual-reset event.

 `signal` is SetEvent, `drain` is ResetEvent. A manual-reset event stays
 signalled until it is reset, which is exactly the level-triggered behaviour
 the poller needs: a wait returns as long as a signal is pending. An auto-reset
 event would be consumed by the first wait that saw it, and a second wait
 would then miss a signal raised in between.

 Sources:
 - CreateEventA, https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-createeventa
 (bManualReset TRUE: "the state of a manual-reset event object remains
 signaled until it is set explicitly to the nonsignaled state by the ResetEvent function")
 - SetEvent, https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-setevent
 - ResetEvent, https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-resetevent
 - std::os::win32 (C3 0.8.5): createEventA, setEvent, resetEvent, closeHandle, getLastError
*>
module bleu::rt::wakeup @feat(WIN32);
import std::os::win32, bleu::error;

<* TRUE for CreateEventA's bManualReset, as a Win32_BOOL. *>
const Win32_BOOL MANUAL_RESET = 1;

fn void? native_open(Wakeup* self) @private
{
	Win32_HANDLE event = win32::createEventA(null, MANUAL_RESET, 0, null);
	if (!event)
	{
		return error::raise(
			error::BACKEND_FAILURE,
			error::Domain.WIN32,
			(int)win32::getLastError(),
			"CreateEvent failed"
		)~;
	}
	self.read_end = event;
	self.write_end = event;
}

fn void native_close(Wakeup* self) @private
{
	// One handle serves both ends; close it exactly once.
	(void)win32::closeHandle(self.read_end);
}

fn void? native_signal(Wakeup* self) @private
{
	if (win32::setEvent(self.write_end)) return;
	return error::raise_text(error::BACKEND_FAILURE, error::Domain.WIN32, (int)win32::getLastError(), "SetEvent failed")~;
}

fn void? native_drain(Wakeup* self) @private
{
	if (win32::resetEvent(self.read_end)) return;
	return error::raise(error::BACKEND_FAILURE, error::Domain.WIN32, (int)win32::getLastError(), "ResetEvent failed")~;
}