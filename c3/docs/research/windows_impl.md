# bleu_windows: implementation notes

Scope built (v1 cut of `session_windows_input.md`, windows section): the Linux
compositor backend (Hyprland, sway, i3, niri through `bleu_compositor`), the Windows
backend (EnumWindows, the Alt-Tab rules, win-event hooks, documented
`IVirtualDesktopManager`), and the macOS backend (NSWorkspace, CGWindowList, Accessibility,
and SkyLight Spaces read-only behind `Options.allow_private`). Not built: the
`ext-workspace` Wayland backend (the brief allowed it only if time remained).

## Verification record

Each row names the claim, the sources read, and the status. "Two sources" means the
constant was read in two independent headers or bindings in this environment.

| Claim | Sources (file:line) | Status |
| --- | --- | --- |
| `EVENT_SYSTEM_FOREGROUND` 0x0003, `EVENT_OBJECT_CREATE` 0x8000, `DESTROY` 0x8001, `SHOW` 0x8002, `HIDE` 0x8003, `STATECHANGE` 0x800A, `LOCATIONCHANGE` 0x800B, `NAMECHANGE` 0x800C, `CLOAKED` 0x8017, `UNCLOAKED` 0x8018 | mingw-w64 `winuser_mingw.h` 5929-6020; windows-sys 0.59.0 `UI/WindowsAndMessaging/mod.rs` 788-838 | two sources |
| `OBJID_WINDOW` 0, `CHILDID_SELF` 0 | mingw 5905-5909; windows-sys 600, 1495 | two sources |
| `WINEVENT_OUTOFCONTEXT` 0, `WINEVENT_SKIPOWNPROCESS` 2 | mingw 5896-5898; windows-sys 2334-2335 | two sources |
| `SetWinEventHook(min, max, hmod, proc, pid, tid, flags)`; `WINEVENTPROC(hook, event, hwnd, idObject, idChild, idThread, time)`; `UnhookWinEvent` | mingw 5889, 5892, 5902 | one source (mingw); signature matches the Learn text cited in the research |
| `GA_ROOT` 2, `GA_ROOTOWNER` 3 | mingw 6256-6257; windows-sys 888-889 | two sources |
| `GWL_EXSTYLE` -20 | mingw 978; windows-sys 969 | two sources |
| `WS_EX_TOOLWINDOW` 0x80, `WS_EX_APPWINDOW` 0x40000 | mingw 1615, 1627; windows-sys 2646, 2624; std `winuser.c3` 338 | two sources |
| `DWMWA_CLOAKED` 14; `DwmGetWindowAttribute(hwnd, attr, value, size)` | windows-sys `Graphics/Dwm/mod.rs` 74 and 17; winapi 0.3.9 `um/dwmapi.rs` 37 | two sources |
| `GetWindowTextW`, `GetClassNameW`, `GetWindowThreadProcessId`, `GetLastActivePopup`, `GetForegroundWindow`, `EnumWindows`, `GetWindowRect`, `IsIconic`, `IsZoomed`, `GetAncestor` | mingw 3639, 3955, 3962, 3967, 3503, 3949, 3643, 2308, 2311, 6262; windows-sys `UI/WindowsAndMessaging` (`fn ... link!`) | two sources |
| `SW_MINIMIZE` 6, `WM_CLOSE` 0x0010 | mingw 208, 1048; windows-sys 2224, 2372 | two sources |
| `OpenProcess`, `QueryFullProcessImageNameW`, `PROCESS_QUERY_LIMITED_INFORMATION` 0x1000 | mingw `processthreadsapi.h` 24, `winbase.h` 1684, `winnt.h` 4526; windows-sys `System/Threading/mod.rs` 242, 255, 531 | two sources |
| `PROCESS_NAME_WIN32` 0 | windows-sys `System/Threading/mod.rs` 526 | one source |
| `IVirtualDesktopManager` IID a5cd92ff-29be-454c-8d04-d82879fb3f1b; CLSID aa509086-5ca9-4c25-8f95-589d3c07b48a; vtable after IUnknown: IsWindowOnCurrentVirtualDesktop, GetWindowDesktopId, MoveWindowToDesktop | mingw `shobjidl.h` 30582-30597 and 32929; windows-sys `UI/Shell/mod.rs` 6674 (CLSID); WINVD `interfaces.rs` (research) | two sources (IID also from WINVD); the research's single-source flag is resolved |
| Alt-Tab rules: visible, not cloaked, root owner chain ends at the window, tool window unless app window | Raymond Chen, "Alt+Tab list?" (2007-10-08) as quoted in the research (RC) | one source (the blog); implemented as the research describes |
| Raymond Chen's owner walk: `GetAncestor(GA_ROOTOWNER)` then `GetLastActivePopup` until stable | RC (research, read) | one source |
| `CGWindowListCopyWindowInfo` options: `OnScreenOnly` 1<<0, `ExcludeDesktopElements` 1<<4; keys `kCGWindowNumber`, `OwnerPID`, `OwnerName`, `Name`, `Layer`, `Bounds`, `IsOnscreen` | objc2-core-graphics 0.3.1 `CGWindow.rs` 65-146 (SDK-generated); x-win 5.0.0 `src/macos/api.rs` (research) | two sources (the crate and the research) |
| `kCGNullWindowID` 0; `kCGNormalWindowLevel` 0 | objc2 `CGWindow.rs` 11; `CGWindowLevel.rs` 15 | one source (generated from the SDK) |
| `CGPreflightScreenCaptureAccess()` | x-win `src/macos/permission.rs` 4-11 | two uses in one crate; the header was not read |
| `CGRectMakeWithDictionaryRepresentation` | none read | UNVERIFIED (signature from memory of CGRect.h); single use, marked in the source |
| `NSWorkspaceDidActivateApplicationNotification` | Apple reference JSON `appkit_nsworkspace_didactivateapplicationnotification` (research scratch, read) | one source (Apple) |
| `AXIsProcessTrusted()` | Apple AppKit reference JSON `appkit_nsevent_addglobalmonitorforevents` (quotes it) | one source |
| `AXUIElementCopyAttributeValue(el, attr, CFTypeRef*)` | Hammerspoon `extensions/window/libwindow.m` 334-335 | one source (call shape); Apple pages unreadable here |
| AX create-application, set-attribute, perform-action; attribute names `AXFocusedWindow`, `AXCloseButton`, `AXMinimized`; actions `AXRaise`, `AXPress` | none readable | UNVERIFIED; marked in `macos_ax.c3` |
| `SLSMainConnectionID` `int(void)` | Hammerspoon `libspaces.m` 281; yabai `src/misc/extern.h` 9 | two sources |
| `SLSGetActiveSpace(connection)` returning a 64-bit Space id | Hammerspoon `libspaces.m` 84 (call site only) | UNVERIFIED return type; marked in `macos_spaces_private.c3` |
| `SLSCopyManagedDisplaySpaces` | yabai `extern.h` 60; Hammerspoon `libspaces.m` 56 (`CFArrayRef`) | declared; dictionary shape NOT verified, so not read |
| `NSApplicationActivateIgnoringOtherApps` = 2 | memory of `NSRunningApplication.h` | UNVERIFIED; marked in `macos_workspace.c3` |

