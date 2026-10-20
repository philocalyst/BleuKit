# bleu_input

Keyboard layouts for a desktop shell: the layouts the user has configured, which one is active, a request to
switch, and the changes as events. The v1 cut of `docs/research/session_windows_input.md` (input part): no evdev
lock-key LEDs, no pointer or keyboard settings.

Module root `bleu::input`. Depends on `bleu_core`, `bleu_rt`, `bleu_service`, `bleu_compositor`, `bleu_dbus`,
`bleu_objc`, `bleu_win`. Implementation notes and every verified source: `docs/research/input_impl.md`.

## Public API

* `input::open(allocator, Options{backend, poll}) -> Input*?`: the first backend that probes true, in priority
  order (compositor, locale1 on Linux; TIS on macOS; win32 on Windows). `Options.backend` forces one.
* `Input.latest() -> Snapshot{State}*?`, `Input.wait_after(seen, timeout)`, `Input.watch`, `unwatch` (`void?`:
  INVALID_STATE from inside the listener it would remove):
  the state, `State{layouts: Layout[], current: Maybe{uint}, can_switch: bool}`.
* `Layout{id, name, short_code, language, variant}`: `id` is stable (xkb name `us`, `de(nodeadkeys)`; TIS id;
  KLID text `00000409`).
* `Input.switch_to(id) -> SwitchOperation*?` and `Input.next() -> SwitchOperation*?` (the id is copied into the
  operation; any length, only empty is refused): the operation's value is
  `SwitchOutcome`: `ACKNOWLEDGED` (the compositor or the OS confirmed it) or `QUEUED` (posted to the foreground
  window; the change shows in the state later).
* `Input.subscribe() -> Reader{Event}*?`: `Event{kind: LAYOUTS_CHANGED | CURRENT_CHANGED, layout_id}`.
* `Input.capability(Cap) -> Availability`, `Cap` = `LIST`, `CURRENT`, `SWITCH`, `EVENTS`.
* `Input.refresh()`, `Input.backend_name()`, `Input.close()`.

Every method may be called from any thread. Changes are published, never mutated in place. Requests that can
fail late return an `Operation`; a request the backend cannot serve is refused before it is queued, with the
reason from `capability`.

## Coverage

Run = executed on Linux against a fake (fake compositor, or a mock service on a private bus). Compiled only =
type-checked for the target with `tools/check.sh`, never executed. Not done = absent by design or not built.

| Capability | Linux compositor (Hyprland / sway / niri) | Linux locale1 (systemd-localed) | macOS TIS | Windows win32 |
| --- | --- | --- | --- | --- |
| LIST | Run (sway, niri: full list; Hyprland: one entry, DEGRADED) | Run (configured list, DEGRADED) | Compiled only | Compiled only |
| CURRENT | Run (sway, niri, Hyprland) | Not done: UNSUPPORTED_BACKEND | Compiled only | Compiled only (DEGRADED) |
| SWITCH | Run: sway, niri. Hyprland: Not done (UNSUPPORTED_BACKEND) | Not done: UNSUPPORTED_BACKEND | Compiled only | Compiled only (DEGRADED) |
| EVENTS | Run (activelayout, input, KeyboardLayoutSwitched) | Run (PropertiesChanged) | Compiled only (DEGRADED) | Compiled only (polled, DEGRADED) |

## Not done

* Hyprland switching. `bleu_compositor` exposes only `set_layout(index)`, and Hyprland's client reports only the
  active layout's name, so no index can be chosen. Hyprland's `switchxkblayout <device> next|prev|<id>` form is
  verified in hyprland-rs 0.4.0-beta.2 but needs a change in `bleu_compositor` (see the report).
* Hyprland's list is the active layout only. A change of the active layout therefore also reports
  `LAYOUTS_CHANGED`, because the one-entry list changed.
* Real compositors: the Linux compositor path ran against the `bleu_compositor` fakes only.
* i3 (no layout list in its IPC), river and dwl (no IPC client in `bleu_compositor`) are not offered.
* locale1: no writes (`SetX11Keyboard`), and no switching: localed holds the configuration, not the live layout.
* macOS: input methods are not listed (only keyboard layout sources, `kTISTypeKeyboardLayout`). TIS calls from a
  worker thread are unverified (Firefox calls them on its main thread). The distributed notification reaches
  an observer on the worker thread only if CoreFoundation delivers it there, which is unverified; the 1 s poll
  covers either case.
* Windows: a device-specific HKL (high word 0xF000 or more) has no KLID derivable from the value; its id is the
  HKL as hex. The name is the locale's English display name, not the layout's registry text.
* Windows: the `WM_INPUTLANGCHANGEREQUEST` effect on the window's thread is unverified on a Windows machine.
* The English layout descriptions in `languages.c3` (all but `English (US)`) are unverified: the xkeyboard-config
  file could not be fetched. They only match names a compositor reports; an unmatched name keeps its own text.
* Lock keys (caps, num, scroll) and pointer or keyboard settings: cut from v1 by the research.
* A switch still queued when the backend stops fails with CANCELLED (`abandon_command`); it is exercised by
  `service_test.c3` through a fake backend, not by a real compositor.
* A backend that cannot start (its poller refuses) stops with no state published: `latest()` stays
  UNAVAILABLE, and `capability` still reports what the backend would do. Requests fail, they do not wait.

## Verified how

* `tools/check.sh bleu_core bleu_rt bleu_service bleu_compositor bleu_dbus bleu_objc bleu_win bleu_input`: clean on
  all six targets.
* Unit tests (`src/*_test.c3`): `names_test`, `hkl_test`, `locale1_convert_test` pass on Linux x86-64, C3 0.8.5_1.
  `service_test.c3` (regression: a 200-byte layout id reaches the backend; an event is announced after its state is
  published; a switch queued at stop is cancelled) passes through a real Hub with fake backends.
* `tests/run_compositor.sh`: the live driver against `bleu_compositor`'s fake sway, niri and Hyprland; 22 checks
  pass, including the sway and niri switch requests on the wire.
* `tests/run_locale1.sh`: the live driver on a private system bus against `tests/mock_locale1.py` (python-dbus-next
  0.2.3): 14 checks pass, including a `PropertiesChanged` update and the no-service refusal.

## Run

    libs/bleu_input.c3l/tests/run_compositor.sh   # needs python3 and c3c
    libs/bleu_input.c3l/tests/run_locale1.sh      # needs dbus-daemon, python3 and c3c (dbus-next is installed in a venv)
