# bleu_brightness: implementation notes

Spec: `docs/research/display.md`, brightness parts (sections 2.1 to 2.3, 2.2 (macOS), 5 and 6).
Scope and status: `libs/bleu_brightness.c3l/README.md`.

## Deviations from the research note

- Model: the research draft's `Control` had `has_level`/`writable` as loose fields and a `Mechanism` list without NATIVE. The shipped `Control` uses `Maybe{Level}` and `Maybe{long}`, and `Mechanism` is `BACKLIGHT, NATIVE, DDC, GAMMA, OVERLAY, KEYBOARD_LED` as the brief specifies. The research's `DisplayBrightness` became `Device` with a `DeviceKind` (PANEL, EXTERNAL, KEYBOARD) so the keyboard backlight is addressed the same way.
- Keyboard backlight is a device of kind KEYBOARD, not a separate State field.
- Mechanism of a Windows panel is BACKLIGHT (the IOCTL on the panel), of dxva2 monitors DDC. The research's `OS_NATIVE` became `NATIVE` (macOS DisplayServices only).
- Unimplemented mechanisms (GAMMA, OVERLAY on Linux) are not listed as controls in State; they are reported by `capability()` only. A device does not expose a control the platform cannot drive.
- Policy semantics: PREFER_HARDWARE uses software only when no hardware control is writable (the result says so in `Applied.mechanism`); ALLOW_SOFTWARE also moves on after a hardware write fails; EXACT never moves. The research did not define these; the brief asked for the three names.
- Smooth transitions are a service feature run by the shared engine (`engine.c3`): each step re-runs the same policy against the last state. Under PREFER_HARDWARE or EXACT a failing step fails the request; under ALLOW_SOFTWARE a failing step may continue on software, which the final `Applied.mechanism` reports.
- DDC write does not verify the monitor's value before returning; it reads it back once. A ramp step on DDC therefore costs one write and one read (about 100 ms on the spec timings). `DEFAULT_TRANSITION_STEP` is 100 ms for that reason.

## Verified against sources (where the research said single-source, this build keeps it single-source)

- logind `SetBrightness(ssu)` signature and the `session/auto` object: cited in `linux_logind.c3` (systemd `logind-session-dbus.c` lines 671-720 and 1085, as in the research). The integration test calls it through a dbus-next stand-in written to that signature, so the wire call is run; logind's own acceptance rules are not.
- sysfs backlight type ranking: kernel `sysfs-class-backlight` (research B1). Covered by `sysfs_test.c3`.
- I2C constants (`I2C_SLAVE` 0x0703, `O_CLOEXEC` 0x80000, `LOCK_EX`/`LOCK_NB` 2/4, `POLLIN` 1, errno values): checked against the Linux headers as cited in the file comments.
- DisplayServices symbols and signatures: Lunar bridging header as recorded in the research (B14, two sources). Not run.
- dxva2 declarations: MGW headers as recorded in the research (B29, B30, two sources). Not run.
- `DISPLAY_BRIGHTNESS` layout and IOCTL codes: MGW `ntddvdeo.h` (B27, single-source per the research). The AC byte as a percentage is UNVERIFIED (B28 was not read).

## C3 notes

Recorded in `docs/C3_GOTCHAS.md` (the lines starting "Parameters may not be optional" onward).
