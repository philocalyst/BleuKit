# bleu_windows

Windows, workspaces (virtual desktops, Spaces, compositor workspaces) and the
focused window, as plain data, with actions on them: what a bar's workspace switcher
and focused-window title need. Module root `bleu::windows`. Service contract:
`docs/ARCHITECTURE.md`. Verification and deviations from the research:
`docs/research/windows_impl.md`; the spec is `docs/research/session_windows_input.md`.

## Public API

* `windows::open(allocator, Options) -> Windows*?`: picks the first backend that works
  (`Options.backend` forces one). `close()` releases it.
* `latest() -> Snapshot{State}*?`, `wait_after(generation, timeout)`, `watch`/`unwatch`:
  the whole `State` (connection, status, focused window id, windows, workspaces, outputs,
  `titles_available`).
* `subscribe() -> Reader{Event}*?`: `WINDOW_OPENED/CLOSED/CHANGED`, `FOCUS_CHANGED`,
  `WORKSPACE_ADDED/REMOVED/CHANGED`, `CONNECTION_CHANGED`. Re-read `latest()` for values.
* Actions return `Operation{bool}*?` (value `true` once accepted): `focus_window`,
  `close_window`, `minimize_window`, `switch_workspace`, `move_window_to_workspace`,
  `toggle_floating`, `toggle_fullscreen`. An action the backend cannot do is refused at
  once (`UNSUPPORTED`, `PERMISSION_DENIED`), never queued.
* `capability(Cap) -> Availability`: each `Cap` is `YES`, `DEGRADED` (works with a
  caveat in `note`), or refused with the reason (`UNSUPPORTED_*`, `PERMISSION_NEEDED`).
* `refresh()`: re-read the platform now.

## Coverage

Run = executed against the fakes in `tests/` (Linux). Compiled = type-checked for the
target, never executed. Not done = refused with `UNSUPPORTED_*` or not implemented.

| Capability | Linux compositor (Hyprland, sway, i3, niri) | Windows (`win32`) | macOS (`macos`) |
| --- | --- | --- | --- |
| State and events | Run (Hyprland, sway, i3, niri) | Compiled (Alt-Tab rules: Run, pure) | Compiled |
| Window titles | Run | Compiled | Compiled; `PERMISSION_NEEDED` without Screen Recording |
| Focused window | Run | Compiled; `DEGRADED` (foreground lock) | Compiled; activates the app |
| Workspaces | Run (Hyprland, sway, i3, niri) | Compiled; `DEGRADED`: only desktops that hold a window | Compiled: the focused screen's Space with `allow_private`; otherwise refused |
| Switch workspace | Run (Hyprland, sway, niri) | Not done (undocumented API) | Not done (SIP) |
| Move window to workspace | Run (Hyprland log; sway and niri replies) | Compiled (documented `MoveWindowToDesktop`) | Not done (SIP) |
| Close window | Run (Hyprland log; sway, niri replies) | Compiled (`WM_CLOSE`) | Compiled (Accessibility; `PERMISSION_NEEDED`) |
| Minimize window | Not done (no compositor reports it) | Compiled (`SW_MINIMIZE`) | Compiled (Accessibility; the focused window only) |
| Toggle floating | Run (Hyprland, sway logs) | Not done (no floating state) | Not done |
| Toggle fullscreen | Run (Hyprland log) | Not done | Not done |
| Reconnect and DISCONNECTED | Run (fake restart, no compositor, stale socket) | n/a | n/a |
| Outputs | Run (count only) | Not done (empty list) | Not done (empty list) |

## Not done

* Linux: the `ext-workspace` / `ext-foreign-toplevel-list` Wayland backend for compositors
  with no IPC client (the brief allowed it only if time remained). Output-change events.
  Compositor minimized and pinned state (no compositor client reports them).
* Windows: switching or creating virtual desktops (undocumented
  `IVirtualDesktopManagerInternal`; per-build IIDs); the list of empty desktops; outputs;
  fullscreen and floating; window titles longer than 512 UTF-16 units are cut.
* macOS: the list of Spaces (`SLSCopyManagedDisplaySpaces` shape not verified); moving
  windows between Spaces (needs SIP changes); minimized windows (not on screen, so not
  listed); AX close and minimize act on the owning application's focused window only;
  fullscreen; outputs.
* Windows and macOS: one service per process. The hook and the notification observer
  reach their hub through a module global, so a second service would replace the first.
* macOS: notification-driven change needs the main thread's run loop; the 1 s poll
  covers the gap.

## Verified how

* Linux, run: `tests/run.sh` starts the fakes that `libs/bleu_compositor.c3l/tests/` ships
  (by path), runs `tests/live/service_live.c3` against each, and checks 36 output lines and
  the requests the fakes logged. Needs python3 and c3c. The restart scenario kills the
  Hyprland fake, restarts it, and expects `DISCONNECTED` then `CONNECTED`.
* Unit tests (`src/*_test.c3`, `c3c compile-test`): backoff, the Linux model mapping, the
  Windows Alt-Tab predicate, window ids, executable names, workspace grouping and macOS
  window numbers. 106 tests pass in the run that includes the other linked libraries.
* Compiled: `tools/check.sh bleu_core bleu_rt bleu_service bleu_compositor bleu_win
  bleu_objc bleu_dl bleu_windows` is clean on all six targets.
* Windows and macOS code has not been executed. Their constants and signatures were cross-checked
  as listed in `docs/research/windows_impl.md`; the AX names and two SkyLight/AppKit values are
  marked UNVERIFIED in the source.

## API example

    Windows* windows = windows::open(mem)!!;
    defer windows.close();
    Operation{bool}* done = windows.focus_window(window_id)!;
    defer done.release();
    if (catch err = done.wait((Duration)3_000_000)) { /* refused or failed: error::last() says why */ }
