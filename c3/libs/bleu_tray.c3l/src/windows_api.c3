<*
 The notification-area calls of shell32 that std::os::win32 does not bind: Shell_NotifyIconW and
 its NOTIFYICONDATAW structure. Signatures and constants are the Windows SDK's (shellapi.h).
 Sources: Microsoft Learn, Shell_NotifyIconW and NOTIFYICONDATAW (learn.microsoft.com/windows/win32/api/shellapi);
 the version 4 layout and NIN_SELECT as described in the same reference.
*>
module bleu::tray::windows_api @feat(WIN32) @link("shell32");
import std::os::win32;

// Shell_NotifyIconW messages.
const uint NIM_ADD        = 0x00000000;
const uint NIM_DELETE     = 0x00000002;
const uint NIM_SETVERSION = 0x00000004;

// NOTIFYICONDATAW.uFlags: which fields of the structure are valid.
const uint NIF_MESSAGE = 0x00000001;
const uint NIF_ICON    = 0x00000002;
const uint NIF_TIP     = 0x00000004;

// NOTIFYICON_VERSION_4: the callback's LOWORD(lParam) carries the event and the anchor is in wParam.
const uint NOTIFYICON_VERSION_4 = 4;

// NIN_SELECT: the icon was selected (a primary click or Enter). WM_USER + 0.
const uint NIN_SELECT = 0x0400;

// Capacities of the text fields, in UTF-16 units, including the terminating zero (shellapi.h).
const usz TIP_UNITS  = 128;
const usz INFO_UNITS = 256;
const usz TITLE_UNITS = 64;

// NOTIFYICONDATAW, the version 4 layout. Field order and sizes are shellapi.h's; `cb_size` must be
// `NotifyIconDataW::size`, the size of this structure on the target.
struct NotifyIconDataW
{
	uint cb_size;
	void* hwnd;
	uint id;
	uint flags;
	uint callback_message;
	void* icon;
	Char16[TIP_UNITS] tip;
	uint state;
	uint state_mask;
	Char16[INFO_UNITS] info;
	uint version;
	Char16[TITLE_UNITS] info_title;
	uint info_flags;
	uint[4] guid_item;
	void* balloon_icon;
}

extern fn int shellNotifyIconW(uint message, NotifyIconDataW* data) @cname("Shell_NotifyIconW");
