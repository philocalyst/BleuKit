# Research spike: session, windows, clipboard, hotkey, input

Scope: five services, each with the six template sections (1-6 of
`docs/research/TEMPLATE.md`). Read-only spike; the only file written is this one.
Sources were read on 2026-10-20 through the agent proxy.

## Method and legend

Each claim carries a verification tag:

* **read** - the primary source file or page was fetched and the exact text or
  identifier was checked.
* **grep** - the source was fetched and a targeted search confirmed the
  identifier. Context was not read in full.
* **README** - only a project's README or a store page was read.
* **UNVERIFIED** - from memory or the task brief, not confirmed here. Do not code
  against it without a check.
* **(single-source)** - only one independent source was confirmed.

Source IDs used below (all fetched 2026-10-20):

| ID | Source |
| --- | --- |
| WP-IDLE | `staging/ext-idle-notify/ext-idle-notify-v1.xml` (wayland-protocols, gitlab raw) - read |
| WP-LOCK | `staging/ext-session-lock/ext-session-lock-v1.xml` - read |
| WP-FTL | `staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml` - read |
| WP-WS | `staging/ext-workspace/ext-workspace-v1.xml` - read |
| WP-DC | `staging/ext-data-control/ext-data-control-v1.xml` - read |
| WP-PRIM | `unstable/primary-selection/primary-selection-unstable-v1.xml` - read |
| WP-IDLEINH | `unstable/idle-inhibit/idle-inhibit-unstable-v1.xml` - read |
| WP-KBINH | `unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml` - read |
| WP-ACT | `staging/xdg-activation/xdg-activation-v1.xml` - read |
| WLR-TL | wlr-protocols `unstable/wlr-foreign-toplevel-management-unstable-v1.xml` (master) - read |
| WLR-DC | wlr-protocols `unstable/wlr-data-control-unstable-v1.xml` (master) - read |
| XDP-GS | xdg-desktop-portal `data/org.freedesktop.portal.GlobalShortcuts.xml` (github mirror; the gitlab path redirects to login) - read; header says "version 2" |
| HYPR-GS | hyprland-protocols `protocols/hyprland-global-shortcuts-v1.xml` - read |
| HYPR-WIKI | https://wiki.hypr.land/IPC/ (text extracted) - read |
| HYPR-RS | `hyprland` crate 0.4.0-beta.2 (`src/shared.rs`, `src/data/regular.rs`) - read |
| NIRI | `niri-ipc` crate 25.11.0 (`src/lib.rs`, `src/socket.rs`) - read |
| SWAY-T | `swayipc-types` crate 1.3.0 (`command.rs`, `event.rs`, `lib.rs`) - read |
| SWAY | `swayipc` crate 3.0.3 (`src/common.rs`) - grep |
| WB-* | Waybar `src/modules/...` (hyprland/window, hyprland/workspaces, sway/language, niri/window, wlr/taskbar, keyboard_state, idle_inhibitor) - grep and excerpts |
| LOGIND | systemd `org.freedesktop.login1` man page (HTML and `man/org.freedesktop.login1.xml`) - read |
| MS-* | learn.microsoft.com Win32 pages (named per claim) - read or grep |
| WINVD | `winvd` crate 0.0.48 (`src/interfaces.rs`) - read |
| MSCH | MScholtes/VirtualDesktop README - read |
| RC | Raymond Chen, "Alt+Tab list?", devblogs.microsoft.com/oldnewthing/20071008-00/?p=24863 - read |
| AJ-* | developer.apple.com `tutorials/data/documentation/<path>.json` - read |
| HS-* | Hammerspoon `extensions/{spaces/libspaces.m, hotkey/libhotkey.m, eventtap/libeventtap.m, window/libwindow.m}` - grep |
| YABAI | yabai README and `src/misc/extern.h` - grep and README |
| GNOME-INTRO | gnome-shell `data/dbus-interfaces/org.gnome.Shell.Introspect.xml` - read |
| GHK | global-hotkey 0.7.0 crate (module tree, `platform_impl/x11/mod.rs`) - grep |
| WLCB | wl-clipboard-rs 0.9.2 crate (`src/data_control.rs`) - grep |
| ARB | arboard 3.6.1 crate (`src/platform/osx.rs`) - grep |
| XWIN | x-win 5.0.0 crate (`src/linux/api/x11_api.rs`, `src/macos/api.rs`, `src/win32/api.rs`) - grep |

Not reached (paths 404 or blocked): `Ciantic/VirtualDesktopAccessor`, `lwouis/alt-tab-macos`
(source paths), `PowerToys`, `cdown/clipboard-manager`, `bugaevc/wl-clipboard` C source,
`sentriz/cliphist`, GNOME `shell-introspect-service.c`, `user-idle` (static.crates.io 403),
Apple pages for `CGEventTapCreate`, `AXUIElementCreateApplication`, `NSPasteboard`
privacy (`accessBehavior`), Carbon `RegisterEventHotKey`, and `TISCopyCurrentKeyboardInputSource`.
Where a claim depends on one of these, it is marked UNVERIFIED.

---

## session

### 1. What a shell needs

