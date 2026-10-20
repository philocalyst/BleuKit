# Coverage

What has been executed, what has only been type-checked, and what has never been run on
a real system. Written from the libraries' README coverage matrices, checked against the
code and the test runs below. Where a claim comes from a README and was not re-run in
this pass, it says so.

Measured on 2026-10-20 on a Linux x86-64 host (4 cores), c3c 0.8.5_1, Python 3.13,
`dbus-daemon` present. This host has no macOS, no Windows, no Wayland compositor
(no sway, Hyprland or niri binaries), and no NetworkManager, BlueZ, UPower, logind,
PulseAudio, PipeWire, or Secret Service daemon. Those services are exercised only through
the fakes and mocks named below.

## Status words

| Word | Meaning |
| --- | --- |
| **Run** | Executed on the Linux host. The fake, mock or daemon it ran against is named in section 1. |
| **Compiled-only** | Type-checked for the target by `tools/check.sh` or `tools/check-app.sh`. Never executed. |
| **Unsupported** | Not built, or refused at run time with `UNSUPPORTED_*`, `DEGRADED` excluded. |
| **Pure on Linux** | A macOS or Windows capability whose pure logic is unit-tested on the Linux host. The target OS code is not run. |

No library has been executed on macOS or on Windows. Every macOS and Windows entry in
section 1 is either Compiled-only, Unsupported, or Pure on Linux.

## 1. Services by OS and backend

Each cell is the count of capability cells in that service's README coverage matrix,
computed by parsing the tables (`Run`, `Compiled`, `Not done`/`UNSUPPORTED`/`Refused`).
Cells that say "n/a" or "-" are excluded. Cells that mix states, such as
"Pure rule Run; wiring Compiled-only", are counted as "other" and not shown. The counts
are a summary of the README, not a new claim. For Linux the **Run** count includes cells
that run only partly (for example "Run (sway, niri); Hyprland not done").

The "Run against" column names the fake, mock or daemon Linux runs were executed against.

