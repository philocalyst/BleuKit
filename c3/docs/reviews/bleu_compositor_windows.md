# Review of bleu_compositor and bleu_windows

Verdict (original): the socket framing, the hostile-JSON handling, the id checks, the Alt-Tab predicate and the Win32/COM bindings hold up on the paths read. The six-target check and both live suites were clean.
Two defects mattered most: sway and i3 snapshots marked every tiled window as floating (a fixture hid it), and any worker that exited early left queued actions uncompleted with the mailbox still open, so waiters hung.
Incremental updates left output state stale, the reconnect timer restarted on every wake-up, and blocking command sockets had no timeout, so a silent compositor could hang the worker and `close()`.

Status after this round: every CRITICAL, HIGH, MEDIUM and LOW finding below is FIXED, or WONTFIX with the reason given. The Linux fixes are run (compile-tests and both live suites). The macOS and Windows fixes are compiled for their targets by `tools/check.sh` but not executed: no host here.

Evidence key: **RUN** = reproduced by a scratch program or an existing test run; **PATH** = precise code path, not executed (no Windows or macOS host here, and the failure cannot be injected on Linux). **Pre-fix** = the regression test run against the starting commit `d46464e` (its sources, the new test and fixture).

## Findings

| ID | Severity | Status | Where (original) | Defect | Resolution | Regression test and pre-fix result |
| --- | --- | --- | --- | --- | --- | --- |
| C-1 | HIGH | FIXED | `sway.c3` (was :220); `tests/fixtures/sway/tree.json` | Sway and i3 report every tiled window as floating. `wire::present(node, "floating")` is true for any value, and sway writes `"floating":"auto_off"` on tiled containers. The fixture had `null`, which hid it. | `is_floating` reads the value: `floating_con`, or `auto_on`/`user_on`. Fixture now uses sway's real `auto_off`. The `window` `floating` event uses the same rule. i3 is taken to share sway's values; i3's own source was not read (S-6). | `tree_walk_finds_views_and_the_focus_path` (tiled windows must not float) and `a_floating_event_reads_the_floating_field`: both fail on the pre-fix code. |
| C-2 | MEDIUM | FIXED | `hyprland.c3` `layout_changed`; `sway.c3` `input_event`; `model.c3` | `activelayout` updated the layout name for any keyboard. | `KeyboardLayouts.keyboard` holds the main keyboard's name (Hyprland) or the held keyboard's identifier (sway). Only an event for that keyboard applies; other keyboards are ignored. A payload without a name asks for a snapshot. | `only_the_main_keyboard_layout_is_followed` (Hyprland) and the sway `input_layout_events_update_the_layout` extension: fail on the pre-fix code (the field itself is new, and the behaviour check fails). |
| C-3 | MEDIUM | FIXED | `sway.c3` `workspace_event`; `niri.c3` `workspace_activated`, `workspaces_changed`; `model.c3` `Model.sync_outputs` | Workspace focus and `WorkspacesChanged` left `outputs[*].active_workspace` and `focused` stale. | `Model.sync_outputs` recomputes both from the workspaces; sway and niri call it after the workspace event. | `a_workspace_focus_moves_the_shown_workspace_and_output` (sway) and `a_workspace_activation_moves_the_shown_workspace_of_its_output` (niri): both fail on the pre-fix code. |
| C-4 | MEDIUM | FIXED | `io.c3` (`await_readable`, `read_to_end`, `await_line`, `await_frame`); the three `*_io.c3` call sites | Command sockets blocked with no timeout, so a silent compositor held the worker and `close()`. | Every command read first waits in `poll(2)` for the rest of a 2 s total budget (`REPLY_TIMEOUT`). A timeout is DISCONNECTED, so the connection is dropped and the worker goes on. | `io_test.c3`: `a_silent_peer_fails_the_read_within_the_timeout` and `..._a_line_read_...`. Pre-fix: `read_to_end(socket)` on a silent socket pair blocks for ever (the test binary was still blocked after 20 s). Residual: `connect` and `send` have no deadline (README). |
| W-1 | HIGH | FIXED | `service.c3` `Windows.open` (no `abandon`); the `run` loops (`linux_compositor.c3`, `win32_enum.c3`, `macos_workspace.c3`) | Early exits left queued Operations uncompleted with the mailbox open, so waiters hung. | `Windows.open` passes `cancel_command` as the hub's `abandon`, so the hub answers every command still queued when `run` returns (`CANCELLED`). The per-run `fail_queued` drains are gone; every batch is processed before any return, so nothing is dequeued and dropped. | `abandon_test.c3`: `a_command_queued_when_the_worker_returns_is_cancelled`. Pre-fix (the same test with `abandon` omitted, which is what `Windows.open` did): the wait times out, so the test fails. |
| W-2 | MEDIUM | FIXED | `linux_compositor.c3` `run`, `Link` | The reconnect timer restarted on every wake-up, so a steady stream of commands shorter than the retry wait starved reconnection. | `Link.retry_at` is an absolute `deadline`, set when a connection is lost or an attempt fails. Wake-ups do not move it; the attempt runs when it has passed. | Live `service_live.c3` storm (new): a command every 100 ms while the compositor is down; the return must come during it (`storm=reconnected`). Pre-fix: `storm=starved` and `FAIL recon-storm`. |
| W-3 | MEDIUM | FIXED (compiled, not run) | `macos_workspace.c3` `close_window`, `minimize`, `focus` | Close and minimize acted on the application's focused window; the target number only chose the PID. | `named_focused_window` refuses unless the target is the frontmost application's topmost window (the rule `fill_state` uses), with `UNSUPPORTED`. Focus raises only the topmost window, else activates the app and fails with `UNSUPPORTED`. Capability notes say so. The AX-by-number lookup was not used: it needs a private symbol that is not verified. | PATH only. `tools/check.sh` compiles it for both macOS targets. |
| C-5 | LOW | FIXED | `hyprland.c3` `fullscreen_changed`, `floating_changed` | A missing or unknown flag applied `false` and returned UPDATED. | Flags must be `0` or `1`; otherwise the event asks for a snapshot. | `payloads_without_their_fields_ask_for_a_snapshot`: fails on the pre-fix code. |
| C-6 | LOW | FIXED (docs) | `hyprland_io.c3` `open` doc; README moves row | `open()` said it checked the command socket; it did not. The README said a move onto an unfocused workspace requested a snapshot. | Doc corrected in code and README. | Doc-only; no test. |
| C-7 | LOW | FIXED | `sway.c3` `fullscreen_of`, `window_event`; `niri.c3` `build_layouts`; `hyprland.c3` `workspaces`, `mode_bit` | Missing values became `false` / `0` with `has_value` set; an out-of-range niri layout index was passed through. | Missing `fullscreen_mode`, `fullscreen` and workspace `id` stay absent (a fullscreen event without a mode asks for a snapshot). A niri index outside the list is absent. | `unknown_is_not_zero_in_hyprland_replies`, `an_out_of_range_layout_index_names_no_layout`, `a_fullscreen_event_without_a_mode_asks_for_a_snapshot`: all fail on the pre-fix code. |
| C-8 | LOW | FIXED | `wire.c3` `Buffer.take_line`, `scanned` offset | `take_line` rescanned from the start, so a dribbled line cost O(n²). | The buffer remembers how far it scanned; compaction moves the offset. | `a_line_split_over_several_feeds_is_found_when_it_completes`: a correctness guard. It passes on the pre-fix code as well, because the defect is cost, not a wrong answer. |
| C-9 | LOW | FIXED (docs) | `hyprland_io.c3` `toggle_fullscreen` doc; README "Not done" | Focus and `fullscreen 0` are two requests; a focus change between them toggles another window. | WONTFIX for the code, documented in code and README: a fix needs a Hyprland dispatch that toggles fullscreen for a named window, and none is verified here. | Doc-only. |
| W-4 | LOW | FIXED | `service.c3` `Windows.close` path | A post accepted between the worker's last take and the close could be discarded by `Mailbox.free`. | The hub closes the mailbox and drains it after `run` returns, so every accepted command is answered; a post after the close is refused. | Covered by `a_command_queued_when_the_worker_returns_is_cancelled` (the drain path). |
| W-5 | LOW | FIXED | `service.c3` `close` doc | The doc said DISCONNECTED; the code cancels with CANCELLED. | Doc says CANCELLED. | Doc-only. |
| W-6 | LOW (latent) | FIXED | `service.c3` `Windows.open` | `self` leaked when `driver.create` failed. | Freed on that path. | Not testable: no `create` fails today. Compiled. |
| W-7 | LOW | FIXED | `driver.c3` `select_driver` | A forced backend listed here whose probe failed reported UNSUPPORTED. | UNAVAILABLE for a listed backend that does not work now; UNSUPPORTED only when it is not listed on this platform. | `a_forced_backend_whose_probe_fails_is_unavailable` (runs when the probe fails, as in this sandbox): fails on the pre-fix code. |
| W-8 | LOW | FIXED (compiled, not run) | `win32_enum.c3` `minimize`; `win32_user.c3` `is_window` | `ShowWindow` reports the old visibility, so a stale HWND looked minimized. | `IsWindow` first; a closed window is `NOT_FOUND`. | PATH. Compiled for both Windows targets. |
| W-9 | LOW | FIXED (compiled, not run) | `macos_spaces_private.c3` `open_skylight` | A library handle leaked when `dl::bind` failed. | Closed on that path. | PATH. Compiled for both macOS targets. |
| W-10 | LOW | FIXED (compiled, not run) | `macos_workspace.c3` `spaces_of` | `active_space` was called twice; a failed second call invented id `"0"`. | One read; a failure gives no workspace. | PATH. Compiled. |
| W-11 | LOW (latent) | FIXED | `model.c3` `Connection` | A zeroed `State` read CONNECTED. | DISCONNECTED is the first (zero) value. | `a_zeroed_state_is_disconnected`: fails on the pre-fix code. |

