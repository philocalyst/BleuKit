# bleu_hotkey: implementation notes

Spec: `docs/research/session_windows_input.md`, section "hotkey" (v1 cut: portal on Linux,
Carbon on macOS, RegisterHotKey on Windows; no event taps, no low-level hooks, no evdev).
Library: `libs/bleu_hotkey.c3l/` (README there). This file records what was checked against
primary sources, what deviates from the research note, and what is still unverified.

## Verified (primary sources, fetched 2026-10-20 through the agent proxy)

| Claim | Source (URL) | Result |
| --- | --- | --- |
| GlobalShortcuts methods, signals, `version` property | xdg-desktop-portal `data/org.freedesktop.portal.GlobalShortcuts.xml` (raw.githubusercontent.com/flatpak/xdg-desktop-portal/main) | read; `CreateSession`, `BindShortcuts(o, a(sa{sv}), s, a{sv})`, `ListShortcuts(o, a{sv})`, `Activated`/`Deactivated (osta{sv})`, `ShortcutsChanged (oa(sa{sv}))` |
| An application binds a session once | same XML, BindShortcuts note: "An application can only attempt to bind shortcuts of a session once." | read. There is no unbind method: removal closes the session and binds the rest again |
| Activated timestamp | same XML | milliseconds, "with an undefined base" |
| `activation_token` in Activated/Deactivated options | same XML | read (optional) |
| Request object path rule and Response codes 0/1/2 | `org.freedesktop.portal.Request.xml` (same tree) | read; path = `/org/freedesktop/portal/desktop/request/SENDER/TOKEN`, SENDER = unique name without ':' and '.' -> '_' |
| Session path rule | `org.freedesktop.portal.Session.xml` | read; the `session_handle` result is an `s` (kept for compatibility) |
| Trigger syntax: modifiers CTRL, ALT, SHIFT, NUM, LOGO joined by '+', then an xkbcommon keysym | shortcuts specification, specifications.freedesktop.org/shortcuts/latest/ (the XDP-GS link `shortcuts-spec/latest` redirects here) | read; example "CTRL+ALT+Return" |
| Keysym identifiers used by `keymap_xkb.c3` | xkbcommon `include/xkbcommon/xkbcommon-keysyms.h` (raw.githubusercontent.com/xkbcommon/libxkbcommon/master) | read; all 95 names in `keymap_xkb.c3` are present (checked by script) |
| `MOD_NOREPEAT` 0x4000, `MOD_*`, `WM_HOTKEY`, `ERROR_HOTKEY_ALREADY_REGISTERED` 1409, `ERROR_HOTKEY_NOT_REGISTERED` 1419 | MinGW-w64 headers `winuser.h`, `winerror.h` (raw.githubusercontent.com/mirror/mingw-w64) and learn.microsoft.com RegisterHotKey page | read; two sources for the MOD values |
| VK codes | `winuser.h` (MinGW-w64) and learn.microsoft.com "Virtual-Key Codes" | read; every value in `keymap_windows.c3` is on the Microsoft page and defined in `winuser.h` (checked by script; letters and digits are ASCII, as winuser.h documents) |
| Carbon hotkey constants | `CarbonEvents.h` and `Events.h` (phracker/MacOSX-SDKs, MacOSX10.13 HIToolbox) | read; kEventHotKeyPressed 5, kEventHotKeyReleased 6, kEventClassKeyboard 'keyb', typeEventHotKeyID 'hkid', kEventHotKeyExclusive 1, cmdKey/shiftKey/optionKey/controlKey = bits 8/9/11/12 |
| kVK key codes | `Events.h` (same SDK) | read; the table is generated from those lines (see `keymap_macos.c3`) |
| `kEventParamDirectObject` = '----' (757935405) | `global-hotkey` 0.7.0 crate, `src/platform_impl/macos/ffi.rs` (static.crates.io) | read (bindgen output); the constant is not in the SDK headers fetched |
| Carbon call sequence (install handler on the application target, RegisterEventHotKey with the 8-byte hot-key ID, GetEventParameter with direct object) | `global-hotkey` 0.7.0 `src/platform_impl/macos/mod.rs`; Hammerspoon `extensions/hotkey/libhotkey.m` (raw) | read; two sources |
| `InstallApplicationEventHandler` is `InstallEventHandler(GetApplicationEventTarget(), ...)` | `CarbonEvents.h` macro definitions | read |

## Deviations from the research note and the brief

1. **ListShortcuts version.** The research note says ListShortcuts was "added in version 2". The XML
   marks only `ConfigureShortcuts` as added in version 2; ListShortcuts carries no marker. The
   backend calls ListShortcuts on every round and treats its failure as non-fatal, so an older portal
   still binds. Corrected here; the research note is not edited (it is not owned by this service).
