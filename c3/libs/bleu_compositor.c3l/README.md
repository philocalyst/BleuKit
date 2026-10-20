# bleu_compositor

Typed clients for the IPC sockets of Wayland compositors and tiling window
managers: which compositor runs, its workspaces, windows, outputs and keyboard
layouts as plain data, incremental updates from its event stream, and window
manager actions. It is the source a Linux shell uses where no standard protocol
covers the job (`ext-foreign-toplevel-list` has no workspaces, geometry or pid).

Module root `bleu::compositor`. Depends on `bleu_core` and `bleu_rt`. Every module
is `@feat(POSIX)`: on other targets the library compiles empty. Sources and
verification: `docs/research/bleu_compositor.md`.

## The model

`compositor::Model` (plain data, one arena per snapshot):

* `Kind` - `NONE`, `HYPRLAND`, `SWAY`, `I3`, `NIRI`, `RIVER`, `DWL`.
* `Workspace{id, name, output, active, focused, urgent}`. `id` is Hyprland's and
  niri's numeric id, or sway's and i3's workspace *name* (sway addresses workspaces
  by name).
* `Window{id, title, app_id, pid, workspace_id, output, focused, floating,
  fullscreen, maximized, urgent, geometry}`. `id` is a Hyprland address, a niri id
  or a sway container id. `pid`, `fullscreen`, `maximized`, `urgent` and `geometry`
  are `Maybe{T}`: absent when the compositor does not report them.
* `Output{name, geometry, scale, active_workspace, focused}` (enabled outputs only).
* `KeyboardLayouts{keyboard, names, current, current_name}` for the main keyboard.
  `keyboard` is the name (Hyprland) or identifier (sway) the layout events name; only
  an event for that keyboard changes `current_name`.
* `Model.clone(allocator)` is a deep copy: publish a copy, keep mutating the original.
* `Model.sync_outputs(allocator)` recomputes each output's `active_workspace` and `focused`
  from the workspaces. sway and niri call it after a workspace event.

Unknown is never zero: a value a compositor does not report is absent, and a text
field is `""`.

## Public API

* `compositor::detect(allocator) -> Detection{kind, socket, event_socket, reason}`:
  from `HYPRLAND_INSTANCE_SIGNATURE` (+ `XDG_RUNTIME_DIR`), `SWAYSOCK`, `I3SOCK`,
  `NIRI_SOCKET`; then `XDG_CURRENT_DESKTOP` hints (river and dwl are named but
  have no client).
* `connect::open(allocator, detection) -> backend::Backend?` opens the event socket
  and returns the client.
* `interface backend::Backend`: `kind`, `event_handle` (wait on it with a poller),
  `snapshot(allocator) -> Model`, `read_events(&model, allocator) -> Refresh`
  (non-blocking drain), `apply_event(&model, allocator, RawEvent) -> Refresh`
  (pure), actions `focus_window`, `close_window`, `switch_workspace`,
  `move_window`, `set_layout(index)`, `toggle_floating`, `toggle_fullscreen`,
  and `close`.
* `Refresh`: `NONE`, `UPDATED` (the model is current), `REFRESH_NEEDED` (take a
  new snapshot). `combine` keeps the strongest.

Ids passed to actions are the ids of the model. Each backend checks them before
building a command (Hyprland: no whitespace or comma; sway: decimal container
ids and quotable names; niri: decimal ids), so an id cannot add command words.

## Coverage

| | Hyprland | sway | i3 | niri |
| --- | --- | --- | --- | --- |
| Detect | `HYPRLAND_INSTANCE_SIGNATURE` + `XDG_RUNTIME_DIR` | `SWAYSOCK` | `I3SOCK` | `NIRI_SOCKET` |
| Snapshot | `j/clients`, `j/activewindow`, `j/workspaces`, `j/monitors`, `j/devices` | GET_WORKSPACES, GET_OUTPUTS, GET_TREE, GET_INPUTS | same, no GET_INPUTS | Workspaces, Windows, Outputs, KeyboardLayouts |
| Events applied in place | `activewindowv2`, `openwindow`, `closewindow`, `windowtitlev2`, `fullscreen`, `changefloatingmode`, `urgent`, `movewindowv2`, `activelayout` | `window` (focus, title, urgent, floating, fullscreen, close), `workspace` (focus, urgent), `input` (xkb_layout) | same, no `input` | `WorkspacesChanged`, `WorkspaceActivated`, `WorkspaceUrgencyChanged`, `WindowsChanged`, `WindowOpenedOrChanged`, `WindowClosed`, `WindowFocusChanged`, `WindowUrgencyChanged`, `KeyboardLayoutsChanged`, `KeyboardLayoutSwitched` |
| Requests a snapshot | workspace, output, monitor, special-workspace events, `configreloaded`, `movewindowv2` to an unknown window or workspace, a payload without its fields | `output`, `workspace` init/empty/move/rename, `window` new/move | same | `ConfigLoaded` |
| Actions | `focuswindow`, `closewindow`, `workspace`, `movetoworkspace`, `togglefloating`, `fullscreen 0` (after focus), `switchxkblayout` | `[con_id] focus`, `kill`, `workspace "N"`, `move container to workspace`, `floating toggle`, `fullscreen toggle`, `input type:keyboard xkb_switch_layout` | as sway, no layout switch | FocusWindow, CloseWindow, FocusWorkspace, MoveWindowToWorkspace (focus kept), SwitchLayout, ToggleWindowFloating, FullscreenWindow |
| Not reported | minimized, per-window urgency in a snapshot, layout index and names | maximized | maximized, layouts | geometry, fullscreen, maximized |

The window tree walk on sway and i3 finds views (leaf containers with an app_id,
X11 window or window properties) and follows each node's `focus` list to the
focused window.

## Not done

* Minimize: none of the protocols read here carries it (Hyprland's and niri's
  client data have no field; sway's tree has none either), so there is no action.
* niri `FocusedWindow` request: focus comes from the `Windows` reply's `is_focused`.
* Hyprland 0.55 and later: the wiki's dispatcher page now documents only Lua
  `hl.dsp` calls. The string dispatchers used here are the form hyprland-rs
  0.4.0-beta.2 and beta.3 still write; they are unverified on 0.55+.
* Hyprland dispatch `fullscreen` acts on the focused window, so
  `toggle_fullscreen` focuses the window first.
* Hyprland `switchxkblayout` takes the keyboard name from `j/devices`; the `all`
  device name was not verified.
* Hyprland sockets under `$XDG_RUNTIME_DIR/hypr/` only; the older `/tmp/hypr` path
  is not tried.
* Sway `binding`, `mode`, `tick`, `shutdown` and bar events are decoded to names
  and ignored by the model. The model holds the first keyboard that has layouts
  (by identifier); a layout change on any other keyboard is ignored.
* Hyprland `activelayout` names its keyboard; only the main keyboard's name is held,
  so a change on another keyboard is ignored.
* Command sockets: each request waits at most `io::REPLY_TIMEOUT` (2 s) in total for
  its reply and then fails with DISCONNECTED. `connect` and the request `send` have no
  deadline: a compositor that never accepts, or never reads a full socket buffer, can
  still block them (request lines are small, so this needs a compositor that stops
  reading altogether).
* Hyprland `toggle_fullscreen` sends the focus and the `fullscreen 0` dispatch as two
  requests. A focus change between them can toggle a different window. It is not
  serialized.
* An event the model cannot apply in place asks for a snapshot; the caller takes
  it. Applied events allocate into the model's arena, which the next snapshot
  replaces.
* Windows and macOS: not applicable. The library is POSIX-only (`@feat(POSIX)`).

## Verified how

* Golden fixtures, hand-written from the documented formats, in `tests/fixtures/`.
  Unit tests (`src/*_test.c3`, run with `c3c compile-test`): 44 in this library
  (framing, JSON accessors, i3 frames, Hyprland / sway / niri parsers, event
  application, detection, clone, socket deadlines). 71 with the `bleu_rt` tests
  linked in. All pass.
* Live tests, `tests/run_live.sh`: a C3 driver (`tests/live/live.c3`) goes through
  `detect` -> `open` -> `snapshot` -> poller -> `read_events` -> actions against
  Python fakes (`tests/fake_*.py`) that speak each socket protocol and answer from
  the fixtures. It checks 42 output lines and the requests the fakes received,
  including a malformed event line (PROTOCOL) and a niri refusal. All pass on
  Linux x86-64, C3 0.8.5.
* Not run against a real compositor. `hyprctl`, `hyprland`, `swaymsg`, `sway`,
  `i3`, `niri` are not installed in the test environment (checked with
  `command -v`). The fakes implement the documented wire format, not any
  compositor's behaviour.
* `tools/check.sh bleu_core bleu_rt bleu_compositor`: clean on all six targets.
* Framing: the buffer takes partial reads, several lines or frames per read, and
  refuses a unit larger than its capacity (PROTOCOL, never growth). Invalid JSON
  is PROTOCOL. JSON accessors check the value type first.

## Run

    libs/bleu_compositor.c3l/tests/run_live.sh     # needs python3 and c3c
