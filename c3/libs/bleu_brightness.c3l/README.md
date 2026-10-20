# bleu_brightness

The brightness service: every light a shell can move (panel backlight, OS-native
panel call, DDC/CI on external monitors, keyboard backlight, gamma dimming), each
reported as its own control with its own level, raw value and range. Requests
name a device and a `Policy`, so a software dimming never silently stands in for a
requested hardware change. Module root `bleu::brightness`. Design: ARCHITECTURE.md;
the research and the cut: `docs/research/display.md` (brightness parts);
implementation notes: `docs/research/brightness_impl.md`.

## Public API

- `open(allocator, Options) -> Brightness*?` (`backend`, `poll`, `transition_step`, `root`, `bus_address`, `open_bus`).
- `Brightness.latest()`, `wait_after(seen, timeout)`, `watch`/`unwatch`: `Snapshot{State}`.
- `State` -> `Device[]` (`id`, `name`, `kind`: PANEL/EXTERNAL/KEYBOARD) -> `Control[]` (`mechanism`, `readable`, `writable`, `availability`, `level`, `raw`, `raw_min`, `raw_max`).
- `set_level(device, Level, Policy = DEFAULT_POLICY, Duration transition = 0) -> SetOperation*?`
  (`SetOperation = Operation{Applied}`; `Applied`: `mechanism`, `requested`, `applied`, `raw`, `read_back`).
- `Policy`: `prefer_hardware()`, `allow_software()`, `exact(Mechanism)`.
- `Mechanism`: BACKLIGHT, NATIVE, DDC, GAMMA, OVERLAY, KEYBOARD_LED.
- `capability(Cap)`: `SET_BACKLIGHT`, `SET_NATIVE`, `SET_DDC`, `SET_GAMMA`, `SET_OVERLAY`, `SET_KEYBOARD_LED`, `TRANSITION`.
- `subscribe()`: `Event` (`LEVEL_CHANGED`, `DEVICE_ADDED`, `DEVICE_REMOVED`).
- `refresh()`, `backend_name()`, `close()`.

## Coverage (capability x OS -> status)

Run = executed on Linux against fakes (fake sysfs/DRM root, `bleu::ddc::mock`,
private dbus-daemon with a dbus-next logind stand-in). Compiled-only = type-checked
for the named target by `c3c compile-only`; never executed. Not done = not built.

| Capability / mechanism | Linux | Windows | macOS |
| --- | --- | --- | --- |
| BACKLIGHT, panel (sysfs read; write via logind, else sysfs) | Run | Compiled-only (`\\.\LCD` IOCTL) | - |
| BACKLIGHT, backlight type priority firmware > platform > raw | Run | - | - |
| NATIVE (DisplayServices, private, dl at run time) | - | - | Compiled-only |
| DDC (VCP 0x10; i2c-dev / DRM mapping / mock) | Run against mock | Compiled-only (dxva2) | Not done (deferred) |
| KEYBOARD_LED (`*kbd_backlight`, logind `leds`) | Run | Not done | Not done |
| Policies (PREFER_HARDWARE, ALLOW_SOFTWARE, EXACT) | Run | Compiled-only | Compiled-only |
| Refusals (`UNSUPPORTED`, `PERMISSION_DENIED`, `NOT_FOUND`) | Run | - | - |
| TRANSITION (smooth ramp, cancel on new request) | Run | Compiled-only | Compiled-only |
| LEVEL_CHANGED / DEVICE_* events | Run (in-process) | Compiled-only | Compiled-only |
| GAMMA (software ramp) | Not done (needs `bleu_wl` or RandR) | Not done | Not done |
| OVERLAY | Not done | Not done | Not done |
| Change notification from the OS (keys) | poll only | poll only | poll only |

## Not done

- GAMMA on every OS: Linux needs wlr-gamma-control (`bleu_wl`) or RandR; Windows (`SetDeviceGammaRamp`) and macOS (`CGSetDisplayTransferByTable`) are not written.
- OVERLAY dimming (the enum value exists; reported `UNSUPPORTED_BACKEND`).
- macOS DDC/CI (IOAVService, IOFramebuffer I2C): deferred by the research cut.
- macOS DisplayServices change notification: its callback semantics are UNVERIFIED in the research; the poll covers changes instead. The run-loop thread that only enqueues is not written.
- Keyboard backlight on Windows and macOS; WMI brightness; nits; EDR; ambient-light toggle.
- Brightness-key events as key presses (`KEY_PRESSED`): key changes arrive as `LEVEL_CHANGED` from the poll.
- Windows: only `\\.\LCD` is opened, not every display from `EnumDisplayDevices`. The AC byte is taken as a percentage and `VIDEO_SUPPORTED_BRIGHTNESS` is not read (both UNVERIFIED).
- Linux DDC: the real `/dev/i2c-N` transport and its `flock` retry are not exercised; every DDC test uses the mock. Linux DDC writes use the luminance maximum from the last read.
- logind: tested against a stand-in, not a real logind. Foreground-session and seat rules are not exercised.
- Writes to a read-only backlight file while running as root succeed: `access(2)` reports writable for root.

## Verified how

- `c3c compile-test` on Linux: 139 `@test` functions pass, counting the dependencies' tests (pure policy, ramp and level arithmetic; sysfs/DRM naming; engine with an in-memory platform, including transitions, cancellation and events; fake-root service tests; DDC against `bleu::ddc::mock`).
- `libs/bleu_brightness.c3l/tests/run.sh`: runs the above, then the logind route twice (stand-in implementing `SetBrightness`, and one that does not). Output: `ALL PASSED`.
- `c3c compile-only` for `linux-x64`, `linux-aarch64`, `macos-x64`, `macos-aarch64`, `windows-x64`, `windows-aarch64`: clean.
- `c3fmt --check` clean.
- Note: `bleu_dbus` is a dependency for every target. Its README is now present; during this work its server sources were mid-edit by another agent, so the Windows and macOS checks were also run against the committed `bleu_dbus` (both pass).
