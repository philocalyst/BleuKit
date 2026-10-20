<*
 Window message numbers, the application message allocator and the word
 decoding that `bleu::win::message_loop` uses. No Win32 import, so the logic is
 unit-tested on every host.

 Sources (each value checked against mingw-w64 `winuser.h`, the `windows-sys`
 0.59.0 crate and Microsoft Learn; docs/research/bleu_win.md, section 7):
 * `WM_APP` and the application range 0x8000 through 0xBFFF: Learn "WM_APP".
 * `WM_HOTKEY` 0x0312 and its wParam/lParam layout: Learn "WM_HOTKEY".
 * `RegisterWindowMessageW` range 0xC000 through 0xFFFF: Learn "RegisterWindowMessage" (see `FIRST_NAMED_MESSAGE`).
 * `WM_CLIPBOARDUPDATE` 0x031D: Learn "WM_CLIPBOARDUPDATE".
 * `LOWORD` and `HIWORD`: mingw-w64 `minwindef.h`, Wine `include/minwindef.h`.
*>
module bleu::win::message_codes;
import bleu::error;

<* `WM_APP`: the base of the application-private messages. winuser.h. *>
const uint WM_APP               = 0x8000;
<* The message `Loop.post_wake` sends: `WM_APP` plus one. *>
const uint WM_WAKE              = WM_APP + 1;
<*
 `WM_HOTKEY`: a hot key registered with `RegisterHotKey` was pressed. wParam is
 the hot key's id; lParam's low word holds the modifiers and its high word the
 virtual-key code.
*>
const uint WM_HOTKEY            = 0x0312;
<* `WM_CLIPBOARDUPDATE`: the clipboard contents changed. Sent to windows added with `AddClipboardFormatListener`. *>
const uint WM_CLIPBOARDUPDATE   = 0x031d;
<* The first id `Loop.allocate_message` hands out: `WM_APP` plus two, clear of `WM_WAKE`. *>
const uint FIRST_CUSTOM_MESSAGE = WM_APP + 2;
<* The last id `Loop.allocate_message` hands out: 0xBFFF, the end of the application range. *>
const uint LAST_CUSTOM_MESSAGE  = 0xbfff;
<*
 The first id `RegisterWindowMessageW` returns. Learn "RegisterWindowMessage": a registered
 message is "in the range 0xC000 through 0xFFFF". (Single source for the range; mingw-w64
 winuser.h and windows-sys 0.59.0 declare the function but do not state the range.)
*>
const uint FIRST_NAMED_MESSAGE  = 0xc000;
<* The last id `RegisterWindowMessageW` returns: 0xFFFF (Learn "RegisterWindowMessage"). *>
const uint LAST_NAMED_MESSAGE   = 0xffff;

<*
 The application messages a loop has handed out. `next` is the id the next
 `allocate` returns. Ids are never reused, so every custom message the window
 receives is one this loop allocated.
*>
struct CustomMessages
{
	uint next;
}

<*
 Hand out the next unused id in the application range.

 @return? CAPACITY_EXCEEDED : "Every id from FIRST_CUSTOM_MESSAGE to LAST_CUSTOM_MESSAGE is in use"
*>
fn uint? CustomMessages.allocate(&self)
{
	if (self.next > LAST_CUSTOM_MESSAGE)
	{
		return error::raise(
			CAPACITY_EXCEEDED,
			error::Domain.INTERNAL,
			0,
			"every application message id from 0x%x to 0x%x is in use",
			FIRST_CUSTOM_MESSAGE,
			LAST_CUSTOM_MESSAGE
		)~;
	}
	uint message = self.next;
	self.next++;
	return message;
}

<* Whether `message` is one these allocations have handed out so far. *>
fn bool CustomMessages.owns(self, uint message) => message >= FIRST_CUSTOM_MESSAGE && message < self.next;

<* Whether `id` lies in the range `RegisterWindowMessageW` answers with, so it cannot clash with an application id. *>
fn bool is_named_message(uint id) => id >= FIRST_NAMED_MESSAGE && id <= LAST_NAMED_MESSAGE;

<* `LOWORD`: the low 16 bits of a packed word, such as the modifiers in a `WM_HOTKEY` lParam. *>
fn uint low_word(iptr packed) @inline => (uint)packed & 0xffff;

<* `HIWORD`: bits 16 to 31 of a packed word, such as the virtual-key code in a `WM_HOTKEY` lParam. *>
fn uint high_word(iptr packed) @inline => ((uint)packed >> 16) & 0xffff;