| Service | Linux: Run / Compiled / Unsupported | Linux: run against | macOS: Run / Compiled / Unsupported | Windows: Run / Compiled / Unsupported |
| --- | --- | --- | --- | --- |
| appearance | 15 / 0 / 6 (+1 other) | mock xdg-desktop-portal on a private bus; gsettings with the GNOME schema XML in `tests/schemas` | 0 / 9 / 2 (appkit) | 0 / 6 / 5 (win32) |
| apps | 9 / 4 / 0 | private dbus-daemon with dbus-next activation mock; real `.desktop` fixtures | 0 / 4 / 3 (+1 pure on Linux) (app-bundles) | 0 / 4 / 3 (+1 pure on Linux) (start-menu) |
| audio | 15 / 0 / 1 | Python PulseAudio mock (`pulse_mock.py`); README also reports a real PulseAudio 16.1 and PipeWire 1.0.5 run (not re-run here) | 0 / 8 / 8 (coreaudio) | 0 / 10 / 6 (wasapi) |
| battery | 21 / 1 / 3 (+1 other) | UPower mock on a private bus; fake sysfs tree | 0 / 10 / 2 (+1 pure on Linux) (IOKit) | 0 / 8 / 4 (+1 pure on Linux) (win32) |
| bluetooth | 16 / 4 / 0 | BlueZ mock (`mock_bluez.py`) on a private bus; fake rfkill tree | 0 / 4 / 16 (iobluetooth) | 0 / 3 / 17 (win32) |
| brightness | 8 / 0 / 2 (+1 other) | fake sysfs/DRM tree; `bleu::ddc::mock`; logind stand-in | 0 / 4 / 4 (+1 other) (DisplayServices is private) | 0 / 5 / 3 (+1 other) (dxva2, `\\.\LCD`) |
| capi | not in matrix (see section 2) | `tools/capi/tests/run.sh`: C, C++ and ctypes against fake sysfs; valgrind | not run | not run |
| clipboard | 7 / 1 / 0 (+1 other) | in-process mock Wayland compositor | 0 / 7 / 1 (+1 other) (pasteboard) | 0 / 6 / 2 (+1 other) (win32) |
| color | 8 / 1 / 3 | in-process mock wlr compositor (gamma ramps read back) | 0 / 5 / 2 (+3 pure on Linux) (CoreGraphics) | 0 / 5 / 2 (+3 pure on Linux) (win32) |
| display | 9 / 7 / 11 (+3 other) | scripted in-process `MockServer` of `bleu::wl::testing`, run from `src/linux_test.c3` (wlr-output-management and read-only route) | 0 / 9 / 2 (+2 other) (CoreGraphics) | 0 / 6 / 4 (+3 other) (display configuration) |
| hotkey | 10 / 1 / 1 | mock xdg-desktop-portal GlobalShortcuts on a private session bus | 0 / 4 / 5 (+2 pure on Linux) (carbon) | 0 / 4 / 5 (+2 pure on Linux) (win32) |
| input | 6 / 0 / 2 | fake compositors (sway, niri, Hyprland fixtures); mock `org.freedesktop.locale1` on a private system bus | 0 / 4 / 0 (TIS) | 0 / 4 / 0 (win32) |
| media | 12 / 7 / 3 | mock MPRIS players (`mock_players.py`) on a private bus | 0 / 17 / 5 (scripting) | 0 / 17 / 5 (SMTC) |
| network | 17 / 0 / 1 | NetworkManager mock (`nm_mock.py`) on a private system bus; fake sysfs | 0 / 11 / 7 (CoreWLAN) | 0 / 11 / 7 (WLAN API) |
| notify | 5 / 0 / 2 | live freedesktop server test against python-dbus-next on a private session bus | 0 / 1 / 5 (+1 other) (UNUserNotificationCenter) | 0 / 0 / 7 (toast) |
| power | 11 / 6 / 4 | logind and power-profiles-daemon mocks on a private system bus; bus restart tested | 0 / 6 / 14 (IOKit) | 0 / 8 / 12 (win32) |
| secrets | 9 / 1 / 0 | Secret Service mock (`secret_service_mock.py`, six modes) on a private session bus | 0 / 3 / 6 (+1 other) (Keychain) | 0 / 3 / 6 (+1 other) (Credential Manager) |
| session | 11 / 0 / 2 | logind mock on a private system bus | 0 / 4 / 5 (IOKit) | 0 / 4 / 5 (win32) |
| sysinfo | 15 / 0 / 0 | fake `/proc` and `/sys` root, and the real `/proc` of the host (live) | 0 / 12 / 3 (mach) | 0 / 11 / 4 (win32) |
| tray | 14 / 3 / 3 (+1 other) | fake StatusNotifierWatcher and item on a private session bus | 0 / 2 / 4 (+1 other) (appkit) | 0 / 4 / 4 (win32) |
| windows | 11 / 0 / 1 | the fake compositors of `bleu_compositor` (`libs/bleu_compositor.c3l/tests`: Hyprland, sway, i3, niri) through `tests/live/service_live.c3` | 0 / 6 / 5 (macos) | 0 / 7 / 4 (win32) |

Linux-only compositor and infrastructure libraries (no README matrix):

