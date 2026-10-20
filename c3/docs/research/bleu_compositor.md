# Research note: bleu_compositor (Wayland compositor and tiling-WM IPC)

Scope: the workspace, window, output and keyboard-layout parts of
`docs/research/session_windows_input.md`, for Hyprland, sway, i3 and niri.
Sources were read on 2026-10-20 through the agent proxy. Verification tags as in
that spike: **read** (the file or page was fetched and the text checked),
**grep** (fetched, a targeted search), **UNVERIFIED**. Crate versions are the
newest non-yanked on the crates.io index that day, with the version the spike
used noted where it differs.

## 1. What a shell needs

1. Which compositor runs here, and its socket (`detect`).
2. The workspaces (active, focused, urgent, output) and the windows (title, app id,
   pid, workspace, output, focus, floating, fullscreen, urgent, geometry).
3. The outputs and the main keyboard's layouts.
4. Change events for all of the above, without re-reading everything.
5. Focus, close, move to workspace, switch workspace, floating, fullscreen, layout.

## 2. Native routes (Linux)

### Hyprland

* **Sockets.** `$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket.sock`
  (requests) and `.socket2.sock` (events). Wiki IPC page, **read**; hyprland-rs
  0.4.0-beta.2 `src/shared.rs` (`SocketType::Command` = `.socket.sock`,
  `Listener` = `.socket2.sock`), **read**.
* **Requests.** Write `[flag/]command`; `j/` asks for JSON. The connection is
  synchronous: open, write, read to end, close (wiki: an open connection stalls
  Hyprland for five seconds). hyprland-rs `write_to_socket_sync` writes, reads until
  a short read, and never shuts the write side, **read**. The client here reads to
  end-of-stream, which the same server satisfies.
* **Queries used.** `j/clients`, `j/activewindow`, `j/workspaces`, `j/monitors`,
  `j/devices`. Object members from hyprland-rs `src/data/regular.rs` (**read**):
  Client `address`, `at`, `size`, `workspace{id,name}`, `floating`,
  `fullscreen` (FullscreenMode 0 none, 1 maximized, 2 fullscreen, 3 both),
  `monitor` (id), `class`, `title`, `pid`, `focusHistoryID`; Monitor `id`, `name`,
  `width`, `height`, `x`, `y`, `activeWorkspace{id,name}`, `scale`, `focused`;
  Workspace `id`, `name`, `monitor`, `monitorID`, `windows`, `hasfullscreen`;
  Devices `keyboards[]` with `name`, `layout`, `active_keymap`, `main`.
  FullscreenMode values **read** in regular.rs; the C++ source was not reached
  (single-source).
* **Events.** Wiki event table (**read**): `EVENT>>DATA\n`. Field counts from
  hyprland-rs `src/event_listener/shared.rs` (`EVENTS` map, **read**), applied as
  `splitn(count, ",")`, so the last field keeps its commas. This matters for
  `openwindow` (title) and `windowtitlev2`. Counts used: activewindowv2 1,
  activewindow 2, openwindow 4, closewindow 1, windowtitlev2 2, fullscreen 1,
  changefloatingmode 2, urgent 1, movewindowv2 3, activelayout 2, workspacev2 2,
  monitoraddedv2 3, monitorremoved 1 (wiki: monitorremovedv2 3), moveworkspacev2 3,
  createworkspacev2 2, destroyworkspacev2 2, renameworkspace 2, focusedmon 2,
  focusedmonv2 2, activespecial 2, activespecialv2 3 (wiki), configreloaded 0.
  Two sources agree for every count except the three marked wiki-only.
* **Dispatch strings.** hyprland-rs `src/dispatch.rs` (**read**, 0.4.0-beta.2 and
  beta.3, **grep**): separator is a space; `closewindow <sel>`,
  `focuswindow <sel>`, `workspace <id>`, `movetoworkspace <ws>,<sel>`,
  `togglefloating <sel>`, `fullscreen <0|1>` (acts on the focused window); window
  selector `address:0x...`. Sent as `j/dispatch <string>`; reply `ok` on success.
  **Caveat:** the wiki dispatcher page (current, post-0.55) documents only Lua
  `hl.dsp` calls, so these strings are verified for the legacy form only.
* **Keyboard layout.** hyprland-rs `src/ctl.rs` (beta.3, **read**):
  `switchxkblayout <device> next|prev|<id>`. The `all` device value is not in any
  source read: the name of the `main` keyboard is used.

### sway and i3

* **Socket.** `$SWAYSOCK` / `$I3SOCK`, absolute path. Environment only.
* **Framing.** Magic `i3-ipc` (6 bytes), u32 payload length, u32 type, payload.
  Native byte order: swayipc-types 2.0.3 `src/command.rs` encodes with
  `to_ne_bytes` (**read**); swayipc 3.0.3 `src/common.rs` decodes with
  `from_ne_bytes` (**read**); i3 `docs/ipc` says "converted, so they are in native
  byte order" (**read**). Magic: swayipc-types 2.0.3 `src/lib.rs` (`MAGIC`, **read**).
* **Message types.** i3 `docs/ipc` table and swayipc-types 2.0.3 `command.rs`
  (**read**): RUN_COMMAND 0, GET_WORKSPACES 1, SUBSCRIBE 2, GET_OUTPUTS 3,
  GET_TREE 4, GET_VERSION 7, GET_INPUTS 100. Both agree.
* **Event types.** Bit 31 set on events; low bits are the type (i3 `docs/ipc`,
  **read**: workspace 0, output 1, mode 2, window 3, barconfig_update 4,
  binding 5, shutdown 6, tick 7). Types 20 (bar_state_update) and 21 (input) are
  sway-only: swayipc-types 2.0.3 `src/error/event.rs` (**read**). swayipc 3.0.3
  `tests.rs` names `Input` as an event (**grep**).
* **Replies.** swayipc-types 2.0.3 `src/reply.rs` (**read**): `Node` (`id`, `name`,
  `type` = root|output|workspace|con|floating_con|dockarea, `focus[]`, `nodes`,
  `floating_nodes`, `focused`, `urgent`, `app_id`, `pid`, `window`,
  `window_properties{class,...}`, `fullscreen_mode`, `floating`, `rect`);
  `Workspace` (`id`, `name`, `visible`, `focused`, `urgent`, `output`);
  `Output` (`name`, `active`, `focused`, `current_workspace`, `rect`, `scale`);
  `Input` (`identifier`, `type`, `xkb_layout_names`, `xkb_active_layout_index`,
  `xkb_active_layout_name`).
