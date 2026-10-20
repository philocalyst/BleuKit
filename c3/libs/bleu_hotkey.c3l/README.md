# bleu_hotkey

Global keyboard shortcuts as plain data: register a chord under an id, read which registrations the
platform accepted, and follow presses and releases while another application has the focus. Module
root `bleu::hotkey`; backends `bleu::hotkey::portal` (Linux), `::carbon` (macOS), `::windows`
(Windows). Research and the v1 cut: `docs/research/session_windows_input.md`, section "hotkey".
Implementation notes, every verified source and every deviation: `docs/research/hotkey_impl.md`.

## Public API

    Hotkey* hotkeys = hotkey::open(mem, { .backend = AUTO })!;      // PORTAL, CARBON, WIN32 to force one
    defer hotkeys.close();
    Chord chord = hotkey::parse_chord("Ctrl+Alt+T")!;               // "Shift+Super+F12", "Cmd+Space" ...
    Task* task = hotkeys.register("toggle", "Show or hide the bar", chord)!;
    Binding binding = task.wait(time::ms(30000))!;                  // BOUND, CONFLICT, REFUSED (or an error)
    task.release();
    Task* gone = hotkeys.unregister("toggle")!;                     // finishes with the removed binding
    stream::Reader{Event}* presses = hotkeys.subscribe()!;          // PRESSED / RELEASED, with `at`
    Snapshot{State}* state = hotkeys.latest()!;                     // bindings, portal_version, registration
    hotkeys.capability(Cap.PRESS_RELEASE);                          // Availability: available, or why not
    hotkeys.backend_name();                                         // "portal", "carbon", "win32"

`Task` is `Operation{Binding}`: `register` and `unregister` return one, and it finishes when the
platform has answered (on the portal that can be after the user answers a dialog). `chord_text`
formats a chord both ways: `format_chord` ("Ctrl+Alt+T") and `format_portal_trigger` ("CTRL+ALT+t",
the shortcuts specification's form).

## Coverage

"Run" = executed on Linux, against a mock portal on a private session bus (`tests/run.sh`) or as a
unit test. "Compiled-only" = type-checked for the target, never executed. "Not done" = not in v1, or
impossible on that platform (see the reason in `capability()`).

| Capability | Linux portal (xdg-desktop-portal) | macOS carbon | Windows win32 |
| --- | --- | --- | --- |
| REGISTER (bind a chord) | Run (mock: CreateSession, ListShortcuts, BindShortcuts) | Compiled-only | Compiled-only |
| UNREGISTER | Run (mock: a new session binds the rest) | Compiled-only | Compiled-only |
| Refusal by the user or the desktop (REFUSED) | Run (mock `refuse`) | Not done (no dialog) | Not done (no dialog) |
| User declines the dialog (CANCELLED) | Run (mock `mode cancel`) | Not done | Not done |
| Desktop has no GlobalShortcuts (response 2, UNSUPPORTED) | Run (mock `mode other`, version property) | Not done | Not done |
| PRESSED events with timestamp and token | Run (mock `activate`) | Compiled-only (no time or token) | Compiled-only (no token; timestamp = MSG.time) |
| RELEASED events (PRESS_RELEASE) | Run (mock `deactivate`) | Compiled-only | Not done (RegisterHotKey has no key-up) |
| CONFLICT (another program owns the chord) | Not done (the portal does not report clashes) | Not done (the clash code is unverified) | Compiled-only (error 1409 maps to CONFLICT) |
| Trigger text shown by the desktop | Run (bind response, ShortcutsChanged) | Not done | Not done |
| Reconnect after the bus restarts | Compiled-only (not exercised) | n/a | n/a |
| Key tables: Windows VK, macOS kVK, XKB names | Run (unit tests, every key) | Run (unit tests, table values) | Run (unit tests, table values) |
| Chord parse and format, portal paths | Run (unit tests) | Run (unit tests) | Run (unit tests) |

Run on Linux: the 18 pure `@test`s (chord text, key tables, portal paths) and `tests/run.sh` (live
portal and the absent-portal refusal). `tools/check.sh bleu_core bleu_rt bleu_service bleu_dbus
bleu_dl bleu_win bleu_hotkey` is clean on all six targets.

## Not done

* macOS and Windows backends have never been executed. Carbon presses need the host's main thread to
  run its event loop; whether a worker thread may call the Carbon registration functions is unverified
  (Hammerspoon calls them on the main thread).
* Windows: the hot keys are registered on a `bleu::win::message_loop.Loop` owned by the worker; a conflict
  with another program is kept as a CONFLICT binding that cannot fire.
* Portal: no event taps, no low-level hooks, no KDE, GNOME or Hyprland native routes, no X11 grab
  (research cut). A desktop whose portal lacks GlobalShortcuts reports UNSUPPORTED; no fallback.
* Portal: a bus restart is handled by reconnecting and binding again on the next tick, but the tests
  do not exercise it. A request that a compositor never answers waits until the caller's timeout.
* Portal: `ConfigureShortcuts` (the settings dialog) is not called.
* Carbon: the conflict code of `RegisterEventHotKey` is not in the headers read, so a clash is a
  BACKEND_FAILURE, not CONFLICT. Media, volume, Insert, Print Screen, Pause, F21-F24 have no macOS
  keycode here and are UNSUPPORTED.
* Windows: the hotkey ids are counted per backend from 1; no wrap-around after 2^31 registrations.

## Verification and how to run it

    libs/bleu_hotkey.c3l/tests/run.sh          # live portal + absent-portal test (needs dbus-daemon, python3, dbus-next)
    tools/check.sh bleu_core bleu_rt bleu_service bleu_dbus bleu_dl bleu_win bleu_hotkey   # six targets
    c3c --libdir "$(tools/libdir.sh)" --lib bleu_core --lib bleu_rt --lib bleu_service --lib bleu_dbus \
        --lib bleu_dl --lib bleu_win compile-test libs/bleu_hotkey.c3l/src/*_test.c3 \
        --sources <the non-test, non-Windows, non-macOS files of src/>   # Linux unit tests

`tests/run.sh` starts a private session bus and `tests/mock_portal.py` (python-dbus-next), which
implements the GlobalShortcuts methods, Request objects with Response signals, Session.Close and the
`version` property; the test drives it through a control file (`mode`, `refuse`, `activate`,
`deactivate`, `changed`, `version`, documented in the mock).
