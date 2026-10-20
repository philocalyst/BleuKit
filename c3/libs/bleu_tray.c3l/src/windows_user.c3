<*
 The user32 calls of the Windows tray that std::os::win32 does not bind: popup menus, icon files,
 and the registered message the shell sends when Explorer restarts. Signatures and constants are
 the Windows SDK's (winuser.h, wingdi.h). Sources: Microsoft Learn, CreatePopupMenu, AppendMenuW,
 TrackPopupMenu, RegisterWindowMessageW and LoadImageW.
*>
module bleu::tray::windows_user @feat(WIN32) @link("user32");
import std::os::win32, bleu::error, bleu::win::errors, bleu::win::text;

// AppendMenuW flags.
const uint MF_STRING    = 0x00000000;
const uint MF_GRAYED    = 0x00000001;
const uint MF_SEPARATOR = 0x00000800;

// TrackPopupMenu flags: the menu follows the right button, and the command is returned, not posted.
const uint TPM_RIGHTBUTTON = 0x0002;
const uint TPM_RETURNCMD   = 0x0100;

// LoadImageW: an icon read from a file at its natural size.
const uint IMAGE_ICON      = 1;
const uint LR_LOADFROMFILE = 0x00000010;
const uint LR_DEFAULTSIZE  = 0x00000040;

// The right-button callback of a version 4 notification icon (WM_CONTEXTMENU is the keyboard and right-button menu).
const uint WM_CONTEXTMENU = 0x007B;

extern fn void* createPopupMenu() @cname("CreatePopupMenu");
extern fn int destroyMenu(void* menu) @cname("DestroyMenu");
extern fn int appendMenuW(void* menu, uint flags, uptr item, WString text) @cname("AppendMenuW");
extern fn int trackPopupMenu(
	void* menu,
	uint flags,
	int x,
	int y,
	int reserved,
	void* window,
	void* rect
) @cname("TrackPopupMenu");
extern fn uint registerWindowMessageW(WString name) @cname("RegisterWindowMessageW");
extern fn void* loadImageW(void* instance, WString name, uint kind, int cx, int cy, uint flags) @cname("LoadImageW");

<* A new popup menu, or the failure. *>
fn void*? create_menu()
{
	void* menu = createPopupMenu();
	if (menu == null) return errors::raise_last("CreatePopupMenu")~;
	return menu;
}

<* Append one entry. `text` is `null` for a separator. *>
fn void? append_menu(void* menu, uint flags, int id, WString text)
{
	if (appendMenuW(menu, flags, (uptr)id, text) == 0) return errors::raise_last("AppendMenuW")~;
}

// Show the menu at (x, y) and wait for a choice. Returns the chosen id, or 0 when none was made.
fn int track_menu(void* menu, int x, int y, void* window)
{
	return trackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_RETURNCMD, x, y, 0, window, null);
}

// The message the shell broadcasts to every window when Explorer starts again.
fn uint? taskbar_created_message()
{
	WideZ name = text::to_wide(mem, "TaskbarCreated")!;
	defer name.free();
	return registerWindowMessageW(name.as_wstring());
}