* **Events.** swayipc-types 2.0.3 `reply.rs` (**read**): `WindowEvent{change,
  container}` with changes new, close, focus, title, fullscreen_mode, move,
  floating, urgent, mark; `WorkspaceEvent{change, current, old}` with init, empty,
  focus, move, rename, urgent, reload; `InputEvent{change, input}` with added,
  removed, xkb_keymap, xkb_layout, libinput_config (snake case).
  sway `include/sway/ipc-json.h` and `sway/ipc-server.c` (**grep**/**read**) confirm
  the node layout and the event emitters.
* **Commands.** Checked against sway `master` sources (**grep**): criteria
  `con_id=<n>` (`sway/criteria.c`); `input type:keyboard` identifiers
  (`sway/input/input-manager.c`, `type_wildcard`); `move ... to workspace <name>`
  (`sway/commands/move.c` usage string); `floating toggle` (`floating.c`),
  `kill` (`kill.c`), `fullscreen toggle` (`fullscreen.c`),
  `input ... xkb_switch_layout` (`input.c`, handler table). i3 has no `input`
  command or `GET_INPUTS`.

### niri

* **Socket.** `$NIRI_SOCKET`, absolute path. niri-ipc 26.4.0 `src/socket.rs`
  (**read**): one JSON line out, one line back; `read_events` after `EventStream`.
* **Version.** niri-ipc **26.4.0** is the newest on the index (**read**: the
  crate tarball from static.crates.io). The spike used 25.11.0. A diff of the
  `Event`, `Response` and `Window`/`Workspace` shapes (**read**, both) shows only
  26.4.0's `Cast*` events and `Casts` response added. The implementation ignores
  unknown variants, so it runs on both.
* **Envelope.** `Result<Response, String>` is serialised as `{"Ok": ...}` or
  `{"Err": ...}` (serde default externally tagged, no `serde(rename)` on the enums
  used; `lib.rs` **read**). `Request::Workspaces` is the bare string `"Workspaces"`.
* **Replies.** `Response::Workspaces(Vec<Workspace>)`, `Windows`,
  `Outputs(HashMap<String, Output>)` (a JSON object keyed by name), and
  `KeyboardLayouts{names, current_idx}`. `Window`: `id`, `title`, `app_id`, `pid`,
  `workspace_id`, `is_focused`, `is_floating`, `is_urgent`, `layout` (no absolute
  position). `Workspace`: `id`, `idx`, `name`, `output`, `is_urgent`, `is_active`,
  `is_focused`. `Output`: `name`, `logical{x,y,width,height,scale,transform}` or null.
* **Events.** `Event` enum variants (**read**): WorkspacesChanged,
  WorkspaceUrgencyChanged, WorkspaceActivated{id,focused},
  WorkspaceActiveWindowChanged, WindowsChanged, WindowOpenedOrChanged, WindowClosed,
  WindowFocusChanged{id: Option}, WindowFocusTimestampChanged, WindowUrgencyChanged,
  WindowLayoutsChanged, KeyboardLayoutsChanged, KeyboardLayoutSwitched{idx},
  OverviewOpenedOrClosed, ConfigLoaded, ScreenshotCaptured, CastsChanged,
  CastStartedOrChanged, CastStopped.
* **Actions.** `Action` (**read**): `FocusWindow{id}`, `CloseWindow{id: Option}`,
  `FocusWorkspace{reference}`, `MoveWindowToWorkspace{window_id, reference, focus}`
  (`focus` has no serde default: always sent), `SwitchLayout{layout}`
  (`LayoutSwitchTarget` Next/Prev/Index), `ToggleWindowFloating{id}`,
  `FullscreenWindow{id}`. `WorkspaceReferenceArg`: `Id(u64)`, `Index(u8)`, `Name(String)`.

### Not used

* `ext-foreign-toplevel-list`, `zwlr_foreign_toplevel`, `ext-workspace`: no
  geometry, pid or workspace action in the first two, and no compositor IPC
  coverage in the third (the spike's findings stand; **read** in the spike).
* GNOME Introspect, KDE, X11 EWMH: out of scope for this library.

## 3. Reference implementations

| Project | Version | Read | Used for |
| --- | --- | --- | --- |
| hyprland-rs (crate `hyprland`) | 0.4.0-beta.2 (spike), beta.3 (newest) | beta.2 read; beta.3 `ctl.rs`, `dispatch.rs` grep | socket names, `j/`, dispatch strings, event field counts, `Client`/`Monitor`/`Workspace` members |
| niri-ipc | 26.4.0 (newest), 25.11.0 (spike) | read both | requests, events, actions, reply envelope |
| swayipc-types | 2.0.3 (newest), 1.3.0 (spike) | 2.0.3 read; 1.3.0 by the spike | node, workspace, output, input, event shapes; framing constants |
| swayipc | 3.0.3 | `common.rs` read | framing decode (`from_ne_bytes`) |
| i3 IPC document | `i3/i3` next branch | read | message and event numbering, native byte order |
| sway | `master` | `ipc-json.h`, `ipc-server.c` read; command sources grep | node layout, criteria, command syntax |
| Hyprland wiki | current (0.55+) | IPC page read; dispatcher page read | socket paths, event list |

## 4. Double validation

| Claim | Source 1 | Source 2 | Status |
| --- | --- | --- | --- |
| Hyprland socket names `.socket.sock`, `.socket2.sock` | wiki IPC | hyprland-rs `shared.rs` | 2 sources |
| `EVENT>>DATA\n` line form | wiki IPC | hyprland-rs `event_listener/shared.rs` (`>>`) | 2 sources |
| Event field counts (splitn) | hyprland-rs `EVENTS` map | wiki field lists | 2 sources (monitorremovedv2, activespecialv2: wiki only) |
| Dispatch strings (`focuswindow`, `closewindow`, `workspace`, `movetoworkspace`, `togglefloating`, `fullscreen`) | hyprland-rs beta.2 `dispatch.rs` | hyprland-rs beta.3 `dispatch.rs` | 2 crate versions; legacy form only |
| `switchxkblayout <device> <n>` | hyprland-rs beta.3 `ctl.rs` | none | single source |
| `j/` JSON flag | hyprland-rs `shared.rs` (`CommandFlag::JSON`) | wiki (`[flag]/command`) | 2 sources |
| FullscreenMode bits | hyprland-rs `regular.rs` | none | single source (UNVERIFIED in C++) |
| i3-ipc magic and native order | swayipc-types 2.0.3 | swayipc 3.0.3; i3 docs | 3 sources |
| Message type numbers | i3 docs table | swayipc-types 2.0.3 `command.rs` | 2 sources |
| Event numbers 0-7 with bit 31 | i3 docs | swayipc-types 2.0.3 `error/event.rs` | 2 sources |
| Event numbers 20, 21 | swayipc-types 2.0.3 `error/event.rs` | sway `ipc-server.c` emits `IPC_EVENT_INPUT` (**grep**, number not read) | single source on the number |
| `Node`, `Workspace`, `Output`, `Input` fields | swayipc-types 2.0.3 | sway `ipc-json.h` (functions only) | 1 read + node layout by grep |
| Sway criteria `con_id`, `type:` identifiers | sway `criteria.c`, `input-manager.c` (**grep**) | swayipc-types 2.0.3 (`Input` identifier) | 2 sources |
| niri `Request`, `Response`, `Event`, `Action` names and fields | niri-ipc 26.4.0 `lib.rs` | niri-ipc 25.11.0 `lib.rs` (diff) | 2 versions |
| niri `{"Ok": ...}` envelope | niri-ipc `lib.rs` (`Reply = Result<...>`) | `socket.rs` (`serde_json::from_str::<Reply>`) | 2 sources |
| niri has no minimized, geometry or fullscreen per window | niri-ipc `Window` struct | niri-ipc `WindowLayout` (no absolute position) | 2 sources |

## 5. Model

See `libs/bleu_compositor.c3l/README.md` and `src/model.c3`. Summary: `Kind`,
`Rect`, `Workspace`, `Window`, `Output`, `KeyboardLayouts`, `Model` (plain data;
`Maybe{T}` for values a compositor may not report; ids as text, with the
compositor's own meaning). Events fold into a retained `Model` through
`Backend.apply_event`; the result is `NONE`, `UPDATED` or `REFRESH_NEEDED`.

## 6. Risks and cut lines

* **Dispatch version drift (Hyprland).** The string dispatchers may stop working
  on 0.55+. The model does not depend on them; actions do. Cut: none. Check
  against a real 0.55 instance before shipping.
* **Undocumented per-window state.** Hyprland's snapshot has no urgency; niri has
  no fullscreen or geometry; sway has no maximize. Reported as absent, never zero.
* **Event ordering.** Hyprland and sway can emit an event before a snapshot reply
  is read (sway's i3 document warns of this). The client snapshots after opening
  the event socket and treats every event as applied on top of that snapshot. A
  wrong order is repaired by the next `REFRESH_NEEDED` snapshot.
* **Reply sizes.** Commands read up to 16 MiB; event lines and frames up to 4 MiB.
  Each sway request reserves a 16 MiB receive buffer; a smaller limit
  would be cheaper and is worth measuring on a large tree.
* **Not done** (cut from v1): minimize (no source); niri `FocusedWindow`;
  Hyprland `all` layout device; Hyprland legacy `/tmp/hypr`; sway binding and mode
  events (decoded as names only).