2. **Portal rounds.** Because of the once-per-session rule and the missing unbind, each round closes
   the previous session, creates a new one, lists, and binds the whole set. Consequences: every
   registration or removal shows the compositor's dialog again (one dialog per round, not per call;
   requests accepted while a round is running join the next one); a user who declines the dialog
   refuses the whole round (the registrations are REFUSED, the operations fail with CANCELLED).
3. **Portal reply and Response order.** The reply to a call and its Response may arrive in either
   order. A round moves on only when both have arrived (`replied` and `answered`).
4. **Portal CONFLICT.** The portal does not report a clash with another application; CONFLICT is
   never produced there (`Cap.CONFLICT_REPORT` = UNSUPPORTED_BACKEND).
5. **Carbon registration.** Options: the application event target and `kEventHotKeyExclusive`. The
   research note and Hammerspoon use exclusive; global-hotkey uses options 0 (shared). Exclusive makes a
   clash fail, which is what the caller needs to know. The dispatcher target (Hammerspoon) and the
   application target (global-hotkey, and the brief's InstallApplicationEventHandler) both deliver
   hot-key events; the application target is used.
6. **Windows WM_HOTKEY.** `bleu::win::message_loop` does not report WM_HOTKEY (its `window_proc`
   sends unknown messages to DefWindowProc), and its `pump`/`dispatch_pending` would consume a
   WM_HOTKEY without reporting it. The worker therefore waits with `bleu::rt::poller` in
   window-message mode and drains the queue itself. A `HOTKEY` event kind in `message_loop` would let
   this go through the shared loop; that is a change requested of `bleu_win`.
7. **Key module split.** `Key` and `Modifiers` live in `bleu::hotkey::keys`, not the root module, so
   the keymap files can import them without a module cycle.
8. **Carbon conflict code.** `eventHotKeyExistsErr` is named in `CarbonEvents.h` (line 15473) but its
   value is not in any header fetched (MacErrors.h and the HIToolbox headers were searched). A clash
   is reported as BACKEND_FAILURE with the OSStatus; CONFLICT is not produced on macOS.

## Unverified (marked in code and in the README)

* macOS: whether a worker thread may call RegisterEventHotKey and UnregisterEventHotKey (Hammerspoon
  calls them on the main thread); whether presses are delivered while the host's main thread runs its
  event loop (the callback is installed; delivery is not observed here).
* macOS: the value of `eventHotKeyExistsErr`.
* Per-desktop portal support: KDE, GNOME and Hyprland backends of GlobalShortcuts are not read. The
  desktop answers response 2 or lacks the interface; both are handled, neither was observed on a
  real desktop.
* The trigger text the desktop shows (`trigger_description`): the mock echoes `preferred_trigger`.
* Windows: no run on Windows (compile only). The VK values, MOD values and error codes are checked
  against the headers above; the behaviour of RegisterHotKey on conflict (error 1409) is from the
  error table, not observed.

## Tests and runs (2026-10-20, Linux x86-64, C3 0.8.5_1)

* Pure `@test`s: 18 in `chord_test.c3`, `keymap_test.c3`, `portal_path_test.c3`. The Linux
  `compile-test` of every test file with the Linux source set runs them with the shared libraries'
  tests (see the run record below).
* Live: `libs/bleu_hotkey.c3l/tests/run.sh` against `tests/mock_portal.py` (dbus-next, private
  session bus, `dbus-daemon`): `the_portal_binds_reports_and_follows` PASS (1.85 s); the absent-portal
  test PASS. The mock implements Request objects with Response signals (0, 1, 2), Session.Close, the
  `version` property, and the three signals.
* Type-check, all six targets, `compile-only --no-obj --warn-deprecation=error --warn-deadcode=no`
  with the dependencies: exit 0 for linux-x64, linux-aarch64, macos-aarch64, macos-x64, windows-x64,
  windows-aarch64.

## C3 gotchas met (for the shared gotchas list)

* `Writer.begin_array` takes the full array type ("a{sv}", "a(sa{sv})"), not the element type; the
  wrong one is refused at run time with INVALID_ARGUMENT.
* `alias` is a keyword (`foreach (alias : ...)` does not parse); `fault` is a keyword (`catch fault =`).
* An enum has no `.values` in 0.8.5: iterate `0 ..< CONST` with a cast and pin the constant in a test.
* A function of an imported module needs its module prefix even when the module is imported:
  `hotkey::format_portal_trigger(...)`.
* A helper named `drop` in a module that imports `bleu::dbus::connection` resolves to the connection's
  private `drop`, which gives "not visible from other modules"; rename helpers (`text_free`).
* `Type.sizeof` is rejected; use `@sizeof(variable)`.
* A bitstruct cannot be shifted or OR-ed as a value: use `uint` masks and cast (`(Modifiers)bits`).
* A contract's `@return?` text may not be followed by parentheses; the parser says "Expected the end
  of the contract here".
* An `if (catch ...)` on an expression that itself uses `!` does not parse; split it into `try` blocks.
* dbus-next (Python) needs struct values as lists, not tuples, in `Variant` bodies.