## Suspicions (unproven, not findings; not addressed in this round)

* **S-1** `IVirtualDesktopManager::MoveWindowToDesktop` may only work on windows the calling process owns. Not checked (no Microsoft Remarks section fetched).
* **S-2** `Windows.close()` frees the service while another thread may still be inside `send_request`. Still open: the header says "any thread".
* **S-3** macOS observer reads the module global `active_hub` from the notification thread. Still open: needs `bleu_objc` `notify::BlockSubscription.close` semantics.
* **S-4** sway command lists split on `;` and `,`. Still open: `argsep` quote handling not confirmed.
* **S-5** niri `WindowOpenedOrChanged` with `is_focused` does not clear the previous focus flag. Still open: niri event order not checked.
* **S-6** i3 was not checked against its own source (C-1 relies on the shared values, see above).
* **S-7** Linux `Link.act` maps a connect failure to a non-DISCONNECTED error. Still open.
* **S-8** The Windows backend uses MTA for `IVirtualDesktopManager`. Still open.

## What is good (original review, unchanged)

* **Framing:** `wire.Buffer` refuses a unit over capacity with PROTOCOL and never grows. `take_line` and `peek_exact` handle partial reads and several units per read. `i3ipc.take_frame` checks the length before it waits for the payload. The magic is checked.
* **Hostile JSON:** the std parser caps nesting at 64. Every read goes through a type-checked accessor. Replies are capped at 16 MiB and event lines at 4 MiB.
* **Id injection:** `is_token`, `is_decimal` and `is_quotable` are checked before each command is built.
* **Incremental apply:** the event socket is subscribed before the snapshot, and events are replayed on top of it.
* **Connection lifecycle:** `drop` removes the poller source before closing the client. Backoff doubles on each failure and resets on success.
* **Operations on the normal path:** every backend's `run_command` completes and releases on all three paths.
* **Alt-Tab predicate:** matches the cited Raymond Chen algorithm. Its rules are pure and tested.
* **WinEvent hook:** the callback filters and posts REFRESH only. `active_hub` is cleared before `UnhookWinEvent`.
* **Win32 bindings:** the constants and the `IVirtualDesktopManager` vtable match the cited values.
* **macOS private gate:** `allow_private` defaults to false; SkyLight is bound at run time.
* **Mailbox:** `close` happens under the lock, so a post after close is refused.

