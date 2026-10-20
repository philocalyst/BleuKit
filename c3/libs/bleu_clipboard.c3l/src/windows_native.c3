<*
 Native clipboard calls that the Windows backend makes and that `std::os::win32` does not bind,
 and the few constants it needs. Signatures are from the Microsoft pages named beside them
 (read 2026-10-20). The rest (OpenClipboard, EmptyClipboard, GetClipboardData, SetClipboardData,
 CloseClipboard, GlobalAlloc, GlobalLock, GlobalUnlock, GlobalFree) come from `std::os::win32`.
*>
module bleu::clipboard::windows_native @feat(WIN32);
import std::os::win32, std::thread, std::time;

// GetClipboardSequenceNumber: "incremented whenever the contents of the clipboard change or the
// clipboard is emptied"; zero without WINSTA_ACCESSCLIPBOARD access (winuser.h, the function page).
extern fn Win32_DWORD getClipboardSequenceNumber() @cname("GetClipboardSequenceNumber");
// EnumClipboardFormats: the next format after `format` (0 to start), 0 at the end (winuser.h).
extern fn Win32_UINT enumClipboardFormats(Win32_UINT format) @cname("EnumClipboardFormats");
// GetClipboardFormatNameW: the name of a registered format; 0 for a standard one (winuser.h).
extern fn int getClipboardFormatNameW(Win32_UINT format, WString name, int max_count) @cname("GetClipboardFormatNameW");
// GlobalSize: the size of a global memory block in bytes (winbase.h).
extern fn Win32_SIZE_T globalSize(Win32_HGLOBAL memory) @cname("GlobalSize");

// Standard clipboard formats, Standard Clipboard Formats page: CF_UNICODETEXT 13, CF_HDROP 15 (read 2026-10-20).
const uint CF_UNICODETEXT = 13;
const uint CF_HDROP       = 15;
// GlobalAlloc flag GMEM_MOVEABLE = 0x0002 (the GlobalAlloc page; also the value in the gfx code of the C3 standard library).
const uint GMEM_MOVEABLE = 0x0002;

// The longest a name of a registered format is read: 256 UTF-16 units.
const int FORMAT_NAME_CAPACITY = 256;
// Attempts to open the clipboard, and the first pause between them (doubled after each).
const usz OPEN_ATTEMPTS = 8;
const Duration OPEN_FIRST_PAUSE = (Duration)5_000;

<*
 Open the clipboard for this thread, retrying with backoff while another application holds it.
 Opening is documented to fail when another window has the clipboard open (OpenClipboard,
 winuser.h); a short back-off is the usual remedy.

 @return "true when the clipboard is open; the caller must close it"
*>
fn bool open_clipboard()
{
	Duration pause = OPEN_FIRST_PAUSE;
	for (usz attempt = 0; attempt < OPEN_ATTEMPTS; attempt++)
	{
		if (win32::openClipboard(null)) return true;
		if (attempt + 1 < OPEN_ATTEMPTS) thread::sleep(pause);
		pause = pause * 2;
	}
	return false;
}
