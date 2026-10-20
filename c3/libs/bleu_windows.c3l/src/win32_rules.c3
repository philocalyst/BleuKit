<*
 The rules of the Windows backend that do not touch the OS: which top-level
 windows the Alt-Tab list shows, which win-events matter, how a window id is
 written and read, the file name of an executable, and which virtual desktops a
 list of windows names. Pure, so every host runs their tests.

 Constants are the winuser.h and dwmapi.h values. Each is read from two
 independent headers or bindings; the lines are cited in docs/research/windows_impl.md.
*>
module bleu::windows::win32_rules;
import std::collections::list, bleu::error, bleu::windows;

// winuser.h: win-event constants (SetWinEventHook, WinEventProc).
const uint EVENT_SYSTEM_FOREGROUND   = 0x0003;
const uint EVENT_OBJECT_CREATE       = 0x8000;
const uint EVENT_OBJECT_DESTROY      = 0x8001;
const uint EVENT_OBJECT_SHOW         = 0x8002;
const uint EVENT_OBJECT_HIDE         = 0x8003;
const uint EVENT_OBJECT_STATECHANGE  = 0x800A;
const uint EVENT_OBJECT_LOCATIONCHANGE = 0x800B;
const uint EVENT_OBJECT_NAMECHANGE   = 0x800C;
const uint EVENT_OBJECT_CLOAKED      = 0x8017;
const uint EVENT_OBJECT_UNCLOAKED    = 0x8018;
// The object id of a window itself; other objects (caret, scrollbars) are not windows.
const int OBJID_WINDOW               = 0;
// winuser.h: flags of SetWinEventHook. Callbacks run on the installing thread.
const uint WINEVENT_OUTOFCONTEXT     = 0x0000;
const uint WINEVENT_SKIPOWNPROCESS   = 0x0002;
// winuser.h: GetAncestor flag, the root of the owner chain.
const uint GA_ROOTOWNER              = 3;
// winuser.h: GetWindowLongPtr index of the extended style.
const int GWL_EXSTYLE                = -20;
// winuser.h: extended window styles.
const uint WS_EX_TOOLWINDOW          = 0x00000080;
const uint WS_EX_APPWINDOW           = 0x00040000;
// dwmapi.h: DWMWINDOWATTRIBUTE value that reports whether a window is cloaked.
const uint DWMWA_CLOAKED             = 14;
// The DWORD size DwmGetWindowAttribute expects for DWMWA_CLOAKED.
const uint DWORD_BYTES               = 4;

<*
 What the Alt-Tab rules need to know about one top-level window.

 `owner_is_self` is true when the owner walk ends at the window itself, or when
 the window is an app window (an app window is treated as having no owner).
*>
struct WindowFacts
{
	bool visible;
	bool cloaked;
	bool tool_window;
	bool app_window;
	bool owner_is_self;
}

<*
 Whether a top-level window belongs in the Alt-Tab list. The rules are Raymond
 Chen's (Microsoft Old New Thing, "Alt+Tab list?", 2007-10-08): the window must be
 visible, the last active popup of its root owner must be itself, a tool window
 is excluded unless it is also an app window; cloaked windows (on another virtual
 desktop, or hidden by the shell) are excluded too.

 @param facts : "What the OS says about the window"
*>
fn bool is_alt_tab_window(WindowFacts facts)
{
	if (!facts.visible || facts.cloaked) return false;
	if (!facts.owner_is_self) return false;
	return !facts.tool_window || facts.app_window;
}

<*
 Whether a win-event is one the backend refreshes on. Only window objects count;
 location changes are included so the geometry in the state stays current.
*>
fn bool is_relevant_event(uint event, int id_object)
{
	if (id_object != OBJID_WINDOW) return false;
	return event == EVENT_SYSTEM_FOREGROUND
		|| event == EVENT_OBJECT_CREATE
		|| event == EVENT_OBJECT_DESTROY
		|| event == EVENT_OBJECT_SHOW
		|| event == EVENT_OBJECT_HIDE
		|| event == EVENT_OBJECT_STATECHANGE
		|| event == EVENT_OBJECT_LOCATIONCHANGE
		|| event == EVENT_OBJECT_NAMECHANGE
		|| event == EVENT_OBJECT_CLOAKED
		|| event == EVENT_OBJECT_UNCLOAKED;
}

<*
 The window id of an HWND: "0x" and the pointer value in lower-case hexadecimal.
 Windows handles are at most 64 bits, so the text is at most 18 characters.
*>
fn String format_handle(ulong handle)
{
	return string::tformat("0x%x", handle).copy(tmem);
}

<*
 The HWND value of a window id written by `format_handle`.

 @return? error::INVALID_ARGUMENT : "The text is not a window id"
*>
fn ulong? parse_handle(String id)
{
	if (id.len < 3 || id.len > 18 || id[0] != '0' || (id[1] != 'x' && id[1] != 'X'))
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "'%s' is not a window id", id)~;
	}
	ulong value = 0;
	for (sz i = 2; i < id.len; i++)
	{
		int digit = hex_digit(id[i]);
		if (digit < 0) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "'%s' is not a window id", id)~;
		value = value * 16 + (ulong)digit;
	}
	return value;
}

// The value of one hexadecimal digit, or -1.
fn int hex_digit(char c) @private
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

<*
 The name of an executable from its full image path: the file name without its
 directory and without a ".exe" extension (any case). Empty for an empty path.
*>
fn String executable_name(String path)
{
	sz start = 0;
	foreach (i, c : path)
	{
		if (c == '\\') start = (sz)i + 1;
	}
	String name = path[start : path.len - start];
	if (name.len >= 4 && is_exe_suffix(name[name.len - 4 : 4])) return name[0 : name.len - 4];
	return name;
}

fn bool is_exe_suffix(String suffix) @private
{
	return suffix == ".exe" || suffix == ".EXE" || suffix == ".Exe" || suffix == ".eXe"
		|| suffix == ".exE" || suffix == ".ExE" || suffix == ".EXe" || suffix == ".eXE";
}

<*
 The workspaces named by a list of windows, in the order they first appear.
 Windows with no workspace id are not counted. `focused_id` marks the one that
 holds focus and `visible_id` the one shown right now; either may be "".
 Names, indices and urgency are not reported by the documented API, so they are absent.

 @param allocator : "Allocator for the array (the snapshot's arena)"
*>
fn windows::Workspace[] workspaces_of(windows::Window[] listed, String focused_id, String visible_id, Allocator allocator)
{
	List{windows::Workspace} found;
	found.init(allocator);
	foreach (window : listed)
	{
		if (window.workspace_id.len == 0) continue;
		sz index = find_workspace(&found, window.workspace_id);
		if (index >= 0)
		{
			windows::Workspace* existing = found.get_ref((usz)index);
			existing.window_count++;
			continue;
		}
		found.push({
			.id = window.workspace_id.copy(allocator),
			.name = "",
			.output_id = "",
			.active = window.workspace_id == focused_id,
			.visible = window.workspace_id == visible_id,
			.window_count = 1,
		});
	}
	return found.array_view();
}

fn sz find_workspace(List{windows::Workspace}* found, String id) @private
{
	foreach (i, workspace : found)
	{
		if (workspace.id == id) return (sz)i;
	}
	return -1;
}
