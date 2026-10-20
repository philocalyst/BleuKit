# bleu_appearance

Desktop appearance as plain data: colour scheme and accent, contrast and
reduced-motion flags, font and text scale, icon, GTK and cursor theme names,
clock format and wallpaper, plus the requests to set the scheme and the
wallpaper. Module root `bleu::appearance`. Built on `bleu_service` (hub, worker,
observable state, events, operations) and on `bleu_dbus` (Linux), `bleu_objc`
(macOS) and `bleu_win` (Windows).

Scope and sources: `docs/research/apps_sysinfo_secrets_appearance.md`, part (D),
with its v1 cut. The time zone and locale are not in the v1 cut and are not
implemented (Caps say so).

## Public API

* `appearance::open(allocator, Options) -> Appearance*?`: `backend`, `poll`,
  `bus_address`, `wallpaper_command` (argv; `{path}` is replaced; empty means GNOME keys).
* `Appearance.close()`, `backend_name()`, `capability(Cap) -> Availability`.
* `Appearance.latest() -> Snapshot{State}*?`, `wait_after(seen, timeout)`, `watch`, `unwatch` (`void?`:
  INVALID_STATE from inside the listener it would remove).
* `Appearance.subscribe() -> Reader{Event}*?`: `EventKind` COLOR_SCHEME, ACCENT, ACCESSIBILITY, DESKTOP, WALLPAPER.
* `Appearance.refresh()`: re-read now.
* `Appearance.set_color_scheme(ColorScheme) -> Operation{bool}*?`: refused with `UNSUPPORTED` when not available.
* `Appearance.set_wallpaper(String absolute_path) -> Operation{bool}*?`: refused when not available;
  `INVALID_ARGUMENT` unless the path is absolute on this platform: `/...` on POSIX; `C:\...`, `C:/...` or
  `\\server\share\...` on Windows (`paths.c3`).
* Model: `State` (`ColorScheme`, `Maybe{Rgb} accent`, `Contrast`, `reduced_motion`,
  `reduced_transparency`, `font_name`, `Maybe{float} text_scale`, `icon_theme`,
  `gtk_theme`, `cursor_theme`, `ClockFormat`, `Wallpaper[]`), `Cap`, `Backend`.
* Usage: `Operation{bool}* done = app.set_color_scheme(DARK)!; defer done.release(); done.wait(time::ms(5000))!;`
  The state changes when the desktop reports it, not when the operation succeeds.

## Coverage (capability x backend)

Run = executed here against fakes (Linux only). Compiled = type-checked for the
target, never executed. Not done = the capability reports UNSUPPORTED_* at run time.

| Capability | Linux portal (+ gsettings extras) | Linux gsettings | macOS appkit | Windows win32 |
| --- | --- | --- | --- | --- |
| COLOR_SCHEME (get) | Run (portal, mock) | Run (gsettings) | Compiled | Compiled |
| COLOR_SCHEME_SET | Run (gsettings `set`) | Run | Compiled (AppleScript, permission unverified) | Compiled (registry, no broadcast) |
| ACCENT | Run (portal, mock) | Not done (GNOME name, no RGB) | Not done (undocumented key) | Compiled (DWM layout UNVERIFIED) |
| CONTRAST | Run (portal, mock) | Not done | Compiled (NSWorkspace) | Not done |
| REDUCED_MOTION | Run (portal, mock) | Run (enable-animations) | Compiled (NSWorkspace) | Not done |
| REDUCED_TRANSPARENCY | Not done (no portal key) | Not done | Compiled (NSWorkspace) | Not done |
| FONT, TEXT_SCALE, THEME_NAMES, CLOCK_FORMAT | Run (gsettings, real schemas) | Run | Not done | Not done (UISettings deferred) |
| WALLPAPER (get) | Run (gsettings) | Run | Compiled (NSScreen) | Compiled (SPI) |
| WALLPAPER_SET | Run (gsettings and command) | Run (gsettings and command) | Compiled (NSWorkspace) | Compiled (SPI) |
| WALLPAPER_PER_SCREEN | Not done (v1 cut) | Not done | Compiled | Not done (IDesktopWallpaper deferred) |
| Change events | Run (SettingChanged, mock) | Poll only | Compiled (notification, delivery UNVERIFIED; poll backstop) | Compiled (registry watch, WM_SETTINGCHANGE) |

## Verified how

* Unit: `c3c compile-test` of `src/convert_test.c3` and `src/paths_test.c3` with the library sources, run with
  `--test-filter bleu::appearance`: 14 `@test`s pass. They cover the GVariant escapes (unknown ones refused), the
  `file://` host rule, the per-platform absolute-path predicates (both Windows forms and POSIX run on every host).
* Live (Linux): `tests/run.sh`: a private dbus-daemon, a python-dbus-next mock of
  `org.freedesktop.portal.Settings` (`ReadAll`, `Read` returning a double variant,
  `SettingChanged`), and the GNOME schemas (the two `.gschema.xml` files fetched upstream; the enums file is hand-written, since the upstream one returned 404) compiled with
  `GSETTINGS_BACKEND=keyfile`. Three modes: portal (checks, including `gsettings` read-back of the writes; 33 PASS lines), gsettings fallback with a
  wallpaper command, and absent (no bus, no gsettings). Exit status 0.
* Type-check: all six targets (`c3c ... compile-only`), with `bleu_core bleu_rt bleu_service bleu_dbus bleu_objc bleu_win`.
  Note: the working tree's `bleu_dbus` currently does not compile (an uncommitted
  `server_model.c3` from another engineer). Verification used the committed copy
  (`git archive HEAD libs/bleu_dbus.c3l`), passed to `run.sh` as `BLEU_LIBDIR`.
* `c3fmt --check` clean on `src/` and `tests/`.
* macOS and Windows: type-checked only. Nothing ran on either OS. The Windows degrade-not-abort change (no `!!`
  on registry or window calls) is compiled, not run.

## Not done

* WinRT `UISettings` (fonts, text scale, animations, colour values) and `IDesktopWallpaper` (per monitor): deferred.
* Time zone (cut) and locale (not in v1 cut; Caps report UNSUPPORTED).
* dconf's D-Bus writer (`ca.desrt.dconf`): not cited or mocked, so writes use `gsettings set` (explicit fallback).
* `org.freedesktop.portal.Wallpaper`, KDE `kdeglobals`, and compositor IPC except through `wallpaper_command`.
* Reading gsettings through the dconf file database (out of scope; `gsettings get` only).
* Portal restart is not re-subscribed. If the session bus closes, the portal backend stops: the last state
  stands, and every later request fails with UNAVAILABLE (the worker's mailbox is closed).
* A failed read keeps the last reading, never a guess: the Windows scheme (when the Personalize key cannot be
  opened), the gsettings scheme and reduced motion. The portal publishes nothing until its first `ReadAll` works,
  and a key whose `Read` fails is read again on the next poll tick.
* Windows: `AppsUseLightTheme` is the only value written. The taskbar and the system UI keep their scheme.
* A backend that cannot start publishes no state: `latest()` stays UNAVAILABLE, and requests fail.
* gsettings-sourced desktop keys refresh on the poll interval (30 s default), and on every request.
* macOS: accent, font, clock; the accessibility-change notification (name not verified); delivery of the distributed notification without a run loop (UNVERIFIED).
* Windows: a broadcast after writing the scheme; DWM AccentColor layout (UNVERIFIED); contrast, motion, transparency.