## Tests run and results

Verification tree: the starting commit `d46464e` for every library except `bleu_compositor.c3l` and `bleu_windows.c3l`, which are this round's working tree. The working tree itself was not usable as a whole: other engineers' edits to `bleu_core`, `bleu_rt` and `bleu_service` were mid-change (e.g. `error::raise_text`, `observe.c3` syntax) at the time of the run.

* `c3c compile-test` bleu_compositor (with its dependencies): 71 passed, 0 failed (was 59; 12 new tests).
* `c3c compile-test` bleu_windows (with its dependencies): 124 passed, 0 failed (was 109 at the start; 3 new tests, plus the compositor tests now linked in).
* `libs/bleu_compositor.c3l/tests/run_live.sh`: "live: all checks passed", 42 output checks.
* `libs/bleu_windows.c3l/tests/run.sh`: "windows live: all checks passed", 37 output checks (one new: the reconnect storm).
* Pre-fix runs (starting commit, new tests): 10 compositor tests fail (sway 5, Hyprland 3, niri 2); the windows abandon, driver, model and storm checks fail; the silent-peer read blocks.
* `tools/check.sh bleu_core bleu_rt bleu_service bleu_compositor bleu_win bleu_objc bleu_dl bleu_windows`: see the final line of this section.
* Not run: all Windows and macOS code (no host here). W-3, W-8, W-9 and W-10 are compiled only.
* `c3fmt`: applied to every touched file, and checked with `--check`.