| Library | Linux | macOS | Windows |
| --- | --- | --- | --- |
| compositor (Hyprland, sway, i3, niri IPC) | Run: 44 own unit tests (113 in the binary); `tests/run_live.sh` against the fake compositors (`fake_hyprland.py`, `fake_sway.py`, `fake_niri.py`, `fake_common.py`) | Compiled-only (check.sh); the sources are POSIX-gated, so no macOS-specific code | Compiled-only (check.sh); POSIX-gated sources are excluded on Windows |
| ipc (DMS line-JSON server and client) | Run: 36 unit tests, `tests/run.sh` raw-socket checks against an in-process server | Compiled-only (check.sh) | Compiled-only (check.sh); POSIX-only sources |
| dbus (client, server, marshalling) | Run: 92 unit tests (`tests/unit/`), `tests/integration.sh` against dbus-daemon and a dbus-next mock | Compiled-only | Compiled-only |
| wl (Wayland client, generated protocols) | Run: 21 unit tests (`client_test`, `wire_test`, `mock_server_test`); no live compositor | not applicable | not applicable |
| json, plist, xdg, ddc, dl, rt, core, objc, win, service | Run: unit tests only (counts in section 2) | Compiled-only; objc and the Apple parts of plist and xdg are compiled, not run | Compiled-only; `bleu_win` COM and WinRT wrappers are compiled, not run |
| registry (service table, `bleud`'s dispatch) | Run only through `apps/bleud/tests/run.sh` (see the apps) | Compiled-only | Compiled-only |

### Apps

| App | Linux | macOS | Windows |
| --- | --- | --- | --- |
| bleud (daemon) | Run: `apps/bleud/tests/check_bleud.py`: handshake, battery on a fake sysfs tree, `brightness.set`, network state and capabilities, sysinfo on the real `/proc`, concurrent clients, a client that disconnects mid-request | Compiled-only (`tools/check-app.sh`) | Compiled-only (`tools/check-app.sh`) |
| bleuctl (client) | Run as the client of the bleud test above | Compiled-only | Compiled-only |
| dmsd (DMS `core` server) | Run: `apps/dmsd/tests/run.sh` (section 1b) | Compiled-only (`tools/check-apps.sh`); not run | Skipped: POSIX-only |

### 1b. dmsd modules

Status from `docs/DMSD.md` ("Status at a glance"), checked against the test scripts that
`apps/dmsd/tests/run.sh` calls:

| Part | Status | Test that runs it |
| --- | --- | --- |
| Socket, handshake, framing, `ping`, `subscribe`, `unsubscribe`, `getServerInfo`, `shell.ready` | done | `check_dms.py` |
| `brightness` (6 methods, 2 topics) | done | `check_dms.py`, fake sysfs |
| `loginctl` (11 methods, 1 topic; 4 not supported) | done | `check_dms.py`, logind mock |
| `bluetooth` (15 methods, 2 topics) | done | `bluetooth.sh`, BlueZ mock of `bleu_bluetooth` |
| `network` (13 methods, 2 topics; 32 not supported) | done | `network.sh`, NetworkManager mock of `bleu_network` |
| `dgop` (partial) | done | `modules.sh`, against the host `/proc` |
| `apps` (`apppicker`, `browser`, `mime`) | done, partial | `modules.sh` |
| `evdev` | refused | `modules.sh` |
| `clipboard` (12 methods, 1 topic) | done, compiled only | `modules.sh` checks its absence only: no Wayland compositor here |
| `wlroutput`, `gamma`, `theme.auto`/`matugen`, `freedesktop` | done | `desktop.sh`, fake wlr compositor and mock portal |
| Refused modules (cups, tailscale, ...) | not supported | `check_dms.py` |
| `location`, `dbus`, `notify` | not started | none |

## 2. test-all results

Final run of `tools/test-all.sh` (all groups), exit status 0:

```
items 63: PASS 62, FAIL 0, TIMEOUT 0, NO-TESTS 1
```

| Status | Item | Detail |
| --- | --- | --- |
| PASS | unit:bleu_appearance | own 14 pass / 0 fail; binary 132 pass / 0 fail |
| PASS | unit:bleu_apps | own 23 pass; binary 253 pass |
| PASS | unit:bleu_audio | own 36 pass; binary 154 pass |
| PASS | unit:bleu_battery | own 31 pass; binary 149 pass |
| PASS | unit:bleu_bluetooth | own 8 pass; binary 136 pass |
| PASS | unit:bleu_brightness | own 40 pass; binary 204 pass |
| PASS | unit:bleu_capi | own 4 pass; binary 324 pass |
| PASS | unit:bleu_clipboard | own 29 pass; binary 168 pass |
| PASS | unit:bleu_color | own 26 pass; binary 123 pass |
| PASS | unit:bleu_compositor | own 44 pass; binary 113 pass |
| PASS | unit:bleu_core | own 34 pass; binary 34 pass |
| PASS | unit:bleu_dbus | own 92 pass; binary 126 pass |
| PASS | unit:bleu_ddc | own 78 pass; binary 112 pass |
| PASS | unit:bleu_display | own 31 pass; binary 248 pass |
| PASS | unit:bleu_dl | own 10 pass; binary 44 pass |
| PASS | unit:bleu_hotkey | own 18 pass; binary 133 pass |
| PASS | unit:bleu_input | own 13 pass; binary 175 pass |
| PASS | unit:bleu_ipc | own 36 pass; binary 105 pass |
| PASS | unit:bleu_json | own 43 pass; binary 77 pass |
| PASS | unit:bleu_media | own 28 pass; binary 146 pass |
| PASS | unit:bleu_network | own 43 pass; binary 161 pass |
| PASS | unit:bleu_notify | own 68 pass; binary 157 pass |
| PASS | unit:bleu_objc | own 13 pass; binary 47 pass |
| PASS | unit:bleu_plist | own 48 pass; binary 82 pass |
| PASS | unit:bleu_power | own 6 pass; binary 124 pass |
| NO-TESTS | unit:bleu_registry | no `@test` in its sources; binary 932 pass (dependencies' tests) |
| PASS | unit:bleu_rt | own 35 pass; binary 69 pass |
| PASS | unit:bleu_secrets | own 29 pass; binary 147 pass |
| PASS | unit:bleu_service | own 7 pass; binary 76 pass |
| PASS | unit:bleu_session | own 7 pass; binary 135 pass |
| PASS | unit:bleu_sysinfo | own 36 pass; binary 141 pass |
| PASS | unit:bleu_tray | own 8 pass; binary 126 pass |
| PASS | unit:bleu_win | own 29 pass; binary 63 pass |
| PASS | unit:bleu_windows | own 12 pass; binary 184 pass |
| PASS | unit:bleu_wl | own 21 pass; binary 90 pass |
| PASS | unit:bleu_xdg | own 64 pass; binary 98 pass |
| PASS | live:appearance | `tests/run.sh` |
| PASS | live:apps | `tests/run.sh` |
| PASS | live:audio | `tests/run.sh` |
| PASS | live:battery | `tests/run.sh` |
| PASS | live:bluetooth | `tests/run.sh` |
| PASS | live:brightness | `tests/run.sh` |
| PASS | live:hotkey | `tests/run.sh` |
| PASS | live:ipc | `tests/run.sh` |
| PASS | live:media | `tests/run.sh` |
| PASS | live:network | `tests/run.sh` |
| PASS | live:notify | `tests/run.sh` (49 of 49 checks) |
| PASS | live:power | `tests/run.sh` |
| PASS | live:secrets | `tests/run.sh` (six modes) |
| PASS | live:session | `tests/run.sh` |
| PASS | live:tray | `tests/run.sh` |
| PASS | live:windows | `tests/run.sh` |
| PASS | live:compositor-run_live | `tests/run_live.sh` (not named `run.sh`; included on purpose) |
| PASS | live:dbus-integration | `tests/integration.sh` (not named `run.sh`) |
| PASS | live:input-run_compositor | `tests/run_compositor.sh` |
| PASS | live:input-run_locale1 | `tests/run_locale1.sh` |
| PASS | live:app-bleud | `apps/bleud/tests/run.sh` |
| PASS | live:app-dmsd | `apps/dmsd/tests/run.sh` |
| PASS | live:capi | `tools/capi/build.sh --check`, build, `tools/capi/tests/run.sh` |
| PASS | check:libs | `tools/check.sh`: 36 libraries, 6 of 6 targets |
| PASS | check:bleuctl | `tools/check-app.sh`: 6 of 6 targets |
| PASS | check:bleud | `tools/check-app.sh`: 6 of 6 targets |
| PASS | check:dmsd | `tools/check-apps.sh`: 4 of 6 targets; Windows skipped (POSIX-only) |

"own" counts only the tests whose module belongs to the library. "binary" is every test
in the compile-test binary, which also links the library's dependencies, so a
dependency's failing test fails the item and shows in the binary count.

### Run history of this pass

| Run | Result | Why it changed |
| --- | --- | --- |
| unit group, first | 34 PASS, 1 FAIL (`bleu_wl`), 1 NO-TESTS | `bleu_wl` harness globbed `src/*.c3`; its protocol bindings are in `src/proto/` (fixed) |
| live group, first | 22 PASS, 1 FAIL (`secrets`) | shared venv had no `cryptography`; the mock could not start (fixed in the runner) |
| check group, first | 2 FAIL (`bleuctl`, `bleud`) | `check-apps.sh` reads `project.json`; these apps have `manifest.json` (runner now uses `check-app.sh`) |
| final | 62 PASS, 0 FAIL, 0 TIMEOUT, 1 NO-TESTS | all items above |

## 3. Known failures

None open in the final run. Causes found and fixed in this pass:

* `bleu_rt` `timers_test::timers_fire_in_due_order`: a test defect, not a timer defect. The
  three `schedule` calls take more than the 1 ms gap between the due times under valgrind,
  so timer 1 (scheduled first, due 3 ms out) fired before timer 3 (scheduled later, due 2 ms
  out). The failing assertion's leak (384 bytes) came only from that failing run: the test
  framework stops the test before `defer queue.free()`. The gaps are now 10, 60 and 110 ms
  with a 200 ms sleep. Verified: 69/69 normal, and valgrind clean (no errors, no leak) in
  three runs.
* `bleu_wl` unit compile: harness only (see the run history).
* `bleu_secrets` live: harness only (see the run history).

Leads from older review notes that do not reproduce today:

* `bleu_notify` "the centre quits cleanly": passes (49 of 49), three runs in a row.
* `bleu_compositor` `sway_test` `input_layout_events_update_the_layout`: passes (113 of 113
  in the compositor binary).
* "One stalled unfiltered compile-test": not reproduced. Every unit compile-test ran to
  completion in under two minutes, and `test-all.sh` bounds each with `timeout`. The
  candidate in the notes is unknown; treat it as open.

## 4. Known gaps

### Capabilities not done (from the READMEs' matrices)

These are the cells marked "Not done", "Unsupported" or "Refused" that matter most for a shell:

* **bluetooth**: macOS (IOBluetooth) and Windows (Win32) have no working capabilities
  beyond the compiled ones; no macOS power or discovery; no Windows radio control.
* **audio**: `PEAK_METER` on all three OS; `PORT` and `CARD_PROFILE` on macOS and Windows;
  `DEFAULT_SET` and `STREAM_MOVE` on Windows (undocumented `IPolicyConfig`).
* **display**: mirror, HDR, colour depth, adaptive sync and persistent change refused on Linux;
  Linux read-only path refuses every apply.
* **hotkey**: `CONFLICT` not reported on Linux (the portal does not report clashes);
  `RELEASED` not available on Windows.
* **session**: `IDLE_WATCH` unsupported on Linux (logind has no idle source, and
  `bleu_wl`'s ext-idle-notify bindings have no backend yet); `UNLOCK` and `SESSION_LIST`
  not done on macOS and Windows.
* **power**: all of macOS and Windows except keep-awake and power events are static
  or unsupported; keep-awake display is unsupported on Linux.
* **notify**: the notification centre is Linux-only (no public macOS or Windows centre API);
  `ActivationToken` is never emitted; closing a sent notification is not available.
* **media**: `BACKEND_FAILED` on Linux (the bus loss is not reported); no `SEEKED` on Windows
  or macOS; publishing our own session is not available on any OS.
* **tray**: NewMenu (KDE) ignored; menu icon-data (PNG) not decoded; XEmbed (X11) cut.
* **windows**: switch workspace and move window on Windows; minimize on Linux; outputs on
  Windows and macOS are empty.
* **color**: Night Shift, the Windows night-light blob and ICC are not done; output hotplug
  does not re-apply the ramp; a real wlroots compositor was not run.
* **clipboard**: `PRIMARY_SELECTION` compiled but no test exercises it; `WRITE_TYPES` on
  Windows is text only.
* **appearance**: `WALLPAPER_PER_SCREEN` not done; accent, contrast and reduced transparency
  not done on several backends.
* **battery**: temperature on macOS and Windows not done; peripherals on sysfs not done.
* **network**: signal in dBm not available on Linux (NetworkManager gives 0-100 only);
  Wi-Fi forget and autoconnect not done on macOS; passphrase prompt not available on macOS
  or Windows (the password is supplied up front).

### dmsd

From `docs/DMSD.md`: `location`, `dbus` (generic D-Bus proxy, out of scope for the shell)
and `notify` (`watchAction`, `send`) are not started, and their methods answer
`unknown method`. `browser`'s frames cannot be served as DMS names them, because
`bleu_ipc` labels each frame with its topic's name (`DMSD.md`, Found in the libraries).
The shell itself is not run: the unmodified DMS QML shell has never been connected to
dmsd in this environment.

### Library findings recorded in DMSD.md and the reviews (not re-verified here)

* `bleu_network`: `set_autoconnect` and `forget` do not republish state until the next
  poll (5 s); `forget`, `set_autoconnect` and `supply_credentials` complete with excuses
  that carry no message.
* `bleu_ipc`: frame naming (above).
* `bleu_input`: no caps-lock state.
* `bleu_xdg`: no shared-mime-info glob table, no `mimeinfo.cache` reader, no `mimeapps.list`
  writer.
* `bleu_sysinfo`: no cumulative network or disk counters, no GPU, no hardware inventory.
* `bleu_clipboard` `open`: its failure reason is not kept in the error state, so
  `failure_text` can return a stale message (DMSD.md).
* `bleu_dbus`: `marshal.decode` allocates a string in `Proxy.get_all_properties`, reported by
  DMSD.md as 6 bytes leaked under ASan after `bleu_power` is closed. Not re-run here.
* `bleu_bluetooth`: `open` returns bare excuses with no detail; the object path, `Icon`,
  `LegacyPairing` and the `AuthorizeService` UUID are not exposed.
* `bleu_color`: a multi-display command reports the first refusal and keeps the other
  writes; a neutral temperature clears the `refused` flag without a write.
* `bleu_display`: an unchanged layout completes without asking the compositor, so a test
  of an unchanged layout proves nothing about the compositor.
* `bleu_bluetooth_secrets` review: "the rest of the Suspicions list" was not run.

### Not covered by test-all

* `libs/bleu_json/test/*.py`, `check_refusals.sh` and `fuzz_main.c3`: no runner exists.
* `libs/bleu_registry`: no `@test` functions; exercised only through `bleud`'s test.
* `apps/bleuctl`: no tests of its own.
* The `bleu_power` `tests/integration/main.c3` and `bleu_session` `tests/*.c3` are run by
  their `run.sh`, not by the unit group.
* Live tests are not run against any real daemon, compositor or device (section 5).

## 5. Never run on real hardware or a real system

* **macOS**: no macOS host has been available. Nothing has been executed on macOS: every
  `macos-*` target in `tools/check.sh` and `tools/check-app.sh` is type-checking only.
  Every macOS backend (`bleu_objc`, the IOKit, CoreAudio, CoreWLAN, Carbon, appkit,
  scripting, pasteboard, SMC and TIS code) is therefore unexecuted, and each entry in
  section 1 is Compiled-only, Unsupported or Pure on Linux.
* **Windows**: no Windows host has been available. Nothing has been executed on Windows.
  COM, WinRT, WASAPI, SMTC, the WLAN API, the Credential Manager, the registry, the
  window-message loops and the Win32 display code are type-checked only.
* **Real services on Linux**: no test ran against a real NetworkManager, BlueZ, UPower,
  logind, power-profiles-daemon, xdg-desktop-portal, Secret Service, freedesktop
  notification daemon, StatusNotifierWatcher, or MPRIS player. Every such test used a
  Python mock on a private bus, except the sysinfo test, which read the host's `/proc`.
  The audio README reports runs against a real PulseAudio 16.1 and PipeWire 1.0.5, but
  those were not re-run in this pass.
* **Compositors**: no real Hyprland, sway, i3, niri, or wlroots compositor has run.
  Display, colour, clipboard, wlroutput, gamma, windows and input were exercised only by
  the fake compositors listed in section 1.
* **Hardware**: no real display (DDC or EDID), battery, Bluetooth radio, Wi-Fi card,
  audio device, keyboard layout, sensor, or backlight was used. Brightness and battery ran
  on fake sysfs trees; DDC ran on `bleu::ddc::mock`.
* **DMS shell**: the unmodified DMS QML shell has not been connected to dmsd.

## How to reproduce

    tools/test-all.sh                  everything (not timed; the unit group alone took about 2 minutes)
    tools/test-all.sh unit bleu_rt     one library's unit tests
    tools/test-all.sh live             the live scripts only
    tools/test-all.sh check            the type-checks only
    KEEP_LOGS=1 tools/test-all.sh      keep every log under the printed work directory

The runner needs `timeout`, `c3c`, `python3` (with pip access to PyPI for `dbus-next` and
`cryptography`, unless `BLEU_*_PYTHON` names a suitable interpreter), `dbus-daemon`, `gcc`,
`g++`, and `valgrind` (for the C ABI leak check; skipped without it).