## Deviations from the research and the brief

* `Command` is a struct (kind, target, destination, request) rather than an enum: an action
  needs its arguments and its `Operation`. `REFRESH` carries no request. This is the
  pattern `bleu_clipboard` uses.
* `Cap` lists the actions the brief names and the listing caps. `CREATE_WORKSPACE` and
  `MAXIMIZE` from the research are not in the brief's action list and are not implemented.
* `Event` kinds: the research's list, plus `WORKSPACE_ADDED`/`REMOVED` and
  `CONNECTION_CHANGED`. `MONITOR_CHANGED` is not an event (outputs are read from the state).
* `State` adds `connection`, `status`, `focused_window_id`, `titles_available`, and `outputs`
  (`Output` refs carry `active_workspace_id`). `Window.reported` makes "not reported"
  distinct from "false" for each flag.
* macOS: the research said notification-driven. The observer enqueues a REFRESH, and a 1 s
  poll also runs, because `didActivateApplication` is delivered on the main run loop, which a
  worker-only process does not run.
* Windows: `LIST_WORKSPACES` is `DEGRADED`: desktops appear only when a listed window is on them.
* Linux: `MINIMIZE_WINDOW` is refused on all compositors (none reports or acts on it).
* Windows: `SetForegroundWindow` may be refused; the refusal is reported, not hidden.

## C3 gotchas found (for `docs/C3_GOTCHAS.md`)

* A zeroed `State` reads as `Connection.CONNECTED` (ordinal 0): a disconnected snapshot
  must set `connection = DISCONNECTED` explicitly. Found by the live test: the service
  published "connected, no windows" when the compositor closed.
* `Cap.FOCUS_WINDOW` and `CommandKind.FOCUS_WINDOW` share a name: qualify each use with its enum.
* A module's own `Window`, `Workspace`, `Output`, `Rect` clash with the same names imported from
  `bleu::compositor`: qualify with the module (`windows::Window`).
* A parameter named `windows` shadows the module `bleu::windows`: rename (`listed`).
* `catch` is only valid in `if`/`while`; discard with `if (catch f()) {}`.
* `main` returning `int` cannot use `!` (rethrow); use `!!` in a test driver.
* `Snapshot{State}` from `bleu::observe` must be imported in every file that names it; the
  service alias `StateSnapshot` is not visible outside `bleu::service`.
* `ObjId` is a distinct type (`std::os::darwin::objc`): compare with `!x`, not `== null`.
* `@objc_entry` and `@autorelease_pool` are macros of `bleu::objc`: write `objc::@...`.
* `Duration` is a typedef of `long`: `2 * wait` needs `(Duration)(2 * (long)wait)`.
* A `const` struct global cannot be passed by address (`&CONST`): make a local.
* Unix socket paths longer than 108 bytes make the Python fakes fail with
  `AF_UNIX path too long`: the scratch directory must be short (`/tmp/x`).
* `std::os::win32::dwmGetWindowAttribute` takes the handle by pointer (`Win32_HWND*`), which
  does not match `DwmGetWindowAttribute`: this library declares its own extern.

## Shared-library observations

* `bleu_objc`: `notify::name_of` returns an owned `Obj`, while `notify::observe` takes an
  `ObjId`. A caller that passes `.ptr` must keep the `Obj` and close it; the API does not say so.
* `bleu_compositor`: no changes needed. Its `read_events` returns `DISCONNECTED` on a closed
  event socket, which the poller path depends on (checked in `io.c3` and `rt unix_message.c3`).
* `bleu_rt`: `Poller.wait` in window-message mode returns `WINDOW_MESSAGES_TAG`; the worker
  calls `message_loop::dispatch_pending` after every wait, as the rt README asks.

## Not verified (carried into the code and the README)

Windows: nothing has run. macOS: nothing has run. The UNVERIFIED items are listed in the
verification table above and in the sources they belong to.