1. Locked state: query now, and events on lock/unlock (lock-screen indicator, pause timers).
2. Idle: user-defined timeouts that emit `idle` and `resume` events (auto-lock, dim, away status).
3. Sleep/wake: a `will_sleep` event with a short delay window to lock first, and a `did_wake` event.
4. Lock request (the user's "lock now" button).
5. Session list / active seat (multi-user awareness).
6. Logout and switch-user (quick settings).
7. Lock-screen implementation: out of the service; a separate locker, see cut lines.

### 2. Per-platform native route (Linux / macOS / Windows)

#### Linux

**Route L1 (preferred for portability): logind, `org.freedesktop.login1`.**
Works on every Linux desktop that runs logind. Limits: logind stores hints; it
does not measure input or lock anything itself.

* `Manager.ListSessions() -> a(susso)`; `Manager.GetSession(s) -> o`;
  `Manager.ListSeats() -> a(so)`; `Manager.TerminateSession(s session_id)`;
  `Manager.ActivateSessionOnSeat(s session_id, s seat_id)`
  (LOGIND, read: `org.freedesktop.login1.xml`).
* Session properties: `LockedHint b`, `IdleHint b`, `IdleSinceHint t` (usec since epoch,
  CLOCK_REALTIME), `IdleSinceHintMonotonic t`, `Active b`, `Seat (so)`, `Type s`, `Class s`
  (LOGIND, read).
* Lock state is a property plus signals. `Session.SetLockedHint(b locked)` writes
  `LockedHint`. `Session.Lock()` and `Session.Unlock()` **methods** emit the
  `Session.Lock` / `Session.Unlock` **signals**, which the locker listens for
  (LOGIND, read). `Manager.LockSession(s)`, `Manager.UnlockSession(s)`,
  `Manager.LockSessions()`, `Manager.UnlockSessions()` do the same for one or all
  sessions (LOGIND, read).
* Idle: `Session.SetIdleHint(b idle)` is called by the shell; logind only stores it and
  uses it for automatic suspend/shutdown policy (LOGIND, read: "The IdleHint property
  reflects the idle hint state..."). logind does **not** compute idle time. (single-source)
* Sleep: `Manager.PrepareForSleep(b start)` signal, sent before (`start=true`) and after
  (`start=false`) suspend (LOGIND, read). Delay lock: call
  `Manager.Inhibit(s what, s who, s why, s mode) -> h fd`, with mode `"delay"`, and
  `what` containing `sleep` (LOGIND, read: mode is "block" or "delay"). Hold the fd,
  lock, then close the fd so suspend proceeds. The `what` value `sleep` and the
  `org.freedesktop.login1.inhibit-block-sleep` action name are from the man page
  (LOGIND, read).

**Route L2 (Wayland compositor-native idle): `ext-idle-notify-v1`, version 2.**

* Bind `ext_idle_notifier_v1`. `get_idle_notification(new_id, uint timeout_ms, wl_seat)`
  fires `idled` after the seat is inactive for at least `timeout` msec, and `resumed` on
  input. `timeout=0` is valid (WP-IDLE, read: arg summary "minimum idle timeout in msec").
* `get_input_idle_notification(...)` ignores idle inhibitors (WP-IDLE, read).
* Events `idled` and `resumed` must alternate. A second `idled` without `resumed` is a
  protocol error (WP-IDLE, read).
* There is **no request that returns elapsed idle time**. The notifier only creates
  notification objects (WP-IDLE, read). An "idle seconds now" value must be built from
  notifications at known thresholds or from logind `IdleSinceHint` if the shell sets it.
* Idle inhibit: `zwp_idle_inhibit_manager_v1.create_inhibitor(wl_surface)`, one
  inhibitor per surface (WP-IDLEINH, read).

**Route L3 (Wayland lock screen): `ext-session-lock-v1` (for the locker, not the service).**

* `ext_session_lock_manager_v1.lock(new_id)`. The compositor replies with `locked` or
  `finished` (WP-LOCK, read).
* For each output, `ext_session_lock_v1.get_lock_surface(new_id, wl_surface, wl_output)`.
  The surface is configured with `configure(serial, w, h)`, which the client acks with
  `ack_configure(serial)`. Attaching a buffer before the first configure is a protocol
  error (WP-LOCK, read).
* `unlock_and_destroy()` after authentication. It is a protocol error to call it before
  `locked` (WP-LOCK, read). `destroy()` is the only option after `finished` without
  `locked`.
* Wayland only: this is an implementation hook for a locker. It is not something the
  service calls. The service calls logind (L1), and the locker answers.

**Route L4 (compositor IPC for focus and session-adjacent events).**
Hyprland's `socket2` event list (HYPR-WIKI, read) has **no lock or idle event**, so
lock state must come from logind. Sway and niri IPC likewise expose no lock event
in what was read (SWAY-T event list: Workspace, Mode, Window, BarConfigUpdate,
Binding, Shutdown, Tick, BarStateUpdate, Input; NIRI event list in section windows).

#### macOS

* Idle: `CGEventSourceSecondsSinceLastEventType(stateID: CGEventSourceStateID, eventType: CGEventType) -> CFTimeInterval`, "the time in seconds since the previous input event of the specified type" (AJ-cgeventsource, read). The constant for "any input" (`kCGAnyInputEventType`) is UNVERIFIED here. Use with `kCGEventSourceStateHIDSystemState`, which the brief names (UNVERIFIED for this session).
* Lock state: `CGSessionCopyCurrentDictionary() -> CFDictionary?` returns the window server session dictionary (AJ-cgsessioncopycurrentdictionary, read: "returns information about the caller's window server session"). The key `CGSSessionScreenIsLocked` is UNVERIFIED. Distributed notifications `com.apple.screenIsLocked` / `screenIsUnlocked` are UNVERIFIED (NSDistributedNotificationCenter page not reachable).
* Sleep/wake: `NSWorkspace.willSleepNotification` ("an observer of this message can delay sleep for up to 30 seconds") and `NSWorkspace.didWakeNotification` (AJ-nsworkspace, read). Both are public API.
* Lock request: private `SACLockScreenImmediate` (login.framework), `CGSession -suspend`, `pmset displaysleepnow`. All UNVERIFIED here; treat as a private/cut-line route.
* Logout / switch user: no route read. UNVERIFIED.

#### Windows

* Idle: `GetLastInputInfo(PLASTINPUTINFO)`. Its `dwTime` is a tick count. It is **session-specific** and may not be monotonic (MS-getlastinputinfo, read). Idle seconds = `(GetTickCount() - dwTime) / 1000`, with the caveat noted in section 6.
* Lock/unlock events: `WTSRegisterSessionNotification(hwnd, NOTIFY_FOR_THIS_SESSION)`, then `WM_WTSSESSION_CHANGE` with `WTS_SESSION_LOCK = 0x7` and `WTS_SESSION_UNLOCK = 0x8` (MS-wm-wtssession-change, read; `NOTIFY_FOR_THIS_SESSION` in MS-wtsregister, read). The same message carries `WTS_SESSION_LOGON = 0x5` (read).
* Lock request: `LockWorkStation()`. "Because the function executes asynchronously, a nonzero return value indicates that the operation has been initiated. It does not indicate whether the workstation has been successfully locked" (MS-lockworkstation, read).
* Sleep/wake: `WM_POWERBROADCAST` / `RegisterPowerSettingNotification` (UNVERIFIED; not fetched).
* Logout / switch user: `ExitWindowsEx` (UNVERIFIED; not fetched).

**Permissions / entitlements / daemons.**
* Linux: logind is a system daemon. The man page lists the `org.freedesktop.login1.*` polkit action names (LOGIND, read). Which calls an owning user may make without a polkit prompt (for example `SetIdleHint`, `Lock`, or `Inhibit` with `sleep`) is UNVERIFIED; check on a target system before assuming.
* macOS: no TCC for the public session/idle/sleep APIs read here. Private SkyLight/CGS calls can break across OS releases.
* Windows: no admin needed for `GetLastInputInfo`, WTS notifications, or `LockWorkStation`.

**Pitfalls.**
* `ext-session-lock`: if the locker client dies, the compositor must not unlock. "It is acceptable for the session to be permanently locked" (WP-LOCK, read). The service must not assume a lock request can be undone.
* `ext-session-lock`: the locker must send `unlock_and_destroy` and then `wl_display.sync` before exit, or the unlock may race with termination (WP-LOCK, read).
* logind `LockedHint` is only as accurate as the code that calls `SetLockedHint`. Which compositors call it is UNVERIFIED.
* logind `IdleHint` is not automatic. If no shell calls `SetIdleHint`, it is always false (LOGIND, read: the hint is written by the shell).
* macOS `willSleep` gives at most 30 s before the system sleeps anyway (AJ, read).

**Private/undocumented routes.**
* macOS `SACLockScreenImmediate`, `CGSession -suspend`: not read here. Mark `*_private.c3` and cut line (section 6).

### 3. Reference implementations (prove it works)

| Project | Language | File | What to copy the idea of | Depth |
| --- | --- | --- | --- | --- |
| Waybar | C++ | `src/modules/idle_inhibitor.cpp` (raw: Alexays/Waybar master) | Binds `ext-idle-notify-v1` and `zwp_idle_inhibit_manager_v1`; gates "wait-for-activity" on the notifier | grep |
| Hammerspoon | ObjC | `extensions/spaces/libspaces.m`, `extensions/eventtap/libeventtap.m` | CGS/SkyLight calls, CGEventTap creation (see windows, hotkey) | grep |
| yabai | C | `src/misc/extern.h` (koekeishiya/yabai master) | SkyLight extern declarations; README states SIP caveat | grep + README |
| DankMaterialShell | Go/QML (repo) | `README.md` (AvengeMedia) | Overall shell scope; compositor backends per the brief | README only; `core/internal/` paths 404 at guessed URLs, so not read |
| GNOME Shell | C/JS | `data/dbus-interfaces/org.gnome.Shell.Introspect.xml` | Window list over D-Bus (windows section) | read (XML only) |
| `ashpd` | Rust | crate source (static.crates.io 0.10.2, downloaded) | Portal client for GlobalShortcuts (hotkey section) | downloaded, not read |

No lock-screen reference (swaylock, hyprlock, gtklock) was fetched. The
lock-screen implementation is therefore unverified and is a cut line.

### 4. Double validation

| Claim | Source 1 | Source 2 | Status |
| --- | --- | --- | --- |
| `ext_idle_notifier_v1.get_idle_notification(timeout uint msec)` | WP-IDLE (XML arg summary) | Waybar `idle_inhibitor.cpp` uses `idle_timeout_ms_` | 2 sources |
| `get_input_idle_notification` ignores idle inhibitors | WP-IDLE description | none | (single-source) |
| No protocol request returns elapsed idle time | WP-IDLE (only two requests + destroy, no getter) | none | (single-source) |
| `ext_session_lock_v1` `locked`/`finished` contract | WP-LOCK | none | (single-source) |
| logind `Session.Lock()` emits `Lock` signal; `LockSession` on Manager | LOGIND (man page HTML) | LOGIND (man page XML source) | same doc, 2 forms |
| logind `PrepareForSleep(b start)` | LOGIND HTML | LOGIND XML | same doc, 2 forms |
| logind `IdleHint` is set by `SetIdleHint`, not computed | LOGIND | none | (single-source) |
| Inhibit `mode` is `block` or `delay` | LOGIND HTML | none | (single-source) |
| `WTS_SESSION_LOCK = 0x7` / `UNLOCK = 0x8` | MS-wm-wtssession-change | none | (single-source) |
| `GetLastInputInfo` is session-specific | MS-getlastinputinfo | none | (single-source) |
| `LockWorkStation` is asynchronous | MS-lockworkstation | none | (single-source) |
| `willSleep` may delay up to 30 s | AJ-nsworkspace | none | (single-source) |
| `CGEventSourceSecondsSinceLastEventType` signature | AJ-cgeventsource (declaration) | none | (single-source) |
| `CGSessionCopyCurrentDictionary` returns session dict | AJ-cgsessioncopycurrentdictionary | none | (single-source) |
| Private SkyLight/CGS Spaces functions exist | HS-SPACES (grep) | YABAI extern.h (grep) | 2 sources |

### 5. Proposed Bleu model

```c3
module bleu::session;

// Plain data only. Optionals are bool + value (style guide).
struct SessionState {
    bool locked_known;      // false when no backend can tell
    bool locked;
    bool idle_known;
    bool sleeping;          // between will_sleep and did_wake
    String session_id;      // logind session id, or "" on macOS/Windows
    String seat_id;
}

// User-defined idle rule, passed in Options.
struct IdleRule {
    String name;            // e.g. "lock", "dim"
    Duration timeout;       // std::time Duration (microseconds)
}

enum SessionEvent : char { LOCKED, UNLOCKED, IDLED, RESUMED, WILL_SLEEP, DID_WAKE }

enum SessionCap : char {
    QUERY_LOCKED, LOCK_EVENTS, LOCK_REQUEST, IDLE_QUERY, IDLE_EVENTS,
    SLEEP_EVENTS, SLEEP_DELAY, LIST_SESSIONS, TERMINATE, SWITCH_USER,
}

enum SessionBackend : char { LOGIND, WAYLAND_IDLE, MACOS, WIN32 }
```

Platform gaps: `IDLE_QUERY` is unavailable on Wayland without logind hints
(`UNSUPPORTED_BACKEND`). `SLEEP_DELAY` is unavailable on macOS without an observer and on
Windows without the power notification (UNVERIFIED).

### 6. Risks and cut lines

* Hard: "idle seconds now" on Wayland has no native getter. Build it from thresholds or
  accept that the value is "at least X" per rule.
* Hard: lock screen. Auth is PAM plus the locker's UI. The service should only request
  and observe a lock, never render or authenticate one. **Cut:** lock-screen
  implementation and PAM (out of the service).
* macOS lock request needs a private API. **Cut** from v1; observe lock state only.
* Windows idle tick count may wrap or go backwards (MS, read). Clamp at zero.
* Recommend v1: logind L1 for lock, sleep and session list on Linux; `ext-idle-notify`
  for idle events; public macOS and Windows APIs; no private calls.

---

## windows

### 1. What a shell needs

1. Active window: title and app id, for the focused-window title in the bar.
2. Workspaces: list, active, urgent, per output; events on change.
3. Workspace switching and creation (click a workspace button).
4. Window list: id, title, app id, pid, workspace, output, focus, floating, fullscreen,
   maximized, minimized, urgent, geometry.
5. Window actions: focus, close, minimize, move to workspace, maximize, toggle floating,
   fullscreen.
6. Change events for all of the above.

### 2. Per-platform native route (Linux / macOS / Windows)

#### Linux, compositor IPC (preferred; gives workspaces and focus)

**Hyprland** (socket path and event list confirmed).
* Command socket: `$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket.sock`.
  Event socket: `.../.socket2.sock` (HYPR-RS `shared.rs`: `SocketType::Command` =
  `.socket.sock`, `Listener` = `.socket2.sock`; HYPR-WIKI, read).
* Requests: `[flags]/command args`. The JSON flag is `j/`, from `CommandFlag::JSON` in
  `shared.rs` (HYPR-RS, read). Examples: `j/clients`, `j/workspaces`, `j/activewindow`,
  `j/monitors`, `j/devices` (`regular.rs` display names: clients, workspaces, activewindow,
  devices, activeworkspace; read).
* Connection rule: Hyprland evaluates requests synchronously. An unclosed connection
  freezes it until a five-second timeout. Open, write, read, close per request
  (HYPR-WIKI, read).
* Events: `EVENT>>DATA\n` per line (HYPR-WIKI, read). Full list read in HYPR-WIKI.
  Relevant: `workspacev2` (ID,NAME), `focusedmonv2` (MON,ID), `activewindowv2` (ADDRESS),
  `activewindow` (CLASS,TITLE), `openwindow`, `closewindow`, `movewindowv2`,
  `windowtitlev2` (ADDRESS,TITLE), `fullscreen` (0/1), `changefloatingmode`
  (ADDRESS,0/1), `urgent` (ADDRESS), `minimized` (ADDRESS,0/1; from an external taskbar
  request only), `createworkspacev2`, `destroyworkspacev2`, `renameworkspace`,
  `moveworkspacev2`, `monitoradded` / `monitoraddedv2`, `monitorremoved` / `...V2`,
  `activelayout` (KEYBOARD,LAYOUT), `pin`, `submap`.
* Client struct fields (HYPR-RS `regular.rs`, read): `address`, `mapped`, `at (i16,i16)`,
  `size (i16,i16)`, `workspace`, `floating`, `fullscreen` and `fullscreen_client`
  (FullscreenMode), `monitor`, `initial_class`, `class`, `initial_title`, `title`, `pid`,
  `xwayland`, `pinned`, `grouped`, `swallowing`. There is **no minimized field**. Minimize
  on Hyprland is UNSUPPORTED from the IPC data.
* Actions: `dispatch focuswindow address:...` is the form given in the brief. The
  dispatch names for close, move-to-workspace, fullscreen, togglefloating and maximize
  are UNVERIFIED here (`dispatch.rs` exists in HYPR-RS, not read).

**Sway / i3** (framing confirmed).
* Socket: `$SWAYSOCK`. Frame: 6-byte magic `i3-ipc` = `[105,51,45,105,112,99]`, then
  payload length and message type, both 32-bit (magic in SWAY-T `lib.rs`, read; header
  checked in SWAY `common.rs`, grep; endianness UNVERIFIED, native order is the usual
  reading).
* Message types (SWAY-T `command.rs`, read): RUN_COMMAND 0, GET_WORKSPACES 1,
  SUBSCRIBE 2, GET_OUTPUTS 3, GET_TREE 4, GET_BAR_CONFIG 6, GET_VERSION 7, SEND_TICK 10,
  GET_BINDING_STATE 12, GET_INPUTS 100.
* Event types (SWAY-T `event.rs`, read): Workspace, Mode, Window, BarConfigUpdate,
  Binding, Shutdown, Tick, BarStateUpdate, Input. Subscribe with a JSON array of names
  (Waybar uses `["input"]`, WB-sway-language, read).
* Window and focus events use the `Window` event type from the list above. Waybar's
  `sway/window.cpp` was fetched but not read, so field details for sway windows are UNVERIFIED.

**niri** (fully read).
* Socket path from env `NIRI_SOCKET` (NIRI `socket.rs`, read). Request/response is
  JSON lines.
* Requests: `Request::Workspaces`, `Request::Windows`, `Request::EventStream`
  (NIRI `lib.rs`, read). `EventStream` stops the reading of other requests on that
  socket (NIRI `lib.rs` doc, read).
* Events (NIRI `lib.rs`, read): `WorkspacesChanged{workspaces}`,
  `WorkspaceUrgencyChanged{id,urgent}`, `WorkspaceActivated{id,focused}`,
  `WorkspaceActiveWindowChanged{workspace_id,active_window_id}`, `WindowsChanged{windows}`,
  `WindowOpenedOrChanged{window}`, `WindowClosed{id}`, `WindowFocusChanged{id}`,
  `WindowUrgencyChanged{id,urgent}`, `WindowLayoutsChanged`, `KeyboardLayoutsChanged`,
  `KeyboardLayoutSwitched{idx}`, `OverviewOpenedOrClosed{is_open}`, `ConfigLoaded`.
* `Window` fields (NIRI `lib.rs`, read): `id`, `title: Option`, `app_id: Option`,
  `pid: Option<i32>`, `workspace_id: Option`, `is_focused`, `is_floating`, `is_urgent`.
  No minimized field.
* `Workspace` fields (NIRI, read): `id`, `idx: u8`, `name: Option`, `output: Option`,
  `is_urgent`, `is_active`, `is_focused`, `active_window_id: Option`.
* Actions seen (NIRI `lib.rs`, read): `FocusWindow`, `CloseWindow`, `FullscreenWindow`,
  `MaximizeColumn`, `ToggleWindowFloating`, `FocusWorkspace`, `MoveWindowToWorkspace`,
  `SetWorkspaceName`. The grep did not cover all variants; a minimize action was not
  seen (UNVERIFIED for full enum).

**wlroots / generic Wayland (`zwlr_foreign_toplevel`, `ext_foreign_toplevel_list`).**
* `ext_foreign_toplevel_list_v1` (WP-FTL, read) gives `toplevel`, then per handle `title`,
  `app_id`, `identifier`, `done`, `closed`. **It has no state, no geometry, no pid, no
  workspace and no actions.** Use it only for a window list with titles.
* `zwlr_foreign_toplevel_manager_v1` v3 (WLR-TL, read): handle requests `set_maximized`,
  `unset_maximized`, `set_minimized`, `unset_minimized`, `activate(seat)`, `close`,
  `set_rectangle(surface,x,y,w,h)`, `set_fullscreen(output?)`, `unset_fullscreen`;
  events `title`, `app_id`, `output_enter/leave`, `state(array)`, `done`, `closed`,
  `parent`. State enum: `maximized=0`, `minimized=1`, `activated=2`, `fullscreen=3`.
  Waybar's taskbar maps these bits (WB-wlr-taskbar `handle_state`, grep lines 422-457).
  The protocol has no pid and no workspace.
* `ext_workspace_v1` (WP-WS, read): manager events `workspace_group`, `workspace`,
  `done`, `finished`, and `commit()` request to apply a batch. Group: `create_workspace`,
  `output_enter/leave`, `workspace_enter/leave`. Handle: `id`, `name`, `coordinates`,
  `state(uint)` with bits `active=1`, `urgent=2`, `hidden=4`; `capabilities` with
  `activate=1`, `deactivate=2`, `remove=4`, `assign=8`; requests `activate`,
  `deactivate`, `assign`, `remove`.
* `cosmic-workspace` and `zext_workspace_manager_v1`: UNVERIFIED (not fetched).

**GNOME Shell.**
* `org.gnome.Shell.Introspect` (GNOME-INTRO, read): methods `GetWindows() -> a{ta{sv}}`,
  `GetRunningApplications() -> a{sa{sv}}`; signals `WindowsChanged`,
  `RunningApplicationsChanged`; properties `AnimationsEnabled`, `ScreenSize (ii)`.
  Whether it is restricted to trusted callers is UNVERIFIED (gnome-shell source path
  not reachable). Workspace control needs an extension (UNVERIFIED).

**KDE / KWin.** Scripting over D-Bus is the route named in the brief. Nothing specific
was verified (kwin source paths did not resolve). UNVERIFIED.

**X11 fallback (EWMH).** `_NET_ACTIVE_WINDOW` and `_NET_CLIENT_LIST_STACKING` atoms
(XWIN `x11_api.rs`, grep). `_NET_CLIENT_LIST`, `_NET_CURRENT_DESKTOP` and window
properties are UNVERIFIED (not read in full).

#### macOS

* Window list: `CGWindowListCopyWindowInfo(CGWindowListOption, CGWindowID) -> CFArray?`
  (AJ-cgwindowlistcopywindowinfo, read; macOS 10.5). Options used by x-win:
  `OptionOnScreenOnly | ExcludeDesktopElements` (XWIN `macos/api.rs`, grep).
  Window titles need Screen Recording permission (UNVERIFIED in this session; HS-WIN
  and XWIN both use the call).
* Focus and app change: `NSWorkspace.didActivateApplicationNotification` (AJ, read;
  "posted when the Finder is about to activate an app"; the `NSWorkspaceApplicationKey`
  name in the userInfo is UNVERIFIED). Frontmost app: `NSWorkspace.frontmostApplication`
  (UNVERIFIED here).
* Accessibility (per-window state, raise, move): `AXUIElementCreateApplication`,
  `kAXWindowsAttribute`, `kAXRaiseAction`, `AXObserver` (UNVERIFIED; doc paths 404;
  yabai `extern.h` shows `_AXUIElementGetWindow` used privately, grep).
* Spaces (private): `SLSMainConnectionID`, `SLSCopyManagedDisplaySpaces`,
  `SLSGetActiveSpace`, `SLSCopySpacesForWindows`, `SLSMoveWindowsToManagedSpace`,
  `SLSSpaceGetType`, `SLSSetWindowListWorkspace` (HS-SPACES, grep; `SLSCopySpacesForWindows`
  and `SLSMainConnectionID` also in YABAI `extern.h`, grep). Dictionary shape of
  `SLSCopyManagedDisplaySpaces` is UNVERIFIED (not read in full).
* Space change event: `NSWorkspace.activeSpaceDidChangeNotification` (AJ, read; "the
  notification doesn't contain a dictionary").
* Control: yabai's README says controlling windows that require elevated privileges
  needs a scripting addition injected into Dock.app, and that this requires partially
  disabling SIP (YABAI README, read). Without SIP changes, moving windows between Spaces
  is not available. (single-source)

#### Windows

* Enumerate: `EnumWindows` plus `GetWindowTextW`, `GetWindowThreadProcessId`,
  `GetWindowPlacement`, `IsIconic` (MS pages: `GetWindowThreadProcessId` and `IsIconic`
  checked by grep; `EnumWindows`, `GetWindowTextW` and `GetWindowPlacement` not checked, UNVERIFIED). x-win uses `EnumChildWindows`,
  `GetForegroundWindow`, `GetWindowRect` (XWIN `win32/api.rs`, grep).
* Alt-Tab predicate (RC, read): for each window, walk to `GetAncestor(hwnd, GA_ROOTOWNER)`
  and use the last active visible popup in that owner chain. A window with `WS_EX_TOOLWINDOW`
  is treated as not visible; a window with `WS_EX_APPWINDOW` is treated as having no owner.
  Cloaked windows are a separate filter: `DwmGetWindowAttribute(DWMWA_CLOAKED)`
  (MS-dwm `DWMWA_CLOAKED`, grep: the attribute name is on the page; the cloaked semantics
  are not read).
* Events: `SetWinEventHook(event_min, event_max, hmod, proc, pid, tid, flags)` with
  `WINEVENT_OUTOFCONTEXT` (MS-setwineventhook, grep: the flag and the `SKIPOWNPROCESS` /
  `SKIPOWNTHREAD` variants are on the page). The event constants `EVENT_SYSTEM_FOREGROUND`,
  `EVENT_OBJECT_CREATE/DESTROY/NAMECHANGE/SHOW/HIDE/CLOAKED` are UNVERIFIED (not on the
  page read).
* Shell events: `RegisterShellHookWindow` with `HSHELL_WINDOWCREATED` (MS-registershellhookwindow,
  grep: the name is on the page). Use as a second source if the win-event hook misses events.
* Foreground rules: `SetForegroundWindow` only succeeds when the caller is the foreground
  process, was started by it, received the last input event, or similar (MS-setforegroundwindow,
  read). Activation from a background bar needs one of these conditions or
  `LockSetForegroundWindow` opt-out by the other process.
* Virtual desktops, documented: `IVirtualDesktopManager` with `IsWindowOnCurrentVirtualDesktop`
  and `GetWindowDesktopId` (MS-ivirtualdesktopmanager, read). Its IID
  `A5CD92FF-29BE-454C-8D04-D82879FB3F1B` (WINVD `interfaces.rs`, read; not on the MS page).
* Virtual desktops, undocumented (the switch/create/move path): WINVD `interfaces.rs` (read)
  defines `CLSID_VirtualDesktopManagerInternal` `C5E0CDCA-7B6E-41B2-9FC4-D93975CC467B`,
  `IVirtualDesktopManagerInternal` `53F5CA0B-158F-4124-900C-057158060B27`,
  `IVirtualDesktop` `3F07F4BE-B107-441A-AF0F-39D82529072C`,
  `IVirtualDesktopNotificationService` `0CD45E71-D927-4F15-8B0A-8FEF525337BF`,
  `IApplicationView` `372E1D3B-38D3-42E4-A15B-8AB2B178F513`, and
  `IApplicationViewCollection` `1841C6D7-4F9D-42C0-AF41-8747538F10E5`.
  **These IIDs change per Windows build.** MScholtes (MSCH, read) says Windows 11
  23H2 Release 3085 changed the COM GUIDs again and ships separate builds for Windows 10,
  11, 11 24H2, Server 2016 and 2022. Treat these IIDs as valid only for the build they
  were tested on. A build-to-IID table has not been built here.

### 3. Reference implementations (prove it works)

| Project | Language | File | What to copy the idea of | Depth |
| --- | --- | --- | --- | --- |
| Waybar | C++ | `src/modules/hyprland/window.cpp`, `hyprland/workspaces.cpp` | Subscribes to `activewindow`, `closewindow`, `workspacev2`; creates workspaces from monitor data | grep (excerpts) |
| Waybar | C++ | `src/modules/sway/window.cpp`, `sway/workspaces.cpp` | Sway IPC subscribe and tree walk | grep |
| Waybar | C++ | `src/modules/niri/window.cpp`, `niri/workspaces.cpp` | Subscribes to `WindowOpenedOrChanged`, `WindowFocusChanged` (WB-niri-window, read: lines 17-19) | grep |
| Waybar | C++ | `src/modules/wlr/taskbar.cpp` | `zwlr_foreign_toplevel` state mapping and `activate()` | grep (lines 422-457 read) |
| hyprland-rs | Rust | `src/shared.rs`, `src/data/regular.rs`, `src/event_listener/` | Socket paths, `j/` flag, `Client` struct | read |
| niri-ipc | Rust | `src/lib.rs`, `src/socket.rs` | Request/Event enums, `NIRI_SOCKET` | read |
| swayipc / swayipc-types | Rust | `src/common.rs`; `command.rs`, `event.rs`, `lib.rs` | i3-ipc framing and message type numbers | read / grep |
| winvd | Rust | `src/interfaces.rs`, `src/comobjects.rs` | Undocumented COM interfaces, IIDs | read |
| MScholtes/VirtualDesktop | C# | `README.md` | Per-build interface variants (Win 10 / 11 / 11 24H2 / Server) | README |
| Eun/MoveToDesktop | C# | `README.md` | Move-window-to-desktop feature only | README (intro only) |
| x-win | Rust | `src/linux/api/x11_api.rs`, `src/macos/api.rs`, `src/win32/api.rs` | Window list per OS, EWMH atoms, CGWindowList options | grep |
| Hammerspoon | ObjC | `extensions/spaces/libspaces.m`, `extensions/window/libwindow.m` | SkyLight Spaces; CGWindowList window list | grep |
| yabai | C | `src/misc/extern.h`, `README.md` | SkyLight externs; SIP caveat | grep / README |
| AltTab-macos | Swift | (paths 404) | Not reached | not read |
| AutoHotkey, PowerToys | C++/AHK | (paths 404) | Not reached | not read |

### 4. Double validation

| Claim | Source 1 | Source 2 | Status |
| --- | --- | --- | --- |
| Hyprland socket names `.socket.sock` and `.socket2.sock` | HYPR-WIKI | HYPR-RS `shared.rs` | 2 sources |
| `EVENT>>DATA\n` line format | HYPR-WIKI | none for the parser (HYPR-RS `event_listener/shared.rs` not read in full) | (single-source) |
| Hyprland event list (`activewindowv2`, `openwindow`, ...) | HYPR-WIKI | Waybar `hyprland/window.cpp` subscribes to `activewindow` and `closewindow` | 2 sources for those two |
| Hyprland `Client` has no minimized field | HYPR-RS `regular.rs` | none | (single-source) |
| `j/` JSON flag | HYPR-RS `shared.rs` (`CommandFlag::JSON`) | HYPR-WIKI says `[flag(s)]/command` | 2 sources (flag letter from one) |
| Sway magic bytes `i3-ipc` | SWAY-T `lib.rs` (`MAGIC`) | SWAY `common.rs` (checks `MAGIC`) | 2 sources |
| Sway message type numbers (GET_WORKSPACES=1, ...) | SWAY-T `command.rs` | none | (single-source) |
| Sway `xkb_active_layout_name` field | WB-sway-language (grep) | none | (single-source) |
| niri event variants | NIRI `lib.rs` | none | (single-source) |
| niri `Window` has no minimized field | NIRI `lib.rs` (fields read) | none | (single-source) |
| `ext_foreign_toplevel_list` carries no state | WP-FTL | none | (single-source) |
| wlr toplevel state enum values | WLR-TL | Waybar `taskbar.cpp` `handle_state` uses the `ZWLR_..._STATE_*` constants | 2 sources |
| `WINEVENT_OUTOFCONTEXT` flag | MS-setwineventhook (grep) | none | (single-source) |
| `IVirtualDesktopManager` IID | WINVD `interfaces.rs` | MS page does not show the IID | (single-source) |
| Undocumented virtual-desktop IIDs change per build | MSCH README | WINVD (single build) | 2 sources (that they change) |
| Alt-Tab predicate rules | RC | none | (single-source) |
| `SetForegroundWindow` conditions | MS-setforegroundwindow | none | (single-source) |
| Spaces private symbols exist | HS-SPACES | YABAI `extern.h` | 2 sources |
| yabai needs SIP partly disabled for window-server control | YABAI README | none | (single-source) |
| `CGWindowListCopyWindowInfo` signature | AJ | XWIN `macos/api.rs` | 2 sources |
| `NSWorkspace.didActivateApplication` posted when activating | AJ | none | (single-source) |

### 5. Proposed Bleu model

```c3
module bleu::windows;

// Plain data only. Ids are String, owned by the snapshot.
struct Rect { int x; int y; int w; int h; }

struct WindowInfo {
    String id;               // hypr address, niri id, sway con_id, HWND, CGWindowID
    String title;
    String app_id;           // wayland app_id / hypr class / macOS bundle id / win32 class
    int pid;                 // -1 when unavailable (ext-foreign-toplevel-list)
    String workspace_id;     // "" when unknown
    String output_id;        // "" when unknown
    bool focused;
    bool floating;
    bool fullscreen;
    bool maximized;
    bool minimized;
    bool urgent;
    bool has_geometry;       // false when the backend cannot report it
    Rect geometry;
}

struct WorkspaceInfo {
    String id;
    String name;
    String output_id;
    bool active;
    bool urgent;
    bool hidden;
}

enum WindowsCap : char {
    LIST_WINDOWS, FOCUSED_WINDOW, LIST_WORKSPACES, SWITCH_WORKSPACE,
    CREATE_WORKSPACE, FOCUS, CLOSE, MINIMIZE, MOVE_TO_WORKSPACE,
    MAXIMIZE, TOGGLE_FLOATING, FULLSCREEN, WINDOW_EVENTS, WORKSPACE_EVENTS,
}

enum WindowsEvent : char {
    WINDOW_OPENED, WINDOW_CLOSED, WINDOW_CHANGED, FOCUS_CHANGED,
    WORKSPACE_CHANGED, WORKSPACE_CREATED, WORKSPACE_DESTROYED, MONITOR_CHANGED,
}

enum WindowsBackend : char {
    HYPRLAND, NIRI, SWAY, WLR_TOPLEVEL, EXT_TOPLEVEL_LIST, GNOME_INTROSPECT,
    X11_EWMH, MACOS_AX_SKYLIGHT, MACOS_CG_LIST, WIN32_ENUM, WIN32_VDM_PRIVATE,
}
```

Notes on fields: `minimized` is `false` on Hyprland and niri because the IPC data has no
such field. `pid` is `-1` on Wayland data-control backends that lack it. Private Windows
backends (`WIN32_VDM_PRIVATE`) must resolve IIDs per build via `bleu::dl`.

### 6. Risks and cut lines

* Hard: workspace control on macOS needs private SkyLight calls and a scripting addition
  that requires disabling SIP. **Cut** from v1 (read-only Spaces through public APIs and
  the change notification).
* Hard: Windows undocumented virtual-desktop interfaces are per-build. Ship
  `IVirtualDesktopManager` (documented, window-to-desktop query only) in v1. Put
  `IVirtualDesktopManagerInternal` (switch, create, move) behind a `WIN32_VDM_PRIVATE`
  backend with a build table. **Cut** from v1 unless the table is built.
* Hard: Wayland generic protocols lack pid, geometry and workspace. Prefer a compositor
  IPC backend; fall back to `ext-foreign-toplevel-list` for titles only.
* Hard: minimize is unsupported on Hyprland and niri per their data. Expose
  `UNSUPPORTED` rather than fake it.
* GNOME needs an extension for workspace control, and Introspect may be restricted
  (UNVERIFIED). **Cut** from v1.
* Win32 `SetForegroundWindow` may refuse activation from a background process. Expect
  focus requests to fail silently and return the status, not an error.
* Recommend v1: Hyprland, sway and niri IPC (full set), `wlr-foreign-toplevel` as a
  focus-only fallback, and Windows `EnumWindows` plus `WINEVENT` hooks. Cut
  Spaces control, undocumented Windows desktop switching, and GNOME/KDE.

---

## clipboard

### 1. What a shell needs

1. Read and write text, with rich text and images as secondary.
2. Watch for changes (clipboard counter or event, not polling where avoidable).
3. Primary selection (Linux middle-click).
4. History that survives the source app exiting (cliphist-style).
5. Password-manager hints: skip entries the source marked as secret/transient.
6. File lists and arbitrary MIME as optional.

### 2. Per-platform native route (Linux / macOS / Windows)

#### Linux (Wayland)

**Route C1 (preferred): `ext-data-control-v1`.**
* `ext_data_control_manager_v1.get_data_device(new_id, wl_seat)` (WP-DC, read).
* `ext_data_control_device_v1`: `set_selection(source?)`, `set_primary_selection(source?)`;
  events `data_offer(new_id)`, `selection(offer?)`, `primary_selection(offer?)`,
  `finished` (WP-DC, read).
* `ext_data_control_offer_v1`: event `offer(mime_type)` for each MIME; request
  `receive(mime_type, fd)` (WP-DC, read).
* `ext_data_control_source_v1`: request `offer(mime_type)`; events `send(mime_type, fd)`
  and `cancelled` (WP-DC, read). "The data source has been replaced by another data source."
* Works without window focus (inference from the protocol's device model; not stated in
WP-DC). This is what a clipboard manager needs.

**Route C2 (fallback): `zwlr_data_control_manager_v1` v2 (wlroots).** Same shape as C1
(WLR-DC, read: same requests and events). `wl-clipboard-rs` supports both C1 and C2
(WLCB `data_control.rs`, grep: `ExtDataControl*` and `ZwlrDataControl*` imports).

**Primary selection.** Two options:
* `zwp_primary_selection_device_manager_v1` (WP-PRIM, read): `set_selection(source, serial)`
  with a serial; events `data_offer`, `selection`. Note: this one needs a serial and focus.
* `ext_data_control` `set_primary_selection` and `primary_selection` event (WP-DC, read).
  Preferred for a clipboard manager (no focus needed).

**Focus-based set (must have focus or serial).** `wl_data_device.set_selection` requires a
serial from input. Not read in this spike (UNVERIFIED).

**Ownership and persistence.** When the source client exits, the selection is gone
(inference from the protocol: the source object is destroyed and the offer dies). A
history manager must `receive` each MIME into its own storage while it still has the
offer. (inference; the persistence semantics are not spelled out in WP-DC.)

**Pipes.** `receive` and `send` pass an `fd` (WP-DC, read). The receiver reads until EOF.
The sender writes and closes. Use non-blocking reads with a deadline; a stalled source
blocks forever otherwise. (inference)

**X11 fallback.** `CLIPBOARD`, `PRIMARY`, `INCR` (brief; UNVERIFIED here, not read).

#### macOS

* Watch: `NSPasteboard.general.changeCount` is the only change signal. "The change count
  increments each time the pasteboard ownership changes" (AJ-nspasteboard-changecount,
  read). Poll it on a timer (cheap). There is no notification.
* Read/write: `NSPasteboardTypeString`, `NSPasteboardTypeTIFF`, `NSPasteboardTypeHTML`
  used by arboard (ARB `osx.rs`, grep). `NSPasteboardTypePNG`, `NSPasteboardTypeFileURL`:
  UNVERIFIED (doc paths 404).
* Concealed/transient markers: `org.nspasteboard.ConcealedType` (ARB `osx.rs`, grep:
  "an unofficial standard ... nspasteboard.org"). `org.nspasteboard.TransientType`:
  UNVERIFIED.
* macOS 15.4 pasteboard privacy prompt (`accessBehavior` / `detectPatterns`): UNVERIFIED.
  Doc paths 404. Treat as a cut risk until checked on hardware.

#### Windows

* Watch: `AddClipboardFormatListener(hwnd)` then `WM_CLIPBOARDUPDATE`, "whenever the
  contents of the clipboard have changed" (MS-addclipboardformatlistener, read).
  `GetClipboardSequenceNumber()` gives a counter (MS page fetched, not read; UNVERIFIED).
* Formats (MS-clipboard-formats, read): `CF_BITMAP`, `CF_DIB`, `CF_DIBV5` are on the page.
  `CF_UNICODETEXT` and `CF_HDROP` values (13 and 15 in winuser.h): UNVERIFIED (not on the page read).
* History and exclusion markers (MS-clipboard-formats, read):
  `ExcludeClipboardContentFromMonitorProcessing` ("place any data ... in this format to
  prevent all clipboard formats being included in the clipboard history or synchronized").
  `CanIncludeInClipboardHistory`: a serialized DWORD, 0 to exclude, 1 to request inclusion.
  Both are registered formats, not fixed numbers.
* Windows history API (`Windows.ApplicationModel.DataTransfer.Clipboard`): UNVERIFIED.

### 3. Reference implementations (prove it works)

| Project | Language | File | What to copy the idea of | Depth |
| --- | --- | --- | --- | --- |
| wl-clipboard-rs | Rust | `src/data_control.rs` | Supports both ext and wlr data-control | grep |
| arboard | Rust | `src/platform/osx.rs` | `ConcealedType` marker; pasteboard types | grep |
| global-hotkey (no clipboard) | Rust | n/a | n/a | n/a |
| cliphist, wl-clipboard (C), clipboard-manager | Go/C | (paths 404) | history persistence (cliphist is the brief's example) | not reached |
| copyq, clipboard-rs | C++/Rust | not fetched | not read | not read |

### 4. Double validation

| Claim | Source 1 | Source 2 | Status |
| --- | --- | --- | --- |
| `ext_data_control` offer/receive/send/cancelled | WP-DC | WLCB `data_control.rs` uses the same types | 2 sources |
| Primary selection in ext_data_control | WP-DC | none | (single-source) |
| `zwp_primary_selection` needs a serial | WP-PRIM | none | (single-source) |
| `changeCount` increments on ownership change | AJ | none | (single-source) |
| `org.nspasteboard.ConcealedType` | ARB (grep) | none | (single-source) |
| `WM_CLIPBOARDUPDATE` on change | MS-addclipboardformatlistener | none | (single-source) |
| `ExcludeClipboardContentFromMonitorProcessing` / `CanIncludeInClipboardHistory` | MS-clipboard-formats | none | (single-source) |

### 5. Proposed Bleu model

```c3
module bleu::clipboard;

// Metadata only in State. Payload bytes are fetched on demand, never published.
struct ClipboardItemMeta {
    String id;               // stable id assigned by the history store
    ulong seq;               // change counter or sequence number when captured
    String[] mime_types;
    bool concealed;          // password-manager hint (ConcealedType / ExclusionFormat)
    bool transient;          // do not store in history
}

struct ClipboardState {
    bool current_known;
    ulong seq;
    String[] current_mime_types;
    bool current_concealed;
    bool primary_known;
    String[] primary_mime_types;
}

enum ClipboardCap : char {
    READ_TEXT, WRITE_TEXT, READ_RICH, WRITE_RICH, READ_IMAGE, WRITE_IMAGE,
    READ_FILES, WRITE_FILES, READ_ARBITRARY_MIME, WATCH, PRIMARY_SELECTION,
    HISTORY, CONCEALED_HINT,
}

enum ClipboardBackend : char {
    WL_EXT_DATA_CONTROL, WL_WLR_DATA_CONTROL, X11, MACOS_PASTEBOARD, WIN32_CLIPBOARD,
}
```

Note: these snippets are a sketch and have not been type-checked with `c3c` (`String[]`
slices and `ulong` width in particular). Read, write and history operate on
`Operation{...}` per the contract (not modelled here).

### 6. Risks and cut lines

* Hard: Wayland clipboard history requires a long-lived client holding offers. Compositor
  focus rules do not apply to data-control, but they still need the seat.
* Hard: `receive` pipes can stall; use deadlines and a size cap, and never trust the
  source's MIME list.
* macOS: no change event (polling). Choose an interval and document the cost.
* macOS 15.4 privacy prompt: UNVERIFIED. Risk until a real machine is tested.
* Windows history API is WinRT; not reached.
* Recommend v1: text only, MIME list, watch, and concealed/exclusion markers on each
  platform. **Cut** from v1: image and file-list history, rich-text round-trips, and the
  Windows WinRT history.

---

## hotkey

### 1. What a shell needs

1. Register a global shortcut by id with a description (for a settings UI).
2. Press and release events, with a timestamp.
3. Unregister.
4. Conflict reporting (already taken).
5. Works while focus is in another app.

### 2. Per-platform native route (Linux / macOS / Windows)

#### Linux

**Route H1 (preferred where available): `org.freedesktop.portal.GlobalShortcuts`.**
* The document describes version 2 of the interface (XDP-GS, read).
* `CreateSession(a{sv} options) -> o handle` (XDP-GS, read).
* `BindShortcuts(o session_handle, a(sa{sv}) shortcuts, s parent_window, a{sv} options) -> o request_handle`
  (XDP-GS, read).
* `ListShortcuts(o session_handle, a{sv} options) -> o request_handle` (XDP-GS, read; the
  file marks this method "added in version 2"). `ConfigureShortcuts(o session_handle,
  s parent_window, a{sv} options)` (XDP-GS, read; its version marker was not checked).
* Signals: `Activated(o session_handle, s shortcut_id, t timestamp, a{sv} options)`,
  `Deactivated(...)` (same args), `ShortcutsChanged(o session_handle, a(sa{sv}) shortcuts)`
  (XDP-GS, read). Press = `Activated`, release = `Deactivated`.
* Per-compositor support: UNVERIFIED for KDE, GNOME and Hyprland (xdg-desktop-portal
  backends not read). Do not assume support.
* Key: a portal session is bound to the bus connection. Keep it alive or re-bind.

**Route H2 (Hyprland native): `hyprland_global_shortcuts_manager_v1`.**
* `register_shortcut(new_id, id, app_id, description, trigger_description)` (HYPR-GS, read).
  Error: `already_taken = 0`.
* `hyprland_global_shortcut_v1` events: `pressed(tv_sec_hi, tv_sec_lo, tv_nsec)` and
  `released(...)` (HYPR-GS, read).
* Use when running under Hyprland and the portal backend is absent (UNVERIFIED that the
  portal backend exists on a given system).

**Route H3 (X11): XGrabKey.** `global-hotkey` 0.7.0 implements Linux hotkeys only for
X11 (module tree: `platform_impl/{macos,windows,x11,no-op}`; GHK, grep). Its `x11/mod.rs`
notes `XGrabKey` works only with exact modifier states (GHK, grep line 101). On Wayland
it has no backend (no-op).

**Route H4: KGlobalAccel (KDE)** and compositor-specific bindings: UNVERIFIED.

**Inhibit (for a recorder or a game).** `zwp_keyboard_shortcuts_inhibit_manager_v1`
`inhibit_shortcuts(new_id, wl_surface, wl_seat)`, events `active` and `inactive` (WP-KBINH,
read). Already inhibited on the same surface and seat is `already_inhibited` (WP-KBINH, read).

#### macOS

* Carbon `RegisterEventHotKey(keycode, mods, hotKeyID, GetEventDispatcherTarget(),
  kEventHotKeyExclusive, &ref)` and `UnregisterEventHotKey` (HS-HK, grep: call sites at
  lines 258 and 286). Events `kEventHotKeyPressed` and `kEventHotKeyReleased` (HS-HK, grep).
  No TCC permission is needed for Carbon hotkeys (UNVERIFIED here; from the brief).
* `CGEventTapCreate(kCGSessionEventTap, ... kCGEventTapOptionDefault ...)` (HS-ET, grep).
  Needs Accessibility or Input Monitoring TCC (UNVERIFIED here; doc 404).
* `NSEvent.addGlobalMonitorForEvents(matching:handler:)` (AJ, read): "observe only; cannot
  modify or prevent the event from being delivered. Key-related events may only be monitored
  if accessibility is enabled or if your application is trusted for accessibility access."

#### Windows

* `RegisterHotKey(hWnd, id, fsModifiers, vk)`; the modifier flags `MOD_ALT 0x0001`,
  `MOD_CONTROL 0x0002`, `MOD_SHIFT 0x0004`, `MOD_WIN 0x0008`, `MOD_NOREPEAT 0x4000`
  (MS-registerhotkey, read). `WM_HOTKEY` is delivered to `hWnd` or to the thread queue
  when `hWnd` is NULL (MS-registerhotkey, read; `WM_HOTKEY` name on the page).
* Low-level: `SetWindowsHookEx(WH_KEYBOARD_LL, ...)` (MS-setwindowshookex, grep: the
  constant is on the page). Global, but heavier and can be removed by the OS if slow.
* Conflicts: "If a hot key already exists with the same hWnd and id parameters, see
  Remarks" (MS-registerhotkey, read). Conflicts with other apps surface as a failure of
  `RegisterHotKey`.

### 3. Reference implementations (prove it works)

| Project | Language | File | What to copy the idea of | Depth |
| --- | --- | --- | --- | --- |
| global-hotkey | Rust | `src/platform_impl/{windows,macos,x11}/mod.rs` | One API over three OS backends; Wayland no-op | grep |
| Hammerspoon | ObjC | `extensions/hotkey/libhotkey.m` | Carbon press/release, exclusive flag | grep |
| Hammerspoon | ObjC | `extensions/eventtap/libeventtap.m` | `CGEventTapCreate` on session tap | grep |
| Hyprland | C++ | `hyprland-protocols` XML | Native global shortcuts | read (XML) |
| xdg-desktop-portal | C | `data/org.freedesktop.portal.GlobalShortcuts.xml` | Portal contract | read (XML) |
| ashpd | Rust | crate 0.10.2 (downloaded) | Portal client | not read |

### 4. Double validation

| Claim | Source 1 | Source 2 | Status |
| --- | --- | --- | --- |
| Portal `Activated`/`Deactivated` signatures | XDP-GS | none | (single-source) |
| Portal version 2 includes `ListShortcuts` and `ConfigureShortcuts` | XDP-GS (header and method note) | none | (single-source) |
| Hyprland `register_shortcut` args | HYPR-GS | none | (single-source) |
| Carbon `RegisterEventHotKey` and exclusive flag | HS-HK | none | 2 sources (only HS, so single) |
| `CGEventTapCreate` on session tap | HS-ET | none | (single-source) |
| `addGlobalMonitorForEvents` observe-only | AJ | none | (single-source) |
| `RegisterHotKey` modifier values | MS-registerhotkey | none | (single-source) |
| `global-hotkey` Linux = X11 only | GHK module tree | none | (single-source) |

### 5. Proposed Bleu model

```c3
module bleu::hotkey;

typedef ModMask = uint;      // bit flags; values are backend-defined, see KeyChord

struct KeyChord {
    String key;              // canonical key name, e.g. "Space"
    ModMask mods;            // platform-normalised modifier bits
}

struct HotkeyRegistration {
    String id;
    String description;
    KeyChord chord;
    bool registered;
    bool conflict;           // true when the platform reports already taken
}

enum HotkeyEvent : char { PRESSED, RELEASED }

enum HotkeyCap : char { REGISTER, UNREGISTER, PRESS_RELEASE, CONFLICT_REPORT, INHIBIT }

enum HotkeyBackend : char {
    PORTAL_GLOBAL_SHORTCUTS, HYPRLAND_NATIVE, X11_GRAB, MACOS_CARBON,
    MACOS_EVENT_TAP, WIN32_REGISTER_HOTKEY, WIN32_LOW_LEVEL_HOOK,
}
```

### 6. Risks and cut lines

* Hard: Wayland has no universal global shortcut. The portal is the only standard route
  and its per-compositor support is UNVERIFIED. Report `UNSUPPORTED_BACKEND` honestly.
* Hard: macOS event taps need TCC; Carbon does not (UNVERIFIED for Carbon).
* Hard: Windows low-level hooks can be slow or removed by the OS, and `RegisterHotKey`
  conflicts are silent unless checked.
* Recommend v1: Windows `RegisterHotKey`, macOS Carbon `RegisterEventHotKey`, and the
  Linux portal where available. **Cut** from v1: event taps, low-level hooks, KGlobalAccel,
  and the X11 grab path (add if X11 must be supported).

---

## input

### 1. What a shell needs

1. Keyboard layout list, current layout, and a switch request.
2. Layout-change events.
3. Caps lock and num lock state, with change events.
4. Optional read-only pointer and keyboard settings (repeat rate, natural scroll, pointer speed).

### 2. Per-platform native route (Linux / macOS / Windows)

#### Linux

**Compositor IPC.**
* Hyprland: `activelayout` event with `KEYBOARDNAME,LAYOUTNAME` (HYPR-WIKI, read). The
  keyboard struct has `active_keymap: String` (HYPR-RS `regular.rs`, read). The
  `devices` command (HYPR-RS display name `devices`, read).
* Sway: `GET_INPUTS` (type 100, SWAY-T `command.rs`, read). Input objects carry
  `xkb_layout_names` and `xkb_active_layout_name` (WB-sway-language, grep:
  `XKB_LAYOUT_NAMES_KEY`, `XKB_ACTIVE_LAYOUT_NAME_KEY`). Events: `Input` in the subscribe
  list (SWAY-T `event.rs`, read).
* niri: `KeyboardLayouts { names: Vec<String>, current_idx: u8 }` (NIRI `lib.rs`, read).
  Events `KeyboardLayoutsChanged{keyboard_layouts}` and `KeyboardLayoutSwitched{idx}`
  (NIRI `lib.rs`, read). Switching a layout is an action; the name is UNVERIFIED.
* XKB on Wayland (`wl_keyboard` keymap fd, `xkb_state`): UNVERIFIED (not read).

**Caps / num / scroll lock.**
* Compositor IPC carries no lock-state event in the Hyprland list (HYPR-WIKI, read) or
  niri/sway events read.
* Waybar reads LEDs from evdev: `EV_LED` with `LED_CAPSL`, `LED_NUML`, `LED_SCROLLL` via
  libevdev on `/dev/input` devices (WB-keyboard-state, grep, lines 343-396). It binds
  key codes `KEY_CAPSLOCK`, `KEY_NUMLOCK`, `KEY_SCROLLLOCK` (grep line 191-193). (single-source)
* Needs read access to `/dev/input/event*` (group `input` on most distros, UNVERIFIED here).

**Localectl / locale1.** `org.freedesktop.locale1` and `localectl` are named in the brief;
not read (UNVERIFIED).

**Pointer and keyboard settings.** Read-only and optional. Compositor config (hyprland
`input` section, sway `input` config, niri) is the route; not read (UNVERIFIED).

#### macOS

* `TISCopyCurrentKeyboardInputSource`, `TISCreateInputSourceList`, `TISSelectInputSource`,
  `kTISNotifySelectedKeyboardInputSourceChanged` (brief; the HIToolbox doc paths 404,
  UNVERIFIED).
* Caps/num lock: `NSEvent.modifierFlags` (`.capsLock`) and `CGEventSourceFlagsState` (UNVERIFIED).

#### Windows

* `GetKeyboardLayoutList` (MS-getkeyboardlayoutlist, grep: the name is on the page). `GetKeyboardLayout`,
  `ActivateKeyboardLayout`: UNVERIFIED (not on the page read).
* `WM_INPUTLANGCHANGE`: UNVERIFIED (not on the page read).
* `GetKeyState(VK_CAPITAL)`, `VK_NUMLOCK` (toggle bit = low-order bit): UNVERIFIED
  (MS-getkeystate fetched, grep not run for these names).
* Keyboard repeat: `SystemParametersInfo(SPI_GETKEYBOARDSPEED / SPI_GETKEYBOARDDELAY)`
  (brief; UNVERIFIED).

### 3. Reference implementations (prove it works)

| Project | Language | File | What to copy the idea of | Depth |
| --- | --- | --- | --- | --- |
| Waybar | C++ | `src/modules/sway/language.cpp`, `hyprland/language.cpp` | Layout list from IPC, union of inputs | grep |
| Waybar | C++ | `src/modules/keyboard_state.cpp` | evdev LED state for caps/num/scroll | grep |
| hyprland-rs | Rust | `src/data/regular.rs` | `Keyboard.active_keymap`, `devices` | read |
| niri-ipc | Rust | `src/lib.rs` | `KeyboardLayouts`, events | read |
| swayipc-types | Rust | `src/reply.rs` (Input) | Input reply type | not read |

### 4. Double validation

| Claim | Source 1 | Source 2 | Status |
| --- | --- | --- | --- |
| Sway `xkb_active_layout_name` field | WB-sway-language | none | (single-source) |
| Hyprland `activelayout` event format | HYPR-WIKI | none | (single-source) |
| niri `KeyboardLayouts` and events | NIRI `lib.rs` | none | (single-source) |
| Caps/num lock via evdev LEDs | WB-keyboard-state | none | (single-source) |
| Hyprland and niri expose no lock event | HYPR-WIKI (list), NIRI (events list) | none | 2 sources (for these two) |
| `GetKeyboardLayoutList` exists | MS-getkeyboardlayoutlist | none | (single-source) |

### 5. Proposed Bleu model

```c3
module bleu::input;

struct KeyboardLayouts {
    String[] names;
    uint current;            // index into names
}

struct LockKeys {
    bool caps_known;
    bool caps;
    bool num_known;
    bool num;
    bool scroll_known;
    bool scroll;
}

struct InputState {
    KeyboardLayouts layouts;
    bool layouts_known;
    LockKeys locks;
}

enum InputEvent : char { LAYOUT_LIST_CHANGED, LAYOUT_SWITCHED, CAPS_CHANGED, NUM_CHANGED, SCROLL_CHANGED }

enum InputCap : char { LIST_LAYOUTS, SWITCH_LAYOUT, LOCK_STATE, LAYOUT_EVENTS, LOCK_EVENTS, POINTER_SETTINGS_READ }

enum InputBackend : char { HYPRLAND_IPC, SWAY_IPC, NIRI_IPC, EVDEV_LEDS, MACOS_TIS, WIN32_KEYBOARD }
```

`LockKeys` uses `_known` flags, not optionals, because per-platform availability differs.

### 6. Risks and cut lines

* Hard: lock-key state on Wayland compositors without an event. evdev LEDs need device
  access (a privilege the shell may not want). **Cut** from v1, or make it opt-in and
  `UNSUPPORTED` by default.
* Layout switching on macOS and Windows may be UNVERIFIED for the TIS and Windows calls
  (see Unverified above).
* Pointer and keyboard settings are per-compositor and per-OS. **Cut** from v1 (listed in
  the brief as optional).
* Recommend v1: layout list, current layout and change events on Hyprland, sway and niri;
  Windows `GetKeyboardLayoutList` polling on change messages; macOS TIS. **Cut** from v1:
  evdev LEDs, pointer settings and locale1 writes.

---

## Unverified claims that could cause harm

* Apple: macOS 15.4 pasteboard privacy API, `SACLockScreenImmediate`, `CGSSessionScreenIsLocked`,
  `kCGAnyInputEventType`, `kCGEventSourceStateHIDSystemState` names. Not read here.
* Windows: `EVENT_SYSTEM_FOREGROUND` and `EVENT_OBJECT_*` names, `WM_INPUTLANGCHANGE`,
  `CF_UNICODETEXT`/`CF_HDROP` numeric values, `SPI_GETKEYBOARD*`, `ActivateKeyboardLayout`.
* Hyprland `dispatch` names for close, move-to-workspace, fullscreen, maximize, togglefloating.
* Sway `RUN_COMMAND` criteria syntax for focus and move.
* Wayland: `cosmic-workspace`, `zext_workspace_manager_v1`, portal backend support per
  compositor (KDE, GNOME, Hyprland).
* GNOME Introspect access restrictions and extension requirements.

## Recommended cut lines (cross-service)

1. Session: logind for lock, sleep and sessions on Linux; `ext-idle-notify` for idle;
   no lock-screen code and no PAM. macOS and Windows: public APIs only.
2. Windows: compositor IPC for Linux focus and workspaces; `EnumWindows` plus win-event
   hooks on Windows; documented `IVirtualDesktopManager` only; no undocumented desktop switching in v1.
3. Clipboard: text and MIME list, watch, concealed/exclusion markers; no image or file history in v1.
4. Hotkey: portal (Linux), Carbon (macOS), `RegisterHotKey` (Windows); no event taps or low-level hooks in v1.
5. Input: layout list and change events; no evdev LEDs or pointer settings in v1.
