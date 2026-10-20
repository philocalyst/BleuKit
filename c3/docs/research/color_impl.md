# bleu_color: implementation notes

Scope: `libs/bleu_color.c3l` (module root `bleu::color`), built to the v1 cut in
`docs/research/display.md`: wlroots gamma ramps on Linux, `SetDeviceGammaRamp` on Windows,
`CGSetDisplayTransferByTable` on macOS; colour temperature from a black-body table; software dimming
as the GAMMA mechanism; sunrise and sunset schedules. Not built, as the cut says: Night Shift, the
Windows night-light registry blob, ICC profiles.

## 1. What was built

| File | Role | Run |
| --- | --- | --- |
| `model.c3` | State, Control, Output, Schedule, Mode, Cap, Event, Command, Applied, Options | - |
| `kelvin_table.c3`, `kelvin.c3` | 242-row black-body table; `rgb(Kelvin)` with clamp and interpolation | tests |
| `ramp.c3` | `fill` (gamma, brightness, temperature, any size >= 2), `encode_u16` | tests |
| `schedule.c3` | NOAA sun position, `day_events`, `daylight_at` with transitions, polar fallback, `validate` | tests |
| `engine.c3` | platform-neutral state machine: commands, apply/release, follow schedule, publish, `serve_timed` | via mock |
| `service.c3`, `driver.c3`, `probe.c3`, `linux.c3`, `windows.c3`, `darwin.c3` | the facade and driver table | via mock |
| `linux_wlr.c3` | wlr-gamma-control backend (memfd ramps, probe, refusal, lost control) | mock |
| `windows_ramp.c3`, `windows_displays.c3` | gdi32 SetDeviceGammaRamp with read-back; user32 EnumDisplayDevicesW | compiled only |
| `coregraphics.c3` | CGSetDisplayTransferByTable with captured tables | compiled only |
| `*_test.c3` | 23 `@test` functions: kelvin 6, ramp 6, schedule 8, linux_wlr 3 | run |

## 2. Deviations from `docs/research/display.md`

1. **Kelvin.** The research says "Tanner Helland/redshift". Only the redshift table is implemented. The
   Tanner Helland formula is not used. wlsunset's `color.c` is a different method (Planckian and
   daylight loci) and is used as a cross-check in tests, not as the implementation.
2. **Sun position.** The research gives no equations. The NOAA worksheet `solareqns.PDF` uses a simpler
   Spencer series; it was fetched and is not used. The implementation follows NOAA's solar calculator
   `main.js`, whose coefficients and functions are listed in section 3. Its sunrise rule (zenith
   90.833) is the same.
3. **Ramp scale.** Entries are scaled by 65535 (the largest 16-bit value) and clamped, so full scale
   stays representable. Redshift's `colorramp_fill` scales by 65536 (`UINT16_MAX+1`); its full-scale
   behaviour was not tested here.
4. **Control.** Added `availability` (why a display is unsupported) and `refused` (the last attempt to
   take its gamma control was refused). The research's list had no way to report a refusal.
5. **Refusal semantics.** The protocol sends `failed` both when another client holds the control and
   when the output has no table. The two cannot be told apart from it. A refused display therefore
   reports BUSY, and the next command tries again. An earlier draft returned BUSY before trying and
   so never retried; it was found on re-reading the engine and fixed. `losing_the_control_later_is_reported`
   covers the retry.
6. **Windows read-back.** Not in the research. `SetDeviceGammaRamp` returns TRUE without applying a ramp
   its heuristics refuse, so the backend reads the ramp back and fails the write on a mismatch.
7. **macOS restore.** The research lists `CGDisplayRestoreColorSyncSettings`. The backend captures each
   display's own table at open and restores that table on release (so only what was changed is put
   back), and calls `CGDisplayRestoreColorSyncSettings` once at shutdown when a display held a ramp.
8. **Probe on Linux.** The probe connects, reads the registry, and disconnects; it takes no gamma control.
   With a test seam (`Options.connect`) the probe returns true without connecting, because the seam
   gives out one descriptor. This is documented in `linux_wlr.c3`.
9. **Gamma sizing at open (Linux).** Each output's control is acquired and destroyed once at open to learn
   its size and refusal. This holds the control for one round trip and changes nothing on screen.
10. **Output ids.** The wl_output `name` (protocol version 4), else `wl_output-<global>`; Windows device
    names (`\\.\DISPLAY1`); CoreGraphics `cg-<id>`.

## 3. Verified facts, and where

Each row is a claim the code relies on. "Read" means the lines were read in a fetched file; "grep" means
matched lines only.

