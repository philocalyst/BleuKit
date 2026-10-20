<*
 The desktop's windows and workspaces, as plain data.

 What a bar's workspace switcher and focused-window title need, and what the
 platform can say about each window. Every `String` is owned by the snapshot
 that holds it.

 Unknown is not zero. A number the platform does not report is a `Maybe` with
 no value. A flag the platform cannot tell is still a `bool` in `flags`, but its
 bit is clear in `reported`: read `flags` only where `reported` says so.
*>
module bleu::windows;
import std::collections::maybe, std::time, bleu::operation;

<* A rectangle in global logical pixels (Linux compositors) or screen pixels (Windows, macOS). *>
struct Rect
{
	int x;
	int y;
	int width;
	int height;
}

<*
 The state flags of one window. In `Window.flags` a set bit means the state
 holds; in `Window.reported` a set bit means the backend can tell that state at
 all, so a clear bit in `flags` with a set bit in `reported` is a real "no".
*>
bitstruct WindowFlags : char
{
	bool focused;    // holds keyboard focus
	bool floating;   // outside the tiling layout
	bool fullscreen; // covers its output
	bool maximized;  // zoomed to the work area
	bool minimized;  // hidden to the taskbar or dock
	bool urgent;     // asks for attention
	bool pinned;     // shown on every workspace
}

<*
 One toplevel window.

 `id` is stable while the window lives and is what actions take: a Hyprland
 address, a niri or sway id, a Win32 HWND written as "0x...", a CGWindowID.
 `icon_hint` names the application for icon lookup: the Wayland app id, the
 macOS bundle identifier, or the Windows executable's base name (empty when not
 known). `workspace_id` and `output_id` are "" when the backend does not know.
*>
struct Window
{
	String id;
	String title;
	String app_id;
	String icon_hint;
	Maybe{int} pid;
	String workspace_id;
	String output_id;
	Maybe{Rect} geometry;
	WindowFlags flags;
	WindowFlags reported;
}

<*
 One workspace (a Hyprland or niri workspace, a sway workspace, a Windows
 virtual desktop that holds at least one window, a macOS Space).

 `active` means the workspace holds keyboard focus; `visible` means it is shown
 on its output right now (a multi-monitor bar highlights one per output).
 `window_count` counts the listed windows on it. `index` is absent when the
 backend has no ordinal, and `urgent` is absent when it is not reported.
*>
struct Workspace
{
	String id;
	String name;
	Maybe{int} index;
	String output_id;
	bool active;
	bool visible;
	int window_count;
	Maybe{bool} urgent;
}

<* One output (monitor) that holds workspaces. `active_workspace_id` is "" when unknown. *>
struct Output
{
	String id;
	String name;
	bool focused;
	String active_workspace_id;
	Maybe{Rect} geometry;
}

<*
 Whether the backend is talking to the platform right now. `DISCONNECTED`
 means the lists are empty because nothing can be read, and `State.status`
 says why.
*>
enum Connection : char
{
	CONNECTED,
	DISCONNECTED,
}

<*
 The whole picture, published as one snapshot. `focused_window_id` is ""
 when no window has focus. `titles_available` is false when window titles are
 withheld by the platform (macOS without Screen Recording permission).
*>
struct State
{
	Connection connection;
	String status; // "" when connected; the reason otherwise
	String focused_window_id;
	Window[] windows;
	Workspace[] workspaces;
	Output[] outputs;
	bool titles_available;
}

<*
 Every optional capability. Each is either available, or refused with the
 reason in `Availability` (see the library README for how each backend answers).
*>
enum Cap : char
{
	LIST_WINDOWS,            // windows with their ids, titles and states
	LIST_WORKSPACES,         // workspaces and which one is active
	WINDOW_TITLES,           // window titles are reported
	FOCUS_WINDOW,
	CLOSE_WINDOW,
	MINIMIZE_WINDOW,
	SWITCH_WORKSPACE,        // show a workspace on its output
	MOVE_WINDOW_TO_WORKSPACE,
	TOGGLE_FLOATING,
	TOGGLE_FULLSCREEN,
}

<*
 A change that happened. Re-read the state for the values. Several events may
 describe one change (a window that gains focus is both `WINDOW_CHANGED` and
 `FOCUS_CHANGED`). `id` is a window or workspace id, "" when none applies.
*>
enum EventKind : char
{
	WINDOW_OPENED,
	WINDOW_CLOSED,
	WINDOW_CHANGED,
	FOCUS_CHANGED,
	WORKSPACE_ADDED,
	WORKSPACE_REMOVED,
	WORKSPACE_CHANGED,
	CONNECTION_CHANGED,
}

<* One transient. *>
struct Event
{
	EventKind kind;
	String id;
}

<* What the worker is asked to do. `REFRESH` re-reads the platform now. *>
enum CommandKind : char
{
	REFRESH,
	FOCUS_WINDOW,
	CLOSE_WINDOW,
	MINIMIZE_WINDOW,
	SWITCH_WORKSPACE,
	MOVE_WINDOW_TO_WORKSPACE,
	TOGGLE_FLOATING,
	TOGGLE_FULLSCREEN,
}

<*
 A request for the worker. `target` and `destination` are copies owned by the
 request's `Operation` arena, which the worker keeps alive until it completes
 the request. `request` is null for `REFRESH`.
*>
struct Command
{
	CommandKind kind;
	String target;
	String destination;
	Operation{bool}* request;
}

<* Which mechanism provides the data. *>
enum Backend : char
{
	AUTO,
	COMPOSITOR, // Linux: the IPC socket of a running compositor (bleu::compositor)
	WIN32,      // Windows: EnumWindows, win-event hooks, IVirtualDesktopManager
	MACOS,      // macOS: NSWorkspace, CGWindowList, Accessibility
}

<*
 Settings for `open`. Zero values mean the defaults. The first reconnect wait
 is `retry`, doubling up to `retry_max`.
*>
struct Options
{
	Backend backend;
	Duration retry;
	Duration retry_max;
	bool allow_private; // macOS only: resolve the SkyLight Spaces symbols at run time (off by default)
}
