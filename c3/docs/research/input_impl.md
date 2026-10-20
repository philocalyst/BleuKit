# bleu_input: implementation notes

Spec: `docs/research/session_windows_input.md`, section "input" (v1 cut: layout list, current layout, switch,
change events; no lock-key LEDs, no pointer settings). Code: `libs/bleu_input.c3l/`. Read the library's README
for the coverage matrix and the not-done list. Dated 2026-10-20.

## Deviations from the research model (section 5)

* The research's `KeyboardLayouts`, `LockKeys` and `InputState` became `Layout{id, name, short_code, language,
  variant}` and `State{layouts, current: Maybe{uint}, can_switch}`. The research cut lock keys, so `LockKeys` is
  gone; `current` is `Maybe{uint}` (unknown is not zero) instead of an index with a `_known` flag.
* `Cap` is `LIST, CURRENT, SWITCH, EVENTS` with `Availability` per capability (the research's `InputCap` listed
  lock-state and pointer capabilities, which v1 cuts). `Backend` is `AUTO, COMPOSITOR, LOCALE1, TIS, WIN32`.
* `Event` is `{kind, layout_id}`: `LAYOUTS_CHANGED`, `CURRENT_CHANGED` (the research named per-lock events, cut).
* Switch returns `Operation{SwitchOutcome}`: `ACKNOWLEDGED` or `QUEUED`. The research did not say how a switch is
  confirmed; Windows only posts a message, so a bare "done" would overstate it.
* `can_switch` is in the state (the research's model had it). It means the route is connected and there are at
  least two layouts; the reason it is false is in `capability(SWITCH)`.
* `next()` is computed on the caller's thread from the latest state (wrap-around, first layout when the current
  one is unknown); `switch_to(id)` checks the id against the latest state. Both refuse with the capability's
  reason before queueing anything.
* Linux has a second backend the research did not name: `org.freedesktop.locale1` (the brief asked for it), read
  only.

## Verified (primary sources read 2026-10-20)

| Claim | Source(s) | Result |
| --- | --- | --- |
| TIS prototypes: `TISCreateInputSourceList(CFDictionaryRef, Boolean)`, `TISCopyCurrentKeyboardInputSource(void)`, `TISGetInputSourceProperty(TISInputSourceRef, CFStringRef)`, `TISSelectInputSource(TISInputSourceRef)` returns OSStatus | Apple HIToolbox `TextInputSources.h`, MacOSX10.13 SDK (phracker/MacOSX-SDKs, raw) ; Firefox `widget/cocoa/TextInputHandler.mm` (mozilla/gecko-dev, raw) | Confirmed; Firefox uses the same calls |
| Property keys `kTISPropertyInputSourceID`, `...LocalizedName`, `...InputSourceLanguages` (BCP 47), `...InputSourceIsSelectCapable`, `...InputSourceType`, value `kTISTypeKeyboardLayout`, `kTISNotifySelectedKeyboardInputSourceChanged` | the same header | Confirmed; Firefox filters by `kTISPropertyInputSourceType` |
| `CFNotificationCenterGetDistributedCenter`, `CFNotificationCenterAddObserver` (6 args), `CFNotificationSuspensionBehaviorDeliverImmediately` = 4 | core-foundation-sys 0.8.7 `src/notification_center.rs` (static.crates.io) | Confirmed |
| `TISSelectInputSource` requires IsSelectCapable and enabled | the header's discussion | Confirmed; the backend filters on IsSelectCapable |
| `GetKeyboardLayout(thread)`: low word LANGID, high word device handle; `0` is the current thread | Learn `nf-winuser-getkeyboardlayout` | Confirmed |
| `GetKeyboardLayoutList(nBuff, lpList)` | Learn `nf-winuser-getkeyboardlayoutlist`; mingw-w64 `winuser.h` | Confirmed (system-wide list) |
| `ActivateKeyboardLayout` affects the calling thread or process only | Learn `nf-winuser-activatekeyboardlayout` ("only affects the layout for the current process or thread") | Confirmed: not used for switching other apps |
| `WM_INPUTLANGCHANGEREQUEST` = 0x0050, handled by `DefWindowProc`, which activates the locale and sends `WM_INPUTLANGCHANGE`; `WM_INPUTLANGCHANGE` lParam is the HKL | Learn `win32/winmsg/wm-inputlangchangerequest`, `.../wm-inputlangchange`; mingw `winuser.h` | Confirmed |
| KLID = hex of language (low four digits) and device identifier (high four); US English is `00000409`, Dvorak `00010409` | Learn `nf-winuser-loadkeyboardlayoutw`; Wine `dlls/user32/input.c` (`LoadKeyboardLayoutW`: a zero high word gives HKL `LANGID|LANGID<<16`) | Confirmed; the two agree on the rule in `hkl.c3` |
| `MAKELCID(lang, SORT_DEFAULT)` = language id; `SORT_DEFAULT` 0; `LOCALE_NAME_MAX_LENGTH` 85 | mingw-w64 `winnt.h` | Confirmed |
| `LCIDToLocaleName`, `GetLocaleInfoEx`, `LOCALE_SENGLISHDISPLAYNAME` 0x72, `LOCALE_NAME_MAX_LENGTH` | mingw-w64 `winnls.h`; Learn WM_INPUTLANGCHANGE sample (`LCIDToLocaleName(MAKELCID(langId, SORT_DEFAULT))`) | Confirmed |
| Hyprland `activelayout` event = `KEYBOARD,LAYOUT` | Hyprland source `src/managers/input/InputManager.cpp` (raw, main); Hyprland wiki IPC page | Confirmed |
| Hyprland `switchxkblayout <device> next|prev|<id>` | hyprland-rs 0.4.0-beta.2 `src/ctl.rs` (static.crates.io) | Confirmed in the crate. Not confirmed in Hyprland's own dispatcher source, which was not found at the paths tried |
| Sway `input <identifier> xkb_switch_layout <index>|next|prev`; `input type:keyboard` criterion | sway `sway-input.5.scd` (swaywm/sway, raw) | Confirmed |
| Sway `GET_INPUTS` fields `xkb_active_layout_name`, `xkb_layout_names`, `xkb_active_layout_index` | sway `sway-ipc.7.scd` (raw) | Confirmed |
| niri `Action::SwitchLayout { layout: Next | Prev | Index(u8) }`; `KeyboardLayouts { names, current_idx }`; events `KeyboardLayoutsChanged`, `KeyboardLayoutSwitched { idx }` | niri-ipc 25.11.0 `src/lib.rs` (static.crates.io) | Confirmed |
| locale1: bus name `org.freedesktop.locale1`, path `/org/freedesktop/locale1`, read-only `s` properties `X11Layout`, `X11Variant`, `X11Model`, `X11Options`, `VConsoleKeymap` | systemd man page `org.freedesktop.locale1` (freedesktop.org); systemd `src/locale/localectl.c` (raw) | Confirmed. The `org.freedesktop.locale1.xml` in systemd's tree was not found at the paths tried |
| BCP 47 subtags of the table (en, de, fr, es, it, ru, pl, sv, ja, uk, cs; US, GB, DE, FR, ES, IT, RU, PL, SE, JP, UA, CZ) | IANA language subtag registry (fetched) | Confirmed |

## Still UNVERIFIED (marked in code or here)

* The English descriptions in `languages.c3` other than `English (US)` (sway-ipc examples confirm that one). The
  xkeyboard-config `rules/base.lst` was not reachable (GitHub mirrors and gitlab raw all 404).
* macOS: that TIS calls work from a worker thread (Firefox calls them on its main thread); that a distributed
  notification reaches an observer registered on a thread without a run loop. The 1 s poll covers the second.
* Windows: what the foreground window's thread does with `WM_INPUTLANGCHANGEREQUEST` in practice (it is documented
  to activate the locale through `DefWindowProc`).
* Hyprland: whether `j/devices` keyboards carry a `layout` string (the configured list). Not read; a request in the
  report needs it.

## Tests run (all from private work directories, `timeout`, `-o` outputs)

* `tools/check.sh bleu_core bleu_rt bleu_service bleu_compositor bleu_dbus bleu_objc bleu_win bleu_input`: ok on all
  six targets (after `c3fmt -i` on `src/*.c3` and `tests/live/*.c3`).
* `compile-test` of the library: 10 `bleu::input` tests and 98 in total, all pass (`hkl_test`, `locale1_convert_test`,
  `names_test`).
* `tests/run_compositor.sh`: 22 checks pass (sway, niri, Hyprland fakes from `bleu_compositor`).
* `tests/run_locale1.sh`: 14 checks pass (private dbus-daemon, `mock_locale1.py` with dbus-next 0.2.3).

## Shutdown

A queued switch that the worker has not run when `close()` stops it is failed with `CANCELLED` (`fail_queued`). This
was reviewed against `bleu_rt`'s `Worker.stop` (the mailbox is closed, queued commands stay) and brightness's
`Engine.finish`, but no test forces the race.