| Claim | Source (fetched) | Lines / section | How read |
| --- | --- | --- | --- |
| Black-body table, 1000 K to 25100 K in 100 K steps, 242 rows, 3 floats each | Redshift `src/colorramp.c` (raw.githubusercontent.com/jonls/redshift/master) | 30-273 | read; rows copied by script |
| Table max channel is 1.0 in every row; 6500 K row is (1,1,1) | same | 30-273 | checked by test |
| Fill: `pow(Y * brightness * white[C], 1/gamma[C])` | same | 285-286 (macro F), 310-322 (`colorramp_fill_float`) | read |
| Planckian and daylight loci, 1/2.2 gamma in xyz_to_rgb | wlsunset `color.c` (raw.githubusercontent.com/kennylevinsen/wlsunset/master) | 87 (illuminant_d), 119 (planckian_locus), 163-168, 179-180 | read |
| Gamma ramp: three ramps of `size` entries; `set_gamma(fd)`; `gamma_size(size)`; `failed`; destroy restores | wlr-gamma-control-unstable-v1.xml (gitlab.freedesktop.org/wlroots/wlr-protocols, raw) | 58, 76-77, 80, 93-103, 106-115, 119-122 | read |
| **The XML says "16-byte unsigned integers" (line 97).** The length rule (line 100: "three times the gamma size") makes an entry 2 bytes, so this is a typo in the protocol text, and entries are u16. | same | 97, 100 | read |
| `SetDeviceGammaRamp`: three arrays of 256 WORDs, RGB in the most significant bits; heuristics make it return TRUE and not set the ramp; any app can overwrite it; reset on most display events | Microsoft Learn `SetDeviceGammaRamp` (learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-setdevicegammaramp) | Syntax; Important; Parameters | read (text) |
| `GetDeviceGammaRamp(HDC, LPVOID)` | Microsoft Learn `GetDeviceGammaRamp` | Syntax; Parameters | read (text) |
| `DISPLAY_DEVICEW` layout: cb, DeviceName[32], DeviceString[128], StateFlags, DeviceID[128], DeviceKey[128] | Microsoft Learn `DISPLAY_DEVICEW` (ns-wingdi-display_devicew) | Syntax | read |
| `DISPLAY_DEVICE_ATTACHED_TO_DESKTOP` = 0x00000001 | Wine `include/wingdi.h` (raw, wine-mirror/wine/master) | line 3372 | read; the Microsoft page names the flag but not its value |
| `CreateDCW("DISPLAY", device)`: the thread that creates the HDC owns it; use `EnumDisplayDevices` names | Microsoft Learn `CreateDCW` (wingdi.h) | Remarks | read |
| `CGGetActiveDisplayList(uint, CGDirectDisplayID*, uint*)`, `CGSetDisplayTransferByTable(display, size, r, g, b)`, `CGGetDisplayTransferByTable(display, capacity, r, g, b, samples)`, `CGDisplayRestoreColorSyncSettings()`, `CGGammaValue = float` | objc2-core-graphics 0.3.2 (static.crates.io), generated from the Apple SDK headers | src/generated/CGDirectDisplay.rs: 96-100, 307, 395-401, 412-419, 439-443 | read |
| `CGError` is `i32`, `Success` = 0 | same, `CGError.rs` | line 13, 16 | read |
| Lunar uses `CGSetDisplayTransferByTable(display, size, r, g, b)` | research note, `docs/research/display.md` section 2.8 (LUN-GAM line 385) | research note | **not re-read in this run** |
| `memfd_create(const char *name, unsigned int flags)`, `MFD_CLOEXEC` | man7.org memfd_create(2) (fetched) | SYNOPSIS, DESCRIPTION | read |
| NOAA equations: L0, M, e, C, omega, apparent longitude, obliquity, declination, equation of time (x4, in minutes), sunrise hour angle with zenith 90.833, sunrise = 720 - 4(lon + ha) - eqtime | NOAA GML solar calculator `main.js` (gml.noaa.gov/grad/solcalc/main.js) | 115-236 (calc* functions), 338-367 (`calcSolNoon`, `calcSunriseSetUTC`) | read for these functions |
| NOAA worksheet `solareqns.PDF` (Spencer series, zenith 90.833) | gml.noaa.gov/grad/solcalc/solareqns.PDF, text extracted with pdftotext | whole | read; not used (section 2.2) |
| Published sunrise and sunset, 2026-03-20 UTC | sunrise-sunset.org JSON API (`formatted=0`) | London 06:01:06 / 18:14:49; New York 10:57:28 / 23:09:21; Sydney 19:56:52 (on 19 March UTC) / 08:08:36 | queried |
| Second computation of the same times | astral 3.2 (PyPI), Python | London 06:03:39 / 18:13:14; New York 10:59:30 / 23:07:57; Sydney sunset 08:06:43 | run |

## 4. Cross-checks

**Kelvin, three reference temperatures** (redshift table, interpolated; wlsunset Planckian/daylight
computation, normalised; `src/kelvin_test.c3` asserts within 0.01):

| K | redshift (R, G, B) | wlsunset (R, G, B) | max difference |
| --- | --- | --- | --- |
| 2700 | 1.0000, 0.6765, 0.3479 | 1.0000, 0.6726, 0.3519 | 0.0040 |
| 6500 | 1.0000, 1.0000, 1.0000 | 1.0000, 1.0000, 1.0000 | 0 |
| 10000 | 0.7899, 0.8649, 1.0000 | 0.7851, 0.8617, 1.0000 | 0.0048 |

