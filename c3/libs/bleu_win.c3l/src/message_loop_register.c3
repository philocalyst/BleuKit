<*
 Clipboard-change, hot-key and named-message registrations for a `Loop`'s window. Part of
 `bleu::win::message_loop`: they arrive as `CLIPBOARD_UPDATED` and `HOTKEY` events,
 through the same handler as every other event.

 Sources (user32; each signature and value checked against mingw-w64 `winuser.h`,
 Wine `include/winuser.h`, the `windows-sys` 0.59.0 crate and Microsoft Learn;
 docs/research/bleu_win.md, section 7):
 * `AddClipboardFormatListener` and `RemoveClipboardFormatListener`: Learn
 "AddClipboardFormatListener" (a window "is posted a WM_CLIPBOARDUPDATE message
 whenever the contents of the clipboard have changed"; desktop apps on Windows Vista
 and later).
 * `RegisterHotKey` and `UnregisterHotKey`: Learn "RegisterHotKey" (id range
 0x0000 through 0xBFFF; the `MOD_*` values; "The application must explicitly call
 UnregisterHotKey") and "UnregisterHotKey".
 * Error 1409 (`ERROR_HOTKEY_ALREADY_REGISTERED`) and 1419 (`ERROR_HOTKEY_NOT_REGISTERED`):
 Learn "System Error Codes (1300-1699)".
*>
module bleu::win::message_loop @feat(WIN32) @link("user32");
import std::os::win32;
import bleu::error;
import bleu::win::errors, bleu::win::hresult, bleu::win::message_codes, bleu::win::text;

<* `MOD_ALT`: the Alt key must be held with the key. winuser.h. *>
const uint MOD_ALT       = 0x0001;
<* `MOD_CONTROL`: the Ctrl key must be held with the key. winuser.h. *>
const uint MOD_CONTROL   = 0x0002;
<* `MOD_SHIFT`: the Shift key must be held with the key. winuser.h. *>
const uint MOD_SHIFT     = 0x0004;
<* `MOD_WIN`: the Windows key must be held with the key. winuser.h. *>
const uint MOD_WIN       = 0x0008;
<* `MOD_NOREPEAT`: no further `HOTKEY` while the keys stay down. winuser.h. *>
const uint MOD_NOREPEAT  = 0x4000;
<* The largest hot-key id an application may use. Learn "RegisterHotKey": 0x0000 through 0xBFFF. *>
const uint MAX_HOTKEY_ID = 0xbfff;

extern fn Win32_BOOL addClipboardFormatListener(void* window) @cname("AddClipboardFormatListener");
extern fn Win32_BOOL removeClipboardFormatListener(void* window) @cname("RemoveClipboardFormatListener");
extern fn Win32_BOOL registerHotKey(void* window, int id, uint modifiers, uint key) @cname("RegisterHotKey");
extern fn Win32_BOOL unregisterHotKey(void* window, int id) @cname("UnregisterHotKey");
extern fn uint registerWindowMessageW(WString name) @cname("RegisterWindowMessageW");

<*
 Ask for `CLIPBOARD_UPDATED` events whenever the clipboard contents change. Undo
 with `remove_clipboard_listener`, or let `close` do it.

 @return? error::BACKEND_FAILURE : "AddClipboardFormatListener failed"
*>
fn void? Loop.add_clipboard_listener(&self)
{
	if (addClipboardFormatListener(self.window) == 0) return errors::raise_last("AddClipboardFormatListener")~;
	self.clipboard_listening = true;
}

<* Stop the `CLIPBOARD_UPDATED` events. The loop stays open. *>
fn void? Loop.remove_clipboard_listener(&self)
{
	if (removeClipboardFormatListener(self.window) == 0) return errors::raise_last("RemoveClipboardFormatListener")~;
	self.clipboard_listening = false;
}

<*
 Register a system-wide hot key whose presses arrive as `HOTKEY` events on this loop.
 Undo it with `unregister_hotkey`, or let `close` do it. An id this loop already holds
 is refused: Learn says a second `RegisterHotKey` for the same window and id keeps the
 old registration as well, so the loop never makes that second one.

 @param id : "Chosen by the caller, 0 through 0xBFFF, unique within this loop"
 @param modifiers : "Any of MOD_ALT, MOD_CONTROL, MOD_SHIFT, MOD_WIN, MOD_NOREPEAT"
 @param vk : "The virtual-key code of the key (winuser.h VK_*)"
 @return? error::INVALID_ARGUMENT : "The id is above 0xBFFF"
 @return? error::INVALID_STATE : "This loop already holds a hot key with this id"
 @return? error::BUSY : "Another registration holds this key combination (Win32 1409)"
 @return? error::BACKEND_FAILURE : "RegisterHotKey failed for another reason"
*>
fn void? Loop.register_hotkey(&self, uint id, uint modifiers, uint vk)
{
	int native = native_hotkey_id(id)!;
	if (hotkey_index(self, id) >= 0)
	{
		return error::raise(
			error::INVALID_STATE,
			error::Domain.INTERNAL,
			(int)id,
			"hot-key id %d is already registered on this loop",
			id
		)~;
	}
	if (registerHotKey(self.window, native, modifiers, vk) == 0) return errors::raise_last("RegisterHotKey")~;
	self.hotkeys.push(id);
}

<*
 Undo `register_hotkey` for `id`. The system's answer that the key is not registered
 (1419) also drops the record, since there is nothing left to undo.

 @param id : "The id given to `register_hotkey`"
 @return? NOT_FOUND : "This loop holds no hot key with this id"
 @return? error::BACKEND_FAILURE : "UnregisterHotKey failed for another reason"
*>
fn void? Loop.unregister_hotkey(&self, uint id)
{
	sz index = hotkey_index(self, id);
	if (index < 0)
	{
		return error::raise(
			NOT_FOUND,
			error::Domain.INTERNAL,
			(int)id,
			"no hot key with id %d is registered on this loop",
			id
		)~;
	}
	if (unregisterHotKey(self.window, (int)id) == 0)
	{
		uint code = win32::getLastError();
		if (code != hresult::ERROR_HOTKEY_NOT_REGISTERED) return errors::raise_win32(code, "UnregisterHotKey")~;
	}
	self.hotkeys.remove_at(index);
}

<*
 Unregister every hot key this loop still holds, before its window is destroyed. A
 failure is ignored: the window goes next, and there is no caller left to report it to.
*>
fn void Loop.release_hotkeys(&self)
{
	foreach (id : self.hotkeys) (void)unregisterHotKey(self.window, (int)id);
	self.hotkeys.clear();
}

<*
 Register a window message by name, the same id in every process that registers the name
 (`RegisterWindowMessageW`). The shell broadcasts `TaskbarCreated` this way when Explorer starts
 again. A message sent to this loop's window with the id arrives as a `CUSTOM_MESSAGE` event. The
 registration lasts until the session ends. Call it on the thread that opened the loop.

 Sources: Learn "RegisterWindowMessage" (the return value is in 0xC000 through 0xFFFF; zero on failure);
 mingw-w64 winuser.h line 1504 and windows-sys 0.59.0 (`RegisterWindowMessageW(PCWSTR) -> u32`).

 @param name : "The message name, such as \"TaskbarCreated\""
 @return "The message id, in 0xC000 through 0xFFFF"
 @return? error::BACKEND_FAILURE : "RegisterWindowMessageW failed, or returned an id outside that range"
*>
fn uint? Loop.register_named_message(&self, String name)
{
	uint id = 0;
	@pool()
	{
		WideZ wide = text::to_wide(tmem, name)!;
		id = registerWindowMessageW(wide.as_wstring());
	};
	if (id == 0) return errors::raise_last("RegisterWindowMessageW")~;
	if (!message_codes::is_named_message(id))
	{
		return error::raise(
			error::BACKEND_FAILURE,
			error::Domain.INTERNAL,
			(int)id,
			"RegisterWindowMessageW returned 0x%x, outside 0xC000 to 0xFFFF",
			id
		)~;
	}
	if (!self.owns_named(id)) self.named_messages.push(id);
	return id;
}

<* Whether `message` is an id `register_named_message` has handed out. *>
fn bool Loop.owns_named(&self, uint message)
{
	foreach (id : self.named_messages)
	{
		if (id == message) return true;
	}
	return false;
}

<* The id as the `int` that `RegisterHotKey` takes, once it is checked against the range Learn gives. *>
fn int? native_hotkey_id(uint id) @local
{
	if (id > MAX_HOTKEY_ID)
	{
		return error::raise(
			error::INVALID_ARGUMENT,
			error::Domain.INTERNAL,
			(int)id,
			"hot-key id %d is above 0xBFFF",
			id
		)~;
	}
	return (int)id;
}

<* The position of `id` in the loop's list of registered hot keys, or -1. *>
fn sz hotkey_index(Loop* loop, uint id) @local
{
	for (sz i = 0; i < loop.hotkeys.len(); i++)
	{
		if (loop.hotkeys.get(i) == id) return i;
	}
	return -1;
}