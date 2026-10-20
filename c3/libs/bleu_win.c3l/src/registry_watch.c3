<*
 Watching a key for changes, as a waitable handle for `bleu::rt`'s poller.
 Part of `bleu::win::registry`.

 A watch is one-shot: `RegNotifyChangeKeyValue` signals the event once, then
 the watch must be re-armed. Re-arm before re-reading the state, not after, so
 a change made while the state is being read is still reported. Sources:
 winreg.h, winbase.h (`CreateEventW`); Learn "RegNotifyChangeKeyValue".
*>
module bleu::win::registry @feat(WIN32) @link("advapi32");
import std::os::win32;
import bleu::error;
import bleu::win::errors;

<* `REG_NOTIFY_CHANGE_NAME`: a subkey was added or removed. winnt.h. *>
const uint REG_NOTIFY_CHANGE_NAME       = 0x00000001;
<* `REG_NOTIFY_CHANGE_ATTRIBUTES`: an attribute or security descriptor changed. winnt.h. *>
const uint REG_NOTIFY_CHANGE_ATTRIBUTES = 0x00000002;
<* `REG_NOTIFY_CHANGE_LAST_SET`: a value was added, changed or removed. winnt.h. *>
const uint REG_NOTIFY_CHANGE_LAST_SET   = 0x00000004;

extern fn Win32_LSTATUS regNotifyChangeKeyValue(
	void* key,
	Win32_BOOL watch_subtree,
	uint filter,
	void* event,
	Win32_BOOL asynchronous
) @cname("RegNotifyChangeKeyValue");
extern fn void* createEventW(
	void* attributes,
	Win32_BOOL manual_reset,
	Win32_BOOL initial_state,
	WString name
) @cname("CreateEventW");

<*
 A key under watch. Owns the key it was made from and the event handle.
 `handle` is the event: it becomes signalled when the key changes.
*>
struct Watch
{
	Key key;
	void* event;
}

<*
 Start watching `key` for changes to its subkeys, values and attributes. The
 watch takes ownership of the key; `Watch.close` releases it. The key must have
 been opened with `KEY_NOTIFY` (`KEY_READ` includes it).

 @return "A watch that is armed: its handle is signalled at the next change"
 @return? error::BACKEND_FAILURE : "The event could not be created or the key could not be armed"
*>
fn Watch? watch_key(Key key)
{
	void* event = createEventW(null, 0, 0, null);
	if (!event)
	{
		key.close();
		return errors::raise_last("CreateEventW")~;
	}
	Watch watch = { .key = key, .event = event };
	if (catch failure = watch.arm())
	{
		watch.close();
		return failure~;
	}
	return watch;
}

<*
 Re-arm the watch after its handle was signalled (or once before the first wait).
 Call it before re-reading the key's state.

 @return? error::BACKEND_FAILURE : "RegNotifyChangeKeyValue failed"
*>
fn void? Watch.arm(&self)
{
	uint filter = REG_NOTIFY_CHANGE_NAME | REG_NOTIFY_CHANGE_ATTRIBUTES | REG_NOTIFY_CHANGE_LAST_SET;
	uint status = (uint)regNotifyChangeKeyValue(self.key.handle, 0, filter, self.event, 1);
	if (status != ERROR_SUCCESS) return errors::raise_win32(status, "RegNotifyChangeKeyValue")~;
}

<*
 The waitable event handle, for `bleu::rt`'s poller. The watch owns it; do not
 close it. Valid until `close`.
*>
fn void* Watch.handle(&self) @inline => self.event;

<* Release the event and the key. Safe to call once; the watch must not be used afterwards. *>
fn void Watch.close(&self)
{
	if (self.event) win32::closeHandle(self.event);
	self.key.close();
	self.event = null;
}