wlsunset clamps below 1667 K and the table goes to 1000 K, so the two are not compared below 1667 K.

**Ramp words, 2700 K** (`src/linux_wlr_test.c3`, red/green/blue at index 255, then index 128; within one word):
brightness 1.0: 65535, 44332, 22798 and 32896, 22253, 11443; brightness 0.5: 32768, 22166, 11399 and 16448,
11126, 5722. These are the table multipliers times brightness, times 65535, rounded.

**Sunrise and sunset, C3 output** (`day_events`, UTC, 2026-03-20; the code's own result):

| City | C3 rise | C3 set | Published (sunrise-sunset.org) | Difference (rise / set) | astral 3.2 (rise / set) |
| --- | --- | --- | --- | --- | --- |
| London | 06:02:47 | 18:13:05 | 06:01:06 / 18:14:49 | +1:41 / -1:44 | 06:03:39 / 18:13:14 |
| New York | 10:58:51 | 23:07:55 | 10:57:28 / 23:09:21 | +1:23 / -1:26 | 10:59:30 / 23:07:57 |
| Sydney | 19:58:09 (on 19 March) | 08:07:17 | 19:56:52 / 08:08:36 | +1:17 / -1:19 | sunset 08:06:43 |

The published service runs about 1.5 minutes longer per event than both NOAA and astral; its refraction
model is not stated. Tests use 3 minutes against the published values and 90 seconds against astral.
NOAA's `calcSunriseSetUTC` is algebraically the same as `noon - 4*ha`. Solar noon is refined twice here
and once in NOAA's `calcSolNoon`; the difference is seconds.

## 5. Honest verification record

Run here (Linux x86-64, c3 0.8.5):
- `timeout 600 ./testrun --test-filter bleu::color`: 23 passed, 0 failed; repeated 40 times, no failure, no hang.
- Mock compositor, in-process, via `bleu::wl::testing::MockServer`: full exchange (acquire, write, dim,
  release, reacquire, release at close), refusal at open (BUSY; control destroyed), control lost after a
  write (released, reported, retried, recovered).
- A deliberate wrong expected word made the run fail (checked, then restored).
- Leak check: the test runner's leak detector reported three leaks in the first version (the displays
  array, the ramp words, the name copies); fixed; the runs are clean.
- `tools/check.sh bleu_core bleu_rt bleu_service bleu_wl bleu_color`: clean on all six targets.
- `c3fmt --check` clean.

Not run:
- A real wlroots compositor. The mock is the protocol as the client sees it, not a compositor's behaviour.
- Windows and macOS: compiled only. Nothing has written a ramp to a display on either.
- `set_schedule` through the service on a running clock (the schedule maths is tested; the engine path with
  a live clock is not).

## 6. Shared-library problems found (for the lead)

1. **`bleu_wl` tests are flaky.** `bleu::wl::client_test::registry_lists_globals_and_removals` failed
   intermittently with "the freed callback id was not reused" (`client_test.c3:24`). In 25 full-suite runs,
   `bleu::wl::client_test::selected_offer_is_received_through_a_pipe` hung twice. Because `compile-test` runs
   every linked library's tests, any library that depends on `bleu_wl` hangs or fails intermittently
   unless the run is filtered (`--test-filter`). Not fixed here: `bleu_wl` is read-only for this task.
2. **`bleu_wl` generated protocol text.** `src/proto/wlr_gamma_control.c3` (and the XML it is generated
   from) says "16-byte unsigned integers". The length rule makes it 16-bit words. The text is
   generated, so the fix belongs in the protocol description the generator reads.
3. **`bleu_core` availability has no "held elsewhere" reason.** `Reason` has no value for a resource
   another client holds. This library reports it as `refused` plus `UNSUPPORTED_BACKEND` with a note.
   A `HELD_ELSEWHERE` reason would be more honest. Optional.
4. **`bleu_brightness` GAMMA** (not edited, per instruction): its GAMMA mechanism has no backend. The shape
   for one is in `libs/bleu_color.c3l/README.md`.

## 7. C3 gotchas found while building this (for `docs/C3_GOTCHAS.md`, not edited here)

- `Kelvin` (a `typedef` of `int` in `bleu::unit`) needs casts for every literal and for `==` against one;
  `(Kelvin)6500`. `Duration` and `Time` likewise.
- `foreach (x : slice)` copies `x`; a write through `x` is lost. Use `foreach (&x : slice)`, and then `x` is
  already a pointer (`&x` is a double pointer).
- `catch` is only valid in `if`/`while` conditions: `!(catch f())` and `catch f() && ...` do not compile.
- `if (catch err = r) { ... } else { use(r) }` works for an optional `r`, but `r` must be unwrapped to pass it.
- `alloc::new_array(allocator, T, n)` takes `sz`; a `usz` length must be cast.
- A function's `@return?` contract on a `void` function is accepted but meaningless: remove it.
- `c3c compile-test --test-filter <prefix>` runs only the matching tests; the binary takes no filter argument of its own.
