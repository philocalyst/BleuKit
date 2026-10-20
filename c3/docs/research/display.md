# Research spike: brightness, display, color (service spike)

Date of research: 2026-10-20. Scope: three services, `brightness`, `display`
and `color` (dark mode excluded). The DDC/CI wire protocol is out of scope
(`libs/bleu_ddc.c3l`); this file covers how each OS reaches the monitor.

Conventions. `[K-*] [L-*] [WL-*] [KDE-*] [MUT] [MSW-*] [MGW] [LUN-*] [MC-*]`
and the other short keys are defined in section 4 with full URLs. Line
numbers refer to the URL named by the key. "Read" means the file was read
in the relevant part; "grep" means only targeted matches were inspected.
Anything not confirmed in a fetched source is marked `(UNVERIFIED)`, and a
claim that rests on one source is marked `(single-source)`.

Unreachable in this run: all Apple `developer.apple.com` documentation pages
(JavaScript-rendered; no text), the Apple SDK header mirror (404), m1ddc and
ddcctl (404 on the expected paths), `ddcci-driver-linux` (404), systemd
`90-backlight.rules` (404 on every path tried), ddcutil's docs and udev rule
file (404), Hyprland, Quickshell, Astal, Twinkle Tray, Monitorian, and the
Wine copy of `dxva2api.h` (404). Those items are left open below.

## 1. What a shell needs

Priority order (P0 required for V1, P1 V1 if cheap, P2 later):

1. P0 `brightness`: per display, list every mechanism that controls it
   (panel backlight, OS-native, DDC/CI, gamma dimming, overlay dimming), each
   with its own availability and its own normalised level. Never merge them.
2. P0 `brightness`: change notifications, including changes made by the
   hardware keys or by another client.
3. P0 `display`: output list with identity (name, make, model, serial, EDID
   where exposed), connection kind, enabled state, current mode, mode list
   with fractional refresh rates, position, scale, transform, primary.
4. P0 `display`: hotplug events; re-enumerate after each.
5. P0 `display`: atomic apply of a configuration, with validate (dry run) and
   revert to the last known good configuration.
6. P0 `color`: gamma control and colour temperature in kelvin (night light),
   and the ICC profile name where exposed.
7. P1 `brightness`: keyboard backlight level and its keys.
8. P1 `brightness`: smooth transitions (client-side ramp or OS delta).
9. P1 `display`: HDR, VRR, colour depth, and wide-gamut flags (read first,
   set later).
10. P1 `brightness`: EDR/XDR headroom where exposed.
11. P2 `brightness`: nits estimate (read-only), ambient-light auto-brightness
    toggle.
12. P2 `color`: Night Shift / night-light scheduling on platforms with private
    routes only.

## 2. Per-platform native route (Linux / macOS / Windows)

### 2.1 brightness, Linux

Ranked routes per mechanism.

**(a) Panel backlight, read.** `/sys/class/backlight/<name>/`:
`brightness` (setpoint), `actual_brightness` (hardware read-back),
`max_brightness`, `type` (`firmware`, `platform`, `raw`) [K-BL]. The kernel
says to prefer `firmware` over `platform` over `raw` when several interfaces
exist for one device [K-BL, `type` entry]. The enum order is RAW=1,
PLATFORM, FIRMWARE [K-BLT, `enum backlight_type`]. The `brightness`
file may differ from the panel, so use `actual_brightness` for the effective
state and `brightness` for the setpoint [K-BL]. `brightness` crate reads
`actual_brightness` and `max_brightness` [DKG `src/blocking/linux.rs`
`Value::Actual`, `Value::Max`].

**(b) Panel backlight, write without root (preferred).**
logind `SetBrightness`:
```
bus:        system
service:    org.freedesktop.login1
object:     /org/freedesktop/login1/session/auto   (the caller's own session)
interface:  org.freedesktop.login1.Session
method:     SetBrightness(in s subsystem, in s name, in u brightness)
subsystem:  "backlight" | "leds"
```
[L-MAN, `SetBrightness()` text; signature in `logind-session-dbus.c` line 1085
(`SD_BUS_ARGS("s", subsystem, "s", name, "u", brightness)`)].
Access rules, verified in code [L-SBD 671-720]:
* No polkit check. The call is refused unless the session is on a seat, that
  seat's active session is this session ("Session is not in foreground"), the
  caller's euid is 0 or the session owner's uid, and the device's seat
  matches the session's seat.
* Subsystem must be `backlight` or `leds`; the device name must be a valid
  filename.
* The write is done by a forked child. Requests for one device are
  coalesced: the newest value wins, and every waiting caller gets the reply
  when the write finishes [L-SBW, comment at lines 19-33 and
  `manager_write_brightness`]. Write latency can be large (comment: "often
  being I2C and such").
Sequence:
1. Enumerate `/sys/class/backlight/*`, pick one (see section 5 for the
   selection rule), read `max_brightness` and `actual_brightness`.
2. Compute the raw value `round(level * max_brightness)`.
3. Call `SetBrightness("backlight", name, raw)` and await the reply.
4. On `org.freedesktop.DBus.Error.UnknownMethod` (older systemd), fall back
   to writing `brightness` directly, as `brightness` crate does [DKG
   `src/blocking/linux.rs` `MethodError` arm, comment lines 55-60]
   (single-source for the fallback rule).
Permissions: the sysfs file mode is set by udev rules that are not
verified here (`(UNVERIFIED)`: systemd `90-backlight.rules`). The logind route
needs no group membership.

**(c) Keyboard backlight.** `/sys/class/leds/<name>` where the name ends in
`::kbd_backlight` (examples in the kernel doc: `input5::kbd_backlight`, or the
bare `:kbd_backlight`) [K-LEDS, lines 92-94]. Write with
`SetBrightness("leds", name, raw)` [L-MAN; L-SBD lines 686-687 allow `leds`].
Max from `max_brightness` as for panels.

**(d) Hardware brightness keys (events).** Linux input codes:
`KEY_BRIGHTNESSDOWN` 224, `KEY_BRIGHTNESSUP` 225, `KEY_KBDILLUMTOGGLE` 228,
`KEY_KBDILLUMDOWN` 229, `KEY_KBDILLUMUP` 230, `KEY_BRIGHTNESS_CYCLE` 243,
`KEY_BRIGHTNESS_AUTO` 244 (ambient auto toggle), `KEY_BRIGHTNESS_MIN` 0x250,
`KEY_BRIGHTNESS_MAX` 0x251 [K-KEY, lines 303-332, 631-632]. Which process
consumes these events is compositor-specific and not verified here
(`(UNVERIFIED)`). A shell that wants to show its own HUD must read them from
the compositor, not from sysfs.

**(e) External monitors, DDC/CI through i2c-dev.**
1. Map the DRM connector to its I2C bus. The connector directory
   `/sys/class/drm/card<N>-<CONNECTOR>/` has a `ddc` symlink to the I2C adapter
   device when the connector has a DDC bus [K-DRMSYS lines 394-396, creates
   `ddc` link from `connector->ddc`]. Then resolve the bus number from the
   symlink target or from `/sys/class/i2c-dev/`.
2. Open `/dev/i2c-<N>` with `O_RDWR` (`O_CLOEXEC` recommended). DMS takes an
   `flock(LOCK_EX|LOCK_NB)` on the fd with a bounded retry [DMS `ddc.go`
   `openDDCBus`], so other tools serialise.
3. `ioctl(fd, I2C_SLAVE, 0x37)`. `I2C_SLAVE` is `0x0703` [K-I2CUAPI line 28].
   `I2C_RDWR` is `0x0707` (combined transfer) [K-I2CUAPI line 35]. Slave
   `0x37` is DDC/CI, `0x50` is EDID (`DDC_ADDR`) [K-EDID line 39; `0x37` in
   MC-ARM line 6 and DMS `ddc.go` line 19]. `0x52` is E-DDC segment
   (`DDC_ADDR2`).
4. Before probing, DMS skips buses with no connected DRM connector and
   buses whose display is asleep (`ddcBusVerdictFor`, `ddcDisplayAsleep`)
   [DMS `ddc.go` lines 105-118]. Re-scan when the bus number is reused by
   another adapter [DMS `ddc.go` lines 99-106].
5. The i2c-dev module must be loaded (`modprobe i2c-dev`) [K-I2C lines 7-10].
   Permissions on `/dev/i2c-N` (group `i2c` in ddcutil's documentation) are
   `(UNVERIFIED)`: the ddcutil docs and rule file were unreachable.
Alternatives: the out-of-tree `ddcci-backlight` kernel driver exposes
external monitors as a backlight class device, which then works with routes
(a) and (b) (`(single-source)`: only the brightness fork's `PLATFORMS.md`;
`ddcci-driver-linux` was unreachable).

**(f) Gamma dimming.** See 2.7 (colour). Gamma is a separate mechanism from
backlight; report it as `GAMMA_TABLE`.

**(g) Compositor-owned backlight.**
* Mutter: property `Backlight` `(uaa{sv})` on `org.gnome.Mutter.DisplayConfig`
  gives per-connector dictionaries with `connector`, `active`, `min`, `max`,
  `value`, plus a serial. Write with `SetBacklight(u serial, s connector, i value)`.
  `ChangeBacklight` is deprecated [MUT lines 212-249]. Values are raw integers
  between `min` and `max` (no percent).
* KDE: `kde-output-device-v2` event `brightness` (since v8, `uint 0-10000`)
  reports the multiplier, and `auto_brightness` (event since v20, flag since
  v19) reports the ALS toggle [KDE-D lines 426-447, 537-555]. Writes:
  `kde_output_configuration_v2.set_brightness` (since v9, `uint 0-10000`),
  `set_dimming` (since v11, temporary, `uint 0-10000`, supported only with
  brightness support), `set_auto_brightness` (since v19), and
  `set_brightness_overrides` (since v7, `int` nits, `-1` = no override, minimum
  in units of 0.0001 nits) [KDE-M lines 281-286, 311-336, 343-365, 433-437].
  These are applied through the normal configuration `apply`.
* RandR: an output property named `Backlight` is the usual X11 route
  `(UNVERIFIED)`: the xserver and amdgpu sources fetched did not show the
  atom.

**Normalisation (Linux).** Panel: `level = raw / max_brightness`. Mutter:
`level = (value - min) / (max - min)`. KDE: `level = value / 10000`. Keyboard:
`raw / max_brightness` of the LED.

### 2.2 brightness, macOS

Routes are ranked per display type. Every symbol below is private unless
marked public, and must be resolved at runtime (ARCHITECTURE rule). Symbol
names are from the Lunar bridging header [LUN-BH] unless noted.

**(a) Built-in panels: DisplayServices (preferred).**
```
int  DisplayServicesGetBrightness(CGDirectDisplayID, float *out);   // 0..1
int  DisplayServicesSetBrightness(CGDirectDisplayID, float);        // 0..1
int  DisplayServicesGetLinearBrightness(CGDirectDisplayID, float *out);
int  DisplayServicesSetLinearBrightness(CGDirectDisplayID, float);
int  DisplayServicesSetBrightnessSmooth(CGDirectDisplayID, float delta);
bool DisplayServicesCanChangeBrightness(CGDirectDisplayID);
int  DisplayServicesRegisterForBrightnessChangeNotifications(
        CGDirectDisplayID, CGDirectDisplayID observer, CFNotificationCallback);
int  DisplayServicesEnableAmbientLightCompensation(CGDirectDisplayID, bool);
int  DisplayServicesHasAmbientLightCompensation(CGDirectDisplayID) -> bool;
int  DisplayServicesGetLinearBrightnessUsableRange(CGDirectDisplayID, int *min, int *max);
```
Source: [LUN-BH lines 49-75]. `DisplayServicesGetBrightness` and
`DisplayServicesSetBrightness` are also used by [NRB lines 124-167].
`DisplayServicesSetBrightnessSmooth` takes a delta (target minus current),
[LUN-ANC line 286].
Sequence (Lunar, `AppleNativeControl`):
1. Availability: `CanChangeBrightness(id)` is true, and the control is
   enabled [LUN-ANC lines 45-58, `canChangeBrightnessDS`].
2. Read: `GetBrightness(id, &f)` [LUN-ANC lines 60-62]; the `KERN_SUCCESS`
   checks are in `testReadAndWrite` [LUN-ANC lines 95-109].
3. Write: `SetBrightness(id, br)` where `br = percent / 100` as a float.
   If `br == 1.0`, Lunar also calls `SetLinearBrightness(id, 1.0)`
   [LUN-ANC lines 147-149]. This "double-set on 1.0" is observed in code
   only (`(single-source)`).
4. Smooth: `SetBrightnessSmooth(id, target - current)`, then
   `SetBrightness(id, target)` (and linear at 1.0) [LUN-ANC lines 283-296].
   Or stepwise: step 0.002 per write, interval 0.004 s (smooth) or 0.025 s
   (other), using `SetBrightness` only [LUN-ANC lines 309-332] (single-source).
5. Notifications: `RegisterForBrightnessChangeNotifications(display,
   observer, callback)` [LUN-BH line 71]. Callback semantics and the
   `DisplayServicesBrightnessChangeNotificationImmediate` call [LUN-BH line 56]
   are not verified (`(UNVERIFIED)`).
Nits estimate: `nits = maxNits * GetLinearBrightness(id)` [LUN-ANC lines
217-221] (`(single-source)`, the value of `maxNits` is the user's panel
figure).
Legacy path (older Macs): `IODisplaySetFloatParameter(service, 0,
kIODisplayBrightnessKey, value)` with `CFSTR(kIODisplayBrightnessKey)` [NRB
lines 54, 150-151]; read with `IODisplayGetFloatParameter` [NRB line 187].
The service is found with `IOServiceGetMatchingServices` on the
`IODisplayConnect` class [NRB lines 86-95]. NRB says `CGDisplayIOServicePort`
is deprecated since 10.9 (comment at line 86) (`(single-source)`).
CoreDisplay (private): `CoreDisplay_Display_GetUserBrightness`,
`CoreDisplay_Display_SetUserBrightness` (`double` 0..1), `..._GetLinearBrightness`,
`..._SetLinearBrightness`, `..._GetDynamicLinearBrightness`,
`..._SetDynamicLinearBrightness` [LUN-BH lines 37-43]. Lunar prefers
CoreDisplay for the first write probe and then DisplayServices
[LUN-ANC lines 70-115] (the exact preference is in `testReadAndWrite`).
Lunar also exposes `CoreDisplay_Display_SetAutoBrightnessIsEnabled(id, bool)`
[LUN-BH line 45] (`(UNVERIFIED)` semantics).
Permissions: none observed for these calls in the code read. No TCC prompt
is involved. (`(UNVERIFIED)` for hardened-runtime and notarisation limits.)

**(b) External monitors, DDC/CI.**
* Apple Silicon: `IOAVService`. Find `DCPAVServiceProxy` registry nodes
  whose `Location` property equals `"External"`, call
  `IOAVServiceCreateWithService(kCFAllocatorDefault, entry)`, and match the
  service to a `CGDirectDisplayID` by `EDID UUID`, `IODisplayLocation`,
  product name, and serial [MC-ARM lines 223-231; DDCM-ARM `src/arm.rs`
  `get_display_av_service`, lines 60-104]. Match score with a claimed-location
  set so each service serves one display [MC-ARM lines 42-66].
  I/O: `IOAVServiceWriteI2C(service, chip, offset, buf, len)` and
  `IOAVServiceReadI2C(service, chip, 0, buf, len)` [MC-ARM lines 92-110;
  DDCM-ARM lines 152-170]. `chip` is `0x37` [MC-ARM line 6]. `offset` is
  `0x51` for DDC/CI data [MC-ARM line 7]. Timing used by MonitorControl:
  10 ms before write, 50 ms before read, 20 ms retry sleep [MC-ARM lines
  102-114] (defaults in that code, not spec values). Chip address `0xB7` is
  used on M1 built-in HDMI behind an MDCP29xx bridge [DDCM-ARM
  `i2c_address`, constant `I2C_ADDRESS_DDC_CI_MDCP29XX`] (`(single-source)`).
  The link is `CoreDisplay.framework` [DDCM-ARM lines 152-154].
* Intel: `IOFramebuffer` + `IOFBGetI2CInterfaceCount`,
  `IOFBCopyI2CInterfaceForBus`, `IOI2CInterfaceOpen`, `IOI2CSendRequest`
  with `IOI2CRequest` [DDCM-ARM `src/intel.rs`, `src/iokit/io2c_interface.rs`
  lines 14-18, 54-68; LUN-DDC lines 217, 277-292]. Transaction types:
  `kIOI2CNoTransactionType` 0, `kIOI2CSimpleTransactionType` 1,
  `kIOI2CDDCciReplyTransactionType` 2, `kIOI2CCombinedTransactionType` 3,
  `kIOI2CDisplayPortNativeTransactionType` 4 [DDCM-ARM
  `iokit/io2c_interface.rs` lines 14-18]. The reply type is chosen from the
  framebuffer's `IOI2CTransactionTypes` bitmask (DDCci preferred, then simple)
  [DDCM-ARM `intel.rs` `get_supported_transaction_type`; LUN-DDC lines 458-494].
  Framebuffer ↔ display matching is by EDID / `IODisplayCreateInfoDictionary`
  [DDCM-ARM `intel.rs` lines 2, 59, 93-129].
* Other macOS DDC references (m1ddc, ddcctl) were not reachable.

**(c) Software, dimming.**
* Gamma: `CGSetDisplayTransferByTable` [LUN-GAM line 385] with the table
  scaled by the brightness factor, mapped from `0.00..max` to `0.08..max`
  [LUN-DISP lines 398-403] (the floor of 0.08 is Lunar's choice).
* Overlay: Lunar switches `dimmingMode` to `.overlay` when `useOverlay` is set
  [LUN-DISP lines 3097-3103, 3242]. The window level and alpha range
  (`.hud`, 0.01…0.85) cited in the task are not in the files read
  (`(UNVERIFIED)`).

**Control selection (Lunar).** `getBestControl()` in [LUN-DISP lines
5152-5200] tries, in order: `AppleNativeControl` (if `appleNativeEnabled` and
`isAvailable()`), then `DDCControl` (if not built-in, `supportsGammaByDefault`
or fake dummy, and `ddcEnabled`, and available), then `NetworkControl`
(if not built-in and `networkEnabled`), then gamma/software fallback (not
read). The enum declaration order is `network, appleNative, ddc, gamma,
ddcctl` [LUN-CTL lines 29-34], which is not the selection order. Do not copy
the `supportsGammaByDefault` gate blindly. It is a Lunar-specific condition.

**(d) Keyboard backlight (private).** Lunar imports `KeyboardBrightnessClient.h`
[LUN-BH line 9] (`KeyboardBrightnessClient` is the CoreBrightness client). Its
selectors are `(UNVERIFIED)`; the header was not fetched.

**(e) Ambient light.** `DisplayServicesHasAmbientLightCompensation` and
`DisplayServicesEnableAmbientLightCompensation` [LUN-BH lines 64-66] are the
Lunar-visible names. The `AppleLMUController` sensor route cited in the task
is `(UNVERIFIED)`.

**(f) Keyboard-key interception.** A session event tap on brightness keys,
requiring Accessibility trust, is described in the brightness fork's docs
[BRF `PLATFORMS.md`, "Replacing brightness keys and HUD"]. Not verified
against Apple docs or code (`(single-source)`).

### 2.3 brightness, Windows

Routes ranked per display type.

**(a) Internal (laptop) panel: IOCTL on the display device.**
1. Enumerate display devices with `EnumDisplayDevicesW` (active only), then
   open each `DISPLAY_DEVICEW.DeviceID` (DOS device path, with
   `EDD_GET_DEVICE_INTERFACE_NAME`) by `CreateFileW(path, GENERIC_READ |
   GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0,
   NULL)` [DKG `src/blocking/windows.rs`, `get_file_handle_for_display_device`,
   the `ERROR_ACCESS_DENIED` case is a virtual display (for example
   Remote Desktop) and is skipped].
2. The panel is internal when `DISPLAYCONFIG_TARGET_DEVICE_NAME.outputTechnology`
   equals `DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INTERNAL` = `0x80000000` [MGW
   `wingdi.h` line 2099; DKG `is_internal`].
3. Get: `DeviceIoControl(h, IOCTL_VIDEO_QUERY_DISPLAY_BRIGHTNESS, NULL, 0,
   &DISPLAY_BRIGHTNESS, sizeof, ...)`.
   Set: query `IOCTL_VIDEO_QUERY_SUPPORTED_BRIGHTNESS`, choose the supported
   level nearest to the request, then `DeviceIoControl(h,
   IOCTL_VIDEO_SET_DISPLAY_BRIGHTNESS, &DISPLAY_BRIGHTNESS, ...)` [DKG
   `ioctl_set_display_brightness` path, `supported.get_nearest(...)`].
   Layout [MGW `ntddvdeo.h` lines 477-481]:
   ```
   typedef struct _DISPLAY_BRIGHTNESS {
       UCHAR ucDisplayPolicy;   // policy selector
       UCHAR ucACBrightness;    // AC (plugged in) level
       UCHAR ucDCBrightness;    // DC (battery) level
   } DISPLAY_BRIGHTNESS;
   ```
   IOCTL function codes [MGW `ntddvdeo.h` lines 185-191]:
   `IOCTL_VIDEO_QUERY_SUPPORTED_BRIGHTNESS` = `CTL_CODE(FILE_DEVICE_VIDEO,
   0x125, METHOD_BUFFERED, FILE_ANY_ACCESS)`, `IOCTL_VIDEO_QUERY_DISPLAY_BRIGHTNESS`
   = `0x126`, `IOCTL_VIDEO_SET_DISPLAY_BRIGHTNESS` = `0x127`. The
   `VIDEO_SUPPORTED_BRIGHTNESS` layout is `(UNVERIFIED)`: it was not read.
   The brightness fork says drivers vary and this path is hardware-qualified
   only on some panels (`(single-source)`).
   Normalisation: `level = ucACBrightness / 100` only if the driver reports
   a percentage. This is `(UNVERIFIED)`; check on hardware.
(WMI route, `root\wmi` `WmiMonitorBrightness` / `WmiMonitorBrightnessMethods`
`WmiSetBrightness`): the task cites it, but the reference crate does not use
it and its Learn page was not retrieved (`(UNVERIFIED)`).

**(b) External monitors: dxva2 high-level then low-level.**
1. Per `HMONITOR` (from `EnumDisplayMonitors` / `GetMonitorInfoW`):
   `GetNumberOfPhysicalMonitorsFromHMONITOR(hmon, &n)`, then
   `GetPhysicalMonitorsFromHMONITOR(hmon, n, arr)`; release with
   `DestroyPhysicalMonitor(s)` [MGW `physicalmonitorenumerationapi.h` lines
   32-36; DKG `get_physical_monitors_from_hmonitor`].
2. Get: `GetMonitorBrightness(h, &min, &cur, &max)` [MGW
   `highlevelmonitorconfigurationapi.h` line 91; MSW-GMB "retrieves a
   monitor's minimum, maximum and current brightness settings"].
3. Set: `SetMonitorBrightness(h, DWORD new)` [MGW line 103]. The brightness
   crate maps a percent to the current range (`percentage_to_current`)
   [DKG `set`].
4. Low-level, for non-brightness VCP codes: `GetVCPFeatureAndVCPFeatureReply(h,
   code, &type, &cur, &max)`, `SetVCPFeature(h, code, value)`,
   `GetCapabilitiesStringLength` [MGW `lowlevelmonitorconfigurationapi.h` lines
   33-36]. Capability bit for brightness is `MC_CAPS_BRIGHTNESS` = `0x2`
   [MGW highlevel line 18] (from `GetMonitorCapabilities`, not read).
Pitfalls: handles may be non-DDC or belong to a virtual display; a count
mismatch between `GetPhysicalMonitorsFromHMONITOR` and `EnumDisplayDevicesW`
means a hotplug race (DKG `EnumerationMismatch`); retry at most a few times.

**(c) Power-policy brightness (not a setpoint).** GUIDs [MGW `winnt.h` lines
6336-6346]: `GUID_VIDEO_SUBGROUP` = `7516b95f-f776-4464-8c53-06167f40cc99`,
`GUID_DEVICE_POWER_POLICY_VIDEO_BRIGHTNESS` = `aded5e82-b909-4619-9949-f5d71dac0bcb`,
`GUID_VIDEO_ADAPTIVE_DISPLAY_BRIGHTNESS` = `fbd9aa66-9553-4097-ba44-ed6e9d65eab8`.
Note: the task's `GUID_VIDEO_BRIGHTNESS` name does not exist in these headers.
The `PowerWriteACValueIndex` function named in the task is not in the saved
`powrprof.h` copy (only `PowerReadACValueIndex`), so whether it writes the
current brightness is `(UNVERIFIED)`. Treat the power-scheme value as a
default, not as the live level.

**(d) Software.** `SetDeviceGammaRamp` / `GetDeviceGammaRamp` (see 2.9).

**Notifications.** `WM_DISPLAYCHANGE` is broadcast on mode changes [MSW-WDC].
Brightness-change notification for the internal panel is `(UNVERIFIED)`.

### 2.4 display, Linux

Ranked routes. Choose by what the compositor exposes.

**(a) Wayland, wlroots output management (widest support on wlroots
compositors: sway, Hyprland, niri-class wlroots builds).** Protocol
`zwlr_output_manager_v1` (version 4) [WL-OM lines 42-127]:
* Manager events: `head(new_id zwlr_output_head_v1)`, `done(serial uint)`.
  Requests: `create_configuration(new_id, serial)`, `stop`.
* Head (`zwlr_output_head_v1`) events: `name`, `description`, `physical_size`
  (`int` mm), `mode(new_id)`, `enabled(int)`, `current_mode(object)`,
  `position(x,y)`, `transform`, `scale(fixed)`, `make`, `model`,
  `serial_number` (since 2), `adaptive_sync(state)` (since 4), `finished`.
* Mode (`zwlr_output_mode_v1`): `size(w,h)`, `refresh(int mHz)` [WL-OM line
  392-397: "vertical refresh rate in mHz"], `preferred`, `finished`.
* Configuration (`zwlr_output_configuration_v1`): `enable_head(new_id,
  head)`, `disable_head(head)`, `apply`, `test`, then exactly one of
  `succeeded`, `failed`, `cancelled`, then `destroy`.
  Errors: `already_configured_head`, `unconfigured_head`, `already_used`.
* Configuration head (`zwlr_output_configuration_head_v1`): `set_mode(mode)`,
  `set_custom_mode(w, h, refresh mHz or 0)`, `set_position(x,y)`,
  `set_transform`, `set_scale(fixed)`, `set_adaptive_sync(state)`.
Sequence:
1. `wl_registry.bind` `zwlr_output_manager_v1`.
2. Wait for `done(serial)`; record serial.
3. `create_configuration(serial)`; for every head, `enable_head` +
   `set_mode` or `set_custom_mode`, `set_position`, `set_transform`,
   `set_scale`.
4. `test` → wait for `succeeded` or `failed`. If `cancelled`, the serial is
   stale (hotplug); restart from step 2.
5. `apply` → wait for `succeeded` / `failed` / `cancelled` (the protocol says
   the compositor may round scale). Then wait for `done` with the new serial.
6. `destroy` the configuration.
Revert: the protocol says that on `failed` the compositor reverts any changes
made by `apply` [WL-OM `failed` description]. Reverting a configuration that
succeeded is not in the protocol: the client must re-apply the previous
configuration (design; see section 5).
Not in this protocol: HDR, colour depth, wide gamut, VRR policy (only
`adaptive_sync`), mirroring (not a field; `(UNVERIFIED)` how a compositor
expresses it), backlight, gamma.

**(b) Wayland, `wl_output` and `xdg-output` (read-only, universal).**
`wl_output` events: `geometry(x, y, physical_width, physical_height, subpixel,
make, model, transform)`, `mode(flags, width, height, refresh mHz)`, `done`
(since 2), `scale(factor)` (since 2), `name` (since 4), `description`
(since 4) [WL-OUT lines 47-239]. `xdg-output` adds `logical_position`,
`logical_size`, `name`, `description` [WL-XO lines 100-218]. The
`display-info` crate reads `wl_output` only [DI `src/linux/wayland.rs`].

**(c) Wayland, KDE (`kde_output_device_registry_v2` / `kde_output_device_v2`
/ `kde_output_management_v2`).** Richest route in the fetched set [KDE-D,
KDE-M]:
* Registry: `output(new_id)` per device; `finished`; `stop`.
* Device events: `geometry`, `current_mode`, `mode`, `done`, `scale`, `edid`
  (base64 raw), `enabled`, `uuid`, `serial_number`, `eisa_id`, `capabilities`
  (bitmask: overscan 0x1, vrr 0x2, rgb_range 0x4, high_dynamic_range 0x8,
  wide_color_gamut 0x10, auto_rotate 0x20, icc_profile 0x40, brightness 0x80,
  built_in_color 0x100, ddc_ci 0x200, max_bits_per_color 0x400, edr 0x800,
  sharpness 0x1000, custom_modes 0x2000, auto_brightness 0x4000, hdr_icc_profile
  0x8000, abm_level 0x10000, disable 0x20000) [KDE-D lines 256-292], plus
  `vrr_policy`, `rgb_range`, `high_dynamic_range`, `sdr_brightness`,
  `icc_profile_path`, `brightness_metadata`, `brightness_overrides`,
  `sdr_gamut_wideness`, `color_profile_source`, `brightness`,
  `color_power_tradeoff`, `ddc_ci_allowed`, `max_bits_per_color`,
  `edr_policy`, `auto_brightness`, `hdr_icc_profile_path` [KDE-D lines 301-562].
* Management: `create_configuration`, `create_mode_list`; per-device requests
  `enable`, `mode`, `transform`, `position`, `scale`, `set_vrr_policy`,
  `set_rgb_range`, `set_primary_output` (since 2), `set_priority` (since 3),
  `set_high_dynamic_range` (since 4), `set_sdr_brightness` (since 4),
  `set_wide_color_gamut` (since 4), `set_auto_rotate_policy` (since 5),
  `set_icc_profile_path` (since 6), `set_brightness` (since 9),
  `set_color_power_tradeoff` (since 10), `set_dimming` (since 11),
  `set_ddc_ci_allowed` (since 14), `set_max_bits_per_color` (since 15),
  `set_edr_policy` (since 16), `set_auto_brightness` (since 19),
  `set_hdr_icc_profile_path` (since 20), `set_abm_level` (since 21) [KDE-M].
  `apply` → `applied` or `failed` (+ `failure_reason`, since 12). There is no
  `test` request in this protocol (`(single-source)` for that absence: read
  from the XML list).
* Mode list: `kde_mode_list_v2` with `add_mode`, `set_resolution`,
  `set_refresh_rate`, `set_reduced_blanking` [KDE-M lines 492-509].
Use this route only when KDE is the compositor; it is not portable.

**(d) Wayland, Mutter (`org.gnome.Mutter.DisplayConfig`, D-Bus, session bus,
object `/org/gnome/Mutter/DisplayConfig`) [MUT]:**
* `GetResources` (crtcs, outputs, modes) [line 133].
* `GetCurrentState` [line 475] returns `serial`, monitors, logical monitors,
  properties.
* `ApplyMonitorsConfig(u serial, u method, a(iiduba(ssa{sv})) logical_monitors,
  a{sv} properties)` [lines 527-531]. `method`: `0` verify, `1` temporary,
  `2` persistent [MUT lines 489-494]. Verify-then-apply is the test path.
* Signal `MonitorsChanged` [line 346] for hotplug.
* Properties: `PowerSaveMode` (`i`, read-write, line 315), `PanelOrientationManaged`,
  `ApplyMonitorsConfigAllowed` (line 330), `NightLightSupported` (line 337),
  `HasExternalMonitor` (line 553), `Backlight` (line 249).
* Monitor-level extras (in the properties of each monitor, lines 392-410):
  `color-mode` (u: `0` default, `1` BT.2100, `2` SDR native),
  `supported-color-modes`, `rgb-range`, `min-refresh-rate` (VRR floor),
  `is-for-lease`, a hardware-locked flag. Mode flags: `1` preferred, `2` current.
* `SetOutputCTM(serial, output, (ttttttttt) ctm)` [line 542], a 3×3 S31.32
  colour matrix.

**(e) wlr-output-power-management (display on/off, not brightness)
[WL-PM]:** `get_output_power(new_id, output)`; `set_mode(uint)` with `off` = 0
and `on` = 1; events `mode` and `failed` [WL-PM lines 68-108].

**(f) sway (IPC and config) [SWAY-OUT, SWAY-IPC].** Commands: `output <name>
mode|resolution|res <w>x<h>[@<rate>Hz] [--custom]`, `modeline`, `scale <f>`,
`transform`, `enable|disable`, `power on|off|toggle`, `adaptive_sync
on|off|toggle`, `render_bit_depth 6|8|10`, `max_render_time`, `scale_filter`
[SWAY-OUT]. IPC `GET_OUTPUTS` returns `name`, `make`, `model`, `serial`,
`active`, `dpms`, `power`, `scale`, `subpixel`, `transform`, the current
workspace [SWAY-IPC lines 187-235]. No brightness or gamma in sway's IPC.

**(g) niri (`niri-ipc` 26.4.0) [NIRI].** `Request::Outputs` returns
`HashMap<String, Output>` with `name`, `make`, `model`, `serial`,
`physical_size` (mm), `modes`, `current_mode`, `is_custom_mode`,
`vrr_supported`, `vrr_enabled`, `logical` [lines 67-71, 1204-1230]. Actions
include `Mode`, `CustomMode`, `Scale`, `Transform`, `Vrr` [lines 1018-1100]
and `PowerOffMonitors` / `PowerOnMonitors` (DPMS) [lines 201-204]. No brightness,
gamma, or HDR action (grep). Mode refresh units: `(UNVERIFIED)`, the crate
doc comment was not read.

**(h) X11, RandR [XR].** `XRRGetScreenResourcesCurrent(dpy, window)` [line
415], `XRRSetCrtcConfig` [line 380], `XRRGetCrtcGammaSize` [line 391],
`XRRSetCrtcGamma(dpy, crtc, XRRCrtcGamma*)` [line 407]. Output and mode
details were not read.

**(i) Hotplug (Linux, all routes).** DRM uevent: `drm_sysfs_hotplug_event`
sets `HOTPLUG=1` in the uevent environment [K-DRMSYS lines 434-444]. Wayland:
wlr `head`/`finished`, KDE device `removed`, Mutter `MonitorsChanged`.

### 2.5 display, macOS

**(a) Enumeration (CoreGraphics, public).** `CGGetActiveDisplayList` [DI
`src/macos/mod.rs`]. `CGDisplayBounds`, `CGDisplayRotation`,
`CGDisplayScreenSize` (mm), `CGDisplayCopyDisplayMode`, `CGDisplayIsBuiltin`,
`CGDisplayIsMain` [DI `src/macos/mod.rs`]. `CGGetOnlineDisplayList`,
`CGDisplayCopyAllDisplayModes` and the `kCGDisplayShowDuplicateLowResolutionModes`
option named in the task are `(UNVERIFIED)`: no fetched source used them.
`NSScreen` to `CGDirectDisplayID` mapping by the `NSScreenNumber` key [DI
`src/macos/mod.rs`, lines 2-24].
Identity: `IODisplayCreateInfoDictionary` / `kIODisplayLocationKey` [MC-ARM
lines 130-153; DDCM `intel.rs` line 2]; EDID UUID from the IORegistry
(`"EDID UUID"`) [MC-ARM line 189]. `CoreDisplay_DisplayCreateInfoDictionary`
[LUN-BH line 47].

**(b) Configuration transaction (public API, CoreGraphics) [HS].**
```
CGBeginDisplayConfiguration(&cfg)                       // [HS 1128, 1170, 1200]
CGConfigureDisplayOrigin(cfg, id, x, y)                  // [HS 1132, 1137]
CGConfigureDisplayMirrorOfDisplay(cfg, id, master)       // [HS 1171, 1201]
CGCompleteDisplayConfiguration(cfg, option)              // [HS 1172, 1202]
   option: kCGConfigurePermanently or kCGConfigureForSession
CGCancelDisplayConfiguration(cfg)                        // [HS 1009]
```
Mode change: Hammerspoon uses the private `CGSConfigureDisplayMode` [HS line
115]. The public `CGConfigureDisplayWithDisplayMode` named in the task was not
seen in any fetched source (`(UNVERIFIED)`).
Changes are atomic inside one transaction: the whole begin/configure/complete
sequence is applied together, or cancelled [HS, `CGCancelDisplayConfiguration`
at line 1009].

**(c) Change notifications.** `CGDisplayRegisterReconfigurationCallback`
[HS line 1463] (callback flags `(UNVERIFIED)`). The private
`DisplayServicesRegisterForBrightnessChangeNotifications` is a separate
brightness-only route (2.2).

**(d) Private: CGS (`CGSGetDisplayList`, `CGSConfigureDisplayEnabled`).**
Named in the task; not seen in fetched sources (`(UNVERIFIED)`). Hammerspoon
uses `CGSConfigureDisplayMode` (private, line 115).

**(e) Deprecated.** `CGDisplayIOServicePort` is deprecated since 10.9 [NRB
line 86, comment]. Its replacement is `(UNVERIFIED)`: the approach in NRB is
to match the `IODisplayConnect` service by hand [NRB lines 86-95].

**(f) HDR / EDR headroom.** NSScreen selectors used by the brightness fork:
`maximumExtendedDynamicRangeColorComponentValue`,
`maximumPotentialExtendedDynamicRangeColorComponentValue`,
`maximumReferenceExtendedDynamicRangeColorComponentValue` [BRF
`src/macos.rs` lines 314-316, guarded by `respondsToSelector`]. Per-layer
opt-in: `setWantsExtendedDynamicRangeContent:` on `CAMetalLayer` [BRF
`src/macos.rs` lines 366-367]. `(single-source)`: these selectors were not
confirmed against Apple's documentation (unreachable).
`CGDisplayStreamGetDynamicRange` named in the task is `(UNVERIFIED)`.

**(g) Permissions.** The CoreGraphics reads and transactions need no TCC prompt
in the code read (`(UNVERIFIED)`: screen-capture TCC is unrelated to these
calls). Private `CoreDisplay` / `DisplayServices` / `IOAVService` symbols need
runtime resolution and may break on OS updates (section 6).

### 2.6 display, Windows

**(a) Enumerate topology (public).**
1. `GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS or QDC_ALL_PATHS, &np,
   &nm)` then `QueryDisplayConfig(flags, &np, paths, &nm, modes, &topology)`
   [MGW `winuser.h` line 5625; `QDC_ALL_PATHS` = `0x1`, `QDC_ONLY_ACTIVE_PATHS`
   = `0x2`, MGW `wingdi.h` lines 2483-2484; crate uses both, DKG `blocking/windows.rs`
   imports].
2. `DisplayConfigGetDeviceInfo(&header)` with `header.type`:
   `GET_SOURCE_NAME` = 1, `GET_TARGET_NAME` = 2, `GET_TARGET_PREFERRED_MODE` = 3,
   `GET_ADAPTER_NAME` = 4, `SET_TARGET_PERSISTENCE` = 5, `GET_TARGET_BASE_TYPE` = 6,
   `GET_SUPPORT_VIRTUAL_RESOLUTION` = 7, `SET_SUPPORT_VIRTUAL_RESOLUTION` = 8,
   `GET_ADVANCED_COLOR_INFO` = 9, `SET_ADVANCED_COLOR_STATE` = 10,
   `GET_SDR_WHITE_LEVEL` = 11, `GET_MONITOR_SPECIALIZATION` = 12,
   `SET_MONITOR_SPECIALIZATION` = 13, `SET_RESERVED1` = 14,
   `GET_ADVANCED_COLOR_INFO_2` = 15, `SET_HDR_STATE` = 16, `SET_WCG_STATE` = 17
   [MGW `wingdi.h` lines 2263-2279].
   `DISPLAYCONFIG_TARGET_DEVICE_NAME` (type 2) gives `flags`, `outputTechnology`,
   `edidManufactureId` (`UINT16`), `edidProductCodeId` (`UINT16`),
   `connectorInstance` (`UINT32`), `monitorFriendlyDeviceName[64]`,
   `monitorDevicePath[128]` [MGW lines 2312-2318]. The `monitorDevicePath`
   equals `DISPLAY_DEVICEW.DeviceID` with `EDD_GET_DEVICE_INTERFACE_NAME` [DKG
   `blocking/windows.rs` comment, lines 70-71].
   Output technology values: `HDMI` = 5 [MGW line 2086], `DISPLAYPORT_EMBEDDED`
   = 11 [MGW line 2091], `INTERNAL` = `0x80000000` [MGW line 2099].
3. Advanced colour: `DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO` bitfields
   `advancedColorSupported`, `advancedColorEnabled`, `wideColorEnforced`,
   `advancedColorForceDisabled` [MGW lines 2373-2376]; `colorEncoding` (RGB 0,
   YCbCr444 1, YCbCr422 2, YCbCr420 3, Intensity 4) [MGW lines 2360-2367];
   `bitsPerColorChannel` [MGW line 2382]. The second struct (type 15) adds
   `highDynamicRangeSupported` and `highDynamicRangeUserEnabled` [MGW lines
   2408-2413].
4. SDR white level (type 11): `DISPLAYCONFIG_SDR_WHITE_LEVEL { header; ULONG
   SDRWhiteLevel; }` [MGW lines 2449-2452]. Units: `1000` = 80 nits, `2000` =
   160 nits [MSW-SDR, "a multiplier of 80 nits, multiplied by 1000"].

**(b) Apply (public, atomic within one call).**
`SetDisplayConfig(numPaths, paths, numModes, modes, flags)` [MGW `winuser.h`
line 5624]. Exactly one of `SDC_APPLY` (`0x80`) or `SDC_VALIDATE` (`0x40`):
"Either SDC_APPLY or SDC_VALIDATE must be set, but not both" [MSW-SDC].
Other flags: `SDC_USE_SUPPLIED_DISPLAY_CONFIG` `0x20`, `SDC_NO_OPTIMIZATION`
`0x100` (APPLY only), `SDC_SAVE_TO_DATABASE` `0x200`, `SDC_ALLOW_CHANGES`
`0x400`, `SDC_PATH_PERSIST_IF_REQUIRED` `0x800`, `SDC_FORCE_MODE_ENUMERATION`
`0x1000` (APPLY + supplied), `SDC_ALLOW_PATH_ORDER_CHANGES` `0x2000`,
`SDC_VIRTUAL_MODE_AWARE` `0x8000` [MGW `wingdi.h` lines 2490-2507; MSW-SDC].
Topology: `SDC_TOPOLOGY_INTERNAL` `0x1`, `CLONE` `0x2`, `EXTEND` `0x4`,
`EXTERNAL` `0x8`, `SUPPLIED` `0x10` [MGW lines 2490-2494]. Failure: no
solution gives `ERROR_BAD_CONFIGURATION` [MSW-SDC].
Sequence: 1) QueryDisplayConfig (ALL_PATHS) → 2) modify path/mode arrays →
3) `SetDisplayConfig(..., SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_VALIDATE)` →
4) if OK, `SetDisplayConfig(..., SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_APPLY)`.
Adding `SDC_SAVE_TO_DATABASE` (`0x200`) is the persistence option. Whether
omitting it makes the change session-only is `(UNVERIFIED)`: the persistence
semantics were not read on Learn.
Revert: no API. Keep the prior `DISPLAYCONFIG_PATH_INFO` array and re-apply
it (design; see section 5).

**(c) Mode-level (legacy but still used).** `EnumDisplayDevicesW` [DKG imports],
`ChangeDisplaySettingsExW(name, devmode, hwnd, flags, lParam)` [MSW-CDS].
Flags [MGW `winuser.h` lines 5567-5579]: `CDS_UPDATEREGISTRY` `0x1`, `CDS_TEST`
`0x2` (validate only), `CDS_FULLSCREEN` `0x4`, `CDS_GLOBAL` `0x8`,
`CDS_SET_PRIMARY` `0x10`, `CDS_VIDEOPARAMETERS` `0x20`, `CDS_ENABLE_UNSAFE_MODES`
`0x100`, `CDS_DISABLE_UNSAFE_MODES` `0x200`, `CDS_RESET` `0x40000000`,
`CDS_RESET_EX` `0x20000000`, `CDS_NORESET` `0x10000000`. Results:
`DISP_CHANGE_SUCCESSFUL`, `DISP_CHANGE_RESTART` (persisted, needs restart),
`DISP_CHANGE_FAILED`, `DISP_CHANGE_BADMODE` [MSW-CDS]. `CDS_NORESET` lets
several changes be batched then committed with one NULL call (`(UNVERIFIED)`
on the commit form; Learn page was read only for `CDS_TEST` and
`CDS_UPDATEREGISTRY`).
Primary: `CDS_SET_PRIMARY` on the chosen display.

**(d) Scale / DPI.** `GetDpiForMonitor(hmon, MONITOR_DPI_TYPE, &x, &y)` [MSW-DPI].
Per the Learn page, `MDT_RAW_DPI` and `MDT_ANGULAR_DPI` exclude the user's
slider override; `MDT_EFFECTIVE_DPI` includes it. Scale percent = effective DPI
/ 96 (`(UNVERIFIED)` the 96 base; it is the standard base).

**(e) Hotplug.** `WM_DISPLAYCHANGE` is sent to all top-level windows when the
resolution or depth changes; `wParam` is bits per pixel, `lParam` is
width/height [MSW-WDC]. Device arrival/removal for displays (`WM_DEVICECHANGE`)
is `(UNVERIFIED)`.

**(f) Permissions.** None observed in the reads (`(UNVERIFIED)`: admin rights
for persistent changes, and whether `SetDisplayConfig` needs a session that
owns the console).

### 2.7 color, Linux

**(a) Gamma tables on Wayland: `zwlr_gamma_control_manager_v1` [WL-GC lines
43-119].**
* `get_gamma_control(new_id zwlr_gamma_control_v1, wl_output)`.
* Event `gamma_size(uint)`: the number of entries per ramp.
* Request `set_gamma(fd)`: the fd holds three successive ramps (R, G, B), each
  `gamma_size` entries of 16-bit unsigned (`u16`). File size must be
  `3 * gamma_size * 2` bytes. "The file descriptor data must have the same
  length as three times the gamma size" [WL-GC `set_gamma` description].
* Event `failed`: no longer valid. Causes include another client holding
  exclusive gamma control [WL-GC `failed` description].
Sequence:
1. `wl_registry.bind` `zwlr_gamma_control_manager_v1`.
2. `get_gamma_control(output)`; wait for `gamma_size`.
3. Create a memfd of `3 * gamma_size * 2` bytes; fill R, G, B ramps.
4. `set_gamma(fd)`; close the fd when done; `destroy` when the output goes away
   (on `failed`, destroy and recreate).
Colour temperature: redshift's table is blackbody RGB at 1000 K to 10000 K in
100 K steps [RED lines 30-121], interpolated linearly between the two nearest
rows, and each channel is multiplied into the ramp [RED lines 276-320;
`colorramp_fill`]. wl-gammarelay-rs exposes `set_gamma`, `set_temperature` and
`set_brightness` over D-Bus [WGR, functions `set_gamma`, `set_temperature`,
`set_brightness`] (grep only).

**(b) Mutter gamma and night-light state.** `GetCrtcGamma(u serial, u crtc,
aq red, aq green, aq blue)` and `SetCrtcGamma(u serial, u crtc, aq red, aq
green, aq blue)` [MUT lines 261-285] (16-bit ramps). `NightLightSupported`
(bool) [MUT line 337]. The night-light settings path is `(UNVERIFIED)`: the
gsettings schema was not read.

**(c) KDE.** `kde_output_device_v2` events `icc_profile_path` (since 5),
`color_profile_source` (since 7), `sdr_gamut_wideness` (since 6),
`color_power_tradeoff` (since 10), `edr_policy` (since 16) [KDE-D]. Requests
`set_icc_profile_path` (since 6), `set_color_profile_source` (since 8),
`set_sdr_gamut_wideness` (since 7), `set_color_power_tradeoff` (since 10),
`set_edr_policy` (since 16) [KDE-M]. Night light is not in these protocols
(`(UNVERIFIED)`: KWin's own night-light config path).

**(d) X11.** `XRRSetCrtcGamma` and `XRRGetCrtcGammaSize` [XR lines 391, 407].

**(e) ICC profile name.** Read: KDE `icc_profile_path`. Other routes not
researched (`(UNVERIFIED)`).

### 2.8 color, macOS

**(a) Gamma.** `CGSetDisplayTransferByTable(display, size, r, g, b)` [LUN-GAM
line 385] (the full argument order was not read; `(UNVERIFIED)` for the exact
signature). Lunar scales the table by the brightness factor [LUN-DISP lines
398-403]. `CGSetDisplayTransferByFormula` and
`CGDisplayRestoreColorSyncSettings` named in the task are `(UNVERIFIED)`.

**(b) Night Shift (private CoreBrightness).** Lunar imports `CBBlueLightClient.h`
[LUN-BH line 8] and uses `client.setEnabled(bool)` and reads `status.enabled` /
`status.active` [LUN-GAM lines 140, 166-168]. Those two are `(single-source)`.
`setStrength:commit:`, `getBlueLightStatus:`, `setSchedule:`, `setMode:` named in
the task were not seen (`(UNVERIFIED)`). Kelvin is not exposed in the
Lunar code read. Mapping strength to kelvin is `(UNVERIFIED)`.

**(c) True Tone (private).** `CBTrueToneClient` is commented out in Lunar's
bridging header [LUN-BH line 11]. Not used by Lunar. Selectors `(UNVERIFIED)`.

**(d) ICC.** Not researched (`(UNVERIFIED)`).

### 2.9 color, Windows

**(a) Gamma.** `SetDeviceGammaRamp(hdc, ramp)`: three arrays of 256 `WORD`
values, with the RGB values in the most significant bits [MSW-SGR]. The
function "implements heuristics" and fails silently (returns TRUE, does not
set the ramp) if the ramp would make the screen unreadable [MSW-SGR]. Read:
`GetDeviceGammaRamp` (`(UNVERIFIED)`, not fetched).

**(b) Advanced colour / HDR / WCG (public DisplayConfig set types, Windows
11).** `DISPLAYCONFIG_DEVICE_INFO_SET_ADVANCED_COLOR_STATE` = 10
(`DISPLAYCONFIG_SET_ADVANCED_COLOR_STATE`, [MGW lines 2385-2394]),
`DISPLAYCONFIG_DEVICE_INFO_SET_HDR_STATE` = 16 (`DISPLAYCONFIG_SET_HDR_STATE`,
[MGW lines 2425-2434]), `..._SET_WCG_STATE` = 17 (`DISPLAYCONFIG_SET_WCG_STATE`,
bitfield `enableWcg`, [MGW lines 2436-2445]). The WCG struct is inside an
`NTDDI_WIN11_GA` guard in the mingw header [MGW line 2447]. The semantics
(which fields to set, and on which OS build) are `(UNVERIFIED)`: the Learn
page for these structs was not read.

**(c) SDR white level (content brightness, Windows 11).** Read: type 11
(section 2.6). Set: `DISPLAYCONFIG_DEVICE_INFO_SET_SDR_WHITE_LEVEL` is
**not in the mingw enum** [MGW lines 2263-2281]. The task says it is
undocumented; the value and struct are `(UNVERIFIED)`.

**(d) Night light (blue-light reduction).** Registry blob at
`HKCU\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.bluelightreduction.bluelightreductionstate`
as cited in the task. No authoritative source was fetched; the blob layout
is `(UNVERIFIED)`.

**(e) ICC / WCS.** Not researched (`(UNVERIFIED)`).

## 3. Reference implementations (prove it works)

Read level: "code" = targeted reads of the relevant part; "grep" = matched
identifiers only; "list" = file list only; "README" = not read.

| Project | Language | File (URL) | What to copy the idea of | Read |
| --- | --- | --- | --- | --- |
| Lunar (pinned 511b0358) | Swift/ObjC | `Lunar/Control/AppleNativeControl.swift`, `Lunar/Data/Display.swift` (`getBestControl`, 5152), `Lunar/Control/GammaControl.swift`, `Lunar/DDC/DDC.c`, `Lunar/DDC/Lunar-Bridging-Header.h`, `Lunar/Control/Control.swift` | Control priority; DisplayServices write/smooth/nits; gamma table; IOFB I2C; private symbol list | code (targeted) |
| MonitorControl (branch `main`, not pinned) | Swift | `MonitorControl/Support/Arm64DDC.swift` | DCPAVServiceProxy/Location matching; IOAVService I/O and timing | code (targeted) |
| ddc-macos 0.2.2 | Rust | `src/arm.rs`, `src/intel.rs`, `src/iokit/io2c_interface.rs` | Apple Silicon and Intel DDC; MCDP29xx `0xB7` | code (targeted) |
| brightness 0.5.0 | Rust | `src/blocking/linux.rs`, `src/blocking/windows.rs` | logind-to-sysfs fallback; panel IOCTL vs DDC branch | code (targeted) |
| ddc-winapi 0.2.2 | Rust | `src/lib.rs` | dxva2 monitor enumeration | list only |
| ddc-hi 0.4.1 | Rust | `src/lib.rs` | cross-OS DDC abstraction | list only |
| display-info 0.5.9 | Rust | `src/macos/mod.rs`, `src/windows/mod.rs`, `src/linux/wayland.rs` | CoreGraphics and NSScreen enumeration; `wl_output` read | grep |
| DankMaterialShell brightness (master) | Go | `core/internal/server/brightness/ddc.go`, `logind.go`, `manager.go` | DRM-gated i2c probing; `flock`; `I2C_SLAVE`; logind backend | code (targeted) |
| nriley/brightness (master) | C | `brightness.c` | DisplayServices plus IODisplay fallback; `CGDisplayIOServicePort` deprecation note | code (targeted) |
| Hammerspoon (master) | ObjC | `extensions/screen/libscreen.m` | CoreGraphics configuration transaction; reconfiguration callback; private `CGSConfigureDisplayMode` | grep |
| redshift (master) | C | `src/colorramp.c` | 1000–10000 K blackbody table; interpolation; ramp fill | code (partial) |
| wl-gammarelay-rs (master) | Rust | `src/main.rs` | separate brightness, temperature, gamma setters over D-Bus | grep |
| niri-ipc 26.4.0 | Rust | `src/lib.rs` | output model; absence of brightness | grep |
| brightness fork (scratch) | Rust | `forks/brightness/PLATFORMS.md`, `src/edr.rs`, `src/macos.rs` | EDR selectors; route summary | local read (previous attempt, not hardware-verified) |
| wlx-monitors fork (scratch) | Rust | `forks/wlx-monitors/src/*` | wlr output management usage | grep (previous attempt) |
| Not read: Quickshell, Astal, Hyprland, Twinkle Tray, Monitorian, Lunar keyboard client, ddcutil source | | | | README or unreachable |

Protocol and API primaries, not reference implementations, are in section 4.

## 4. Double validation

### 4.1 Source keys

Kernel (pinned to tag `v6.18`):
* `K-BL` `https://raw.githubusercontent.com/torvalds/linux/v6.18/Documentation/ABI/stable/sysfs-class-backlight`
* `K-BLT` `.../v6.18/include/linux/backlight.h`
* `K-I2C` `.../v6.18/Documentation/i2c/dev-interface.rst`
* `K-I2CUAPI` `.../v6.18/include/uapi/linux/i2c-dev.h`
* `K-EDID` `.../v6.18/include/drm/drm_edid.h`
* `K-DRMSYS` `.../v6.18/drivers/gpu/drm/drm_sysfs.c`
* `K-LEDS` `.../v6.18/Documentation/leds/leds-class.rst`
* `K-KEY` `.../v6.18/include/uapi/linux/input-event-codes.h`

systemd (branch `main`, not pinned):
* `L-SBD` `https://raw.githubusercontent.com/systemd/systemd/main/src/login/logind-session-dbus.c`
* `L-SBW` `.../src/login/logind-brightness.c`
* `L-MAN` `https://raw.githubusercontent.com/systemd/systemd/main/man/org.freedesktop.login1.xml`

Wayland and desktop:
* `WL-OM` `https://gitlab.freedesktop.org/wlroots/wlr-protocols/-/raw/master/unstable/wlr-output-management-unstable-v1.xml`
* `WL-GC` `.../wlr-protocols/-/raw/master/unstable/wlr-gamma-control-unstable-v1.xml`
* `WL-PM` `.../wlr-protocols/-/raw/master/unstable/wlr-output-power-management-unstable-v1.xml`
* `WL-OUT` `https://gitlab.freedesktop.org/wayland/wayland/-/raw/main/protocol/wayland.xml` (`wl_output`)
* `WL-XO` `https://gitlab.freedesktop.org/wayland/wayland-protocols/-/raw/main/unstable/xdg-output/xdg-output-unstable-v1.xml`
* `KDE-D` `https://invent.kde.org/libraries/plasma-wayland-protocols/-/raw/master/src/protocols/kde-output-device-v2.xml`
* `KDE-M` `.../plasma-wayland-protocols/-/raw/master/src/protocols/kde-output-management-v2.xml`
* `MUT` `https://gitlab.gnome.org/GNOME/mutter/-/raw/main/data/dbus-interfaces/org.gnome.Mutter.DisplayConfig.xml`
* `XR` `https://gitlab.freedesktop.org/xorg/lib/libxrandr/-/raw/master/include/X11/extensions/Xrandr.h`
* `SWAY-OUT` `https://raw.githubusercontent.com/swaywm/sway/master/sway/sway-output.5.scd`
* `SWAY-IPC` `https://raw.githubusercontent.com/swaywm/sway/master/sway/sway-ipc.7.scd`
* `NIRI` `https://static.crates.io/crates/niri-ipc/niri-ipc-26.4.0.crate` (`src/lib.rs`)
* `RED` `https://raw.githubusercontent.com/jonls/redshift/master/src/colorramp.c`
* `WGR` `https://raw.githubusercontent.com/MaxVerevkin/wl-gammarelay-rs/master/src/main.rs`

Windows (Microsoft Learn and mingw-w64 headers, which mirror the SDK):
* `MSW-GMB` `https://learn.microsoft.com/en-us/windows/win32/api/highlevelmonitorconfigurationapi/nf-highlevelmonitorconfigurationapi-getmonitorbrightness`
* `MSW-SGR` `https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-setdevicegammaramp`
* `MSW-CDS` `https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-changedisplaysettingsexw`
* `MSW-SDC` `https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setdisplayconfig`
* `MSW-DPI` `https://learn.microsoft.com/en-us/windows/win32/api/shellscalingapi/nf-shellscalingapi-getdpiformonitor`
* `MSW-SDR` `https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-displayconfig_sdr_white_level`
* `MSW-WDC` `https://learn.microsoft.com/en-us/windows/win32/gdi/wm-displaychange`
* `MGW` `https://raw.githubusercontent.com/mirror/mingw-w64/master/mingw-w64-headers/include/` + `wingdi.h`, `winuser.h`, `ntddvdeo.h`, `winnt.h`, `highlevelmonitorconfigurationapi.h`, `physicalmonitorenumerationapi.h`, `lowlevelmonitorconfigurationapi.h`

Reference code:
* `LUN-*` Lunar at `https://raw.githubusercontent.com/alin23/Lunar/511b035896d81f44e5440beeb3f20fd4a6905009/` + path: `LUN-ANC` = `Lunar/Control/AppleNativeControl.swift`, `LUN-DISP` = `Lunar/Data/Display.swift`, `LUN-GAM` = `Lunar/Control/GammaControl.swift`, `LUN-DDC` = `Lunar/DDC/DDC.c`, `LUN-BH` = `Lunar/DDC/Lunar-Bridging-Header.h`, `LUN-CTL` = `Lunar/Control/Control.swift`
* `MC-ARM` `https://raw.githubusercontent.com/MonitorControl/MonitorControl/main/MonitorControl/Support/Arm64DDC.swift`
* `DDCM-ARM` `https://static.crates.io/crates/ddc-macos/ddc-macos-0.2.2.crate` (`src/arm.rs`, `src/intel.rs`, `src/iokit/io2c_interface.rs`)
* `DKG` `https://static.crates.io/crates/brightness/brightness-0.5.0.crate` (`src/blocking/linux.rs`, `src/blocking/windows.rs`)
* `DI` `https://static.crates.io/crates/display-info/display-info-0.5.9.crate`
* `DMS` `https://raw.githubusercontent.com/AvengeMedia/DankMaterialShell/master/core/internal/server/brightness/` + `ddc.go`, `logind.go`, `manager.go`
* `NRB` `https://raw.githubusercontent.com/nriley/brightness/master/brightness.c`
* `HS` `https://raw.githubusercontent.com/Hammerspoon/hammerspoon/master/extensions/screen/libscreen.m`
* `BRF` local scratch: `.../scratchpad/rust_prev/desktop-systems/forks/brightness/PLATFORMS.md`, `src/edr.rs`, `src/macos.rs` (previous attempt, unverified on hardware)

Apple documentation: `developer.apple.com` pages returned no text. Apple claims
are therefore backed by reference code only and are marked single-source.

### 4.2 Claims

| ID | Claim | Sources (agreeing) | Status |
| --- | --- | --- | --- |
| B1 | Backlight `type` ordering firmware > platform > raw | K-BL, K-BLT | two |
| B2 | `brightness` is setpoint, `actual_brightness` is read-back | K-BL, DKG `linux.rs` | two |
| B3 | logind `SetBrightness(ssu)`, subsystems `backlight`/`leds` | L-MAN, L-SBD lines 686-687 and 1085 | two |
| B4 | logind requires active foreground session, owner or root, same seat; no polkit | L-SBD 671-720 | single-source (code) |
| B5 | logind coalesces writes, replies after write | L-SBW (comment + `manager_write_brightness`) | single-source (code) |
| B6 | Unknown-method fallback to direct sysfs write | DKG `linux.rs` (comment) | single-source |
| B7 | DRM connector `ddc` symlink to the I2C adapter | K-DRMSYS 394-396, DMS (uses DRM mapping) | two |
| B8 | `I2C_SLAVE` = `0x0703`; `I2C_RDWR` = `0x0707` | K-I2CUAPI (value); K-I2C (usage) | two (doc + header) |
| B9 | EDID address `0x50`, `DDC_ADDR2` `0x52` | K-EDID | single-source |
| B10 | DDC/CI chip `0x37` | MC-ARM line 6, DDCM-ARM, DMS `ddc.go` line 19 | three |
| B11 | Apple Silicon DDC: `DCPAVServiceProxy` with `Location == "External"`, `IOAVServiceCreateWithService`, `Write/ReadI2C` | MC-ARM 223-231 and 92-110; DDCM-ARM `arm.rs` | two |
| B12 | Apple MCDP29xx chip `0xB7` on builtin HDMI | DDCM-ARM only | single-source |
| B13 | Intel DDC via `IOFBCopyI2CInterfaceForBus` + `IOI2CSendRequest` | DDCM-ARM `intel.rs`, LUN-DDC 287-292 | two |
| B14 | `DisplayServicesGet/SetBrightness` and `GetLinearBrightness` exist | LUN-BH 49-53, NRB 124-167 | two |
| B15 | `DisplayServicesSetBrightnessSmooth` takes a delta | LUN-ANC 286 (usage) | single-source |
| B16 | `br == 1.0` also sets linear brightness | LUN-ANC 147-149 | single-source |
| B17 | Smooth ramp step 0.002, intervals 0.004/0.025 s | LUN-ANC 309-317 | single-source |
| B18 | nits = `maxNits * GetLinearBrightness` | LUN-ANC 217-221 | single-source |
| B19 | CoreDisplay user brightness symbols | LUN-BH 37-43, NRB 173-182 | two |
| B20 | Legacy `IODisplaySetFloatParameter` + `kIODisplayBrightnessKey` | NRB 54, 150-151 | single-source |
| B21 | `CGDisplayIOServicePort` deprecated 10.9 | NRB 86 (comment) | single-source |
| B22 | Lunar control order: appleNative → DDC → network → gamma | LUN-DISP 5152+ | single-source (task also states it; not independent) |
| B23 | Lunar `DisplayControl` declaration order differs from selection order | LUN-CTL 29-34 vs LUN-DISP | single-source |
| B24 | `CGSetDisplayTransferByTable` used for gamma | LUN-GAM 385 | single-source |
| B25 | Overlay `.hud` level, alpha 0.01…0.85 | none read | UNVERIFIED |
| B26 | Windows `\\.\LCD` IOCTLs `0x125`/`0x126`/`0x127` | MGW `ntddvdeo.h` 185-191, DKG `windows.rs` (imports) | two |
| B27 | `DISPLAY_BRIGHTNESS { AC, DC, policy }` | MGW `ntddvdeo.h` 477-481 | single-source (DKG imports the type name) |
| B28 | `VIDEO_SUPPORTED_BRIGHTNESS` layout | none read | UNVERIFIED |
| B29 | `GetMonitorBrightness` returns min, cur, max | MSW-GMB, MGW highlevel 91 | two |
| B30 | `SetMonitorBrightness(h, DWORD)` | MGW highlevel 103, DKG `set` | two |
| B31 | `GetPhysicalMonitorsFromHMONITOR` + `DestroyPhysicalMonitor` | MGW physmon 32-36, DKG | two |
| B32 | VCP low-level `SetVCPFeature`, `GetVCPFeatureAndVCPFeatureReply` | MGW lowlevel 33-34 | single-source (header) |
| B33 | `INTERNAL` output tech `0x80000000` | MGW `wingdi.h` 2099, DKG `is_internal` | two |
| B34 | `GUID_DEVICE_POWER_POLICY_VIDEO_BRIGHTNESS` and `GUID_VIDEO_SUBGROUP` | MGW `winnt.h` 6336-6343 | single-source |
| B35 | `GUID_VIDEO_BRIGHTNESS` exists | none; absent from MGW | refuted (not in headers) |
| B36 | `PowerWriteACValueIndex` exists | not in saved `powrprof.h` | UNVERIFIED |
| B37 | `DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL` = 11; struct; 1000 = 80 nits | MGW 2273, 2449-2452; MSW-SDR | two |
| B38 | `DISPLAYCONFIG_DEVICE_INFO_SET_SDR_WHITE_LEVEL` exists | absent from MGW enum | UNVERIFIED (task claim unsupported) |
| B39 | WMI `WmiMonitorBrightness` route | none read; DKG does not use it | UNVERIFIED |
| B40 | KDE `brightness` 0-10000, `set_brightness` (since 9), `set_dimming` (since 11) | KDE-D 426-447, KDE-M 311-365 (same repo) | single-source (protocol) |
| B41 | Mutter `Backlight` property and `SetBacklight(u,s,i)` | MUT 228-249 | single-source |
| B42 | Mutter `ApplyMonitorsConfig` method 0 verify / 1 temp / 2 persistent | MUT 489-494 | single-source |
| D1 | wlr configuration `test` / `apply` / `succeeded` / `failed` / `cancelled` semantics | WL-OM 466-530 | single-source (protocol; not compared to a compositor) |
| D2 | wlr mode refresh in mHz | WL-OM 392-397, WL-OUT 138 (`refresh` mHz) | two (same ecosystem) |
| D3 | wlr output management has no HDR/colour-depth/mirror fields | WL-OM (field list) | single-source |
| D4 | KDE has no `test` request | KDE-M request list | single-source |
| D5 | sway `output ... mode`, `power`, `render_bit_depth` | SWAY-OUT | single-source (man page) |
| D6 | sway IPC `GET_OUTPUTS` fields | SWAY-IPC 187-235 | single-source |
| D7 | niri has no brightness/gamma action | NIRI (grep) | single-source |
| D8 | RandR `XRRSetCrtcGamma` etc. | XR 380-415 | single-source (header) |
| D9 | DRM hotplug uevent `HOTPLUG=1` | K-DRMSYS 434-444 | single-source |
| D10 | Mutter `MonitorsChanged` | MUT 346 | single-source |
| D11 | Mac `CGDisplayRegisterReconfigurationCallback` | HS 1463 | single-source |
| D12 | Mac CG config transaction (`Begin`, `ConfigureDisplayOrigin`, `ConfigureDisplayMirrorOfDisplay`, `Complete`, `Cancel`) | HS 1009-1202 | single-source |
| D13 | Mac `CGConfigureDisplayWithDisplayMode` | none | UNVERIFIED |
| D14 | Mac `CGDisplayCopyAllDisplayModes`, `kCGDisplayShowDuplicateLowResolutionModes` | none | UNVERIFIED |
| D15 | Mac `CGDisplayScreenSize`, `CGDisplayRotation`, `CGDisplayBounds`, `CGDisplayIsBuiltin` | DI `macos/mod.rs` | single-source |
| D16 | Windows `QueryDisplayConfig` flags `QDC_*` | MGW winuser 5625, wingdi 2483-2484 | two (header + DKG imports) |
| D17 | `DISPLAYCONFIG_TARGET_DEVICE_NAME` fields | MGW 2312-2318, DKG comment | two |
| D18 | `SetDisplayConfig` APPLY xor VALIDATE | MSW-SDC, MGW 2499-2500 | two |
| D19 | `ERROR_BAD_CONFIGURATION` when no solution | MSW-SDC | single-source |
| D20 | `CDS_TEST`, `CDS_UPDATEREGISTRY`, `DISP_CHANGE_RESTART` | MSW-CDS, MGW 5567-5579 | two |
| D21 | `GetDpiForMonitor` MDT semantics | MSW-DPI | single-source |
| D22 | `WM_DISPLAYCHANGE` | MSW-WDC | single-source (official) |
| D23 | `SetDisplayConfig` has no revert | MSW-SDC (no revert in text) | single-source |
| C1 | `SetDeviceGammaRamp` 3×256 WORD, silent fail | MSW-SGR | single-source |
| C2 | wlr `set_gamma` fd = 3 × gamma_size × 16-bit | WL-GC | single-source |
| C3 | redshift blackbody 1000 K–10000 K, 100 K step | RED 30-121 | single-source |
| C4 | `CBBlueLightClient.setEnabled:` and `status.enabled` | LUN-GAM 140, 166-168, LUN-BH 8 | single-source |
| C5 | Night Shift `setStrength:commit:`, `setSchedule:`, `setMode:` | none | UNVERIFIED |
| C6 | Windows night-light registry blob | task only | UNVERIFIED |
| C7 | KDE `icc_profile_path`, `set_icc_profile_path` (since 6) | KDE-D 387, KDE-M 275 (same repo) | single-source |
| C8 | Mutter `color-mode` 0/1/2 | MUT 392-410 | single-source |
| C9 | SetOutputCTM 3×3 S31.32 | MUT 542-550 | single-source |
| E1 | NSScreen EDR selectors | BRF `macos.rs` 314-316 | single-source (previous attempt) |
| E2 | `setWantsExtendedDynamicRangeContent:` | BRF `macos.rs` 366-367 | single-source |
| E3 | macOS 26.3 XDR breakage | none (Lunar at this pin has no such note) | UNVERIFIED |
| E4 | Windows SDR white and HDR set types 10, 16, 17 | MGW 2271-2279 | single-source (header) |

## 5. Proposed Bleu model

Draft C3 types, written to the ARCHITECTURE contract (plain-data state,
`Cap`, `Event`, `Operation`, `Options`, backend list). Not yet compiled; check
each declaration with `c3c` before use (STYLE.md: C3 0.8.5 differs from older
tutorials). Units are in the type names.

```c3
module bleu::brightness;

import bleu::availability;   // Availability: AVAILABLE or WHY_NOT
import bleu::unit;           // shared quantities

// 0.0..1.0, clamped at the boundary. Never a percent or raw count.
typedef Level = float;
// Estimate only. Read-only. Source: DisplayServices linear, or KDE override.
typedef Nits = float;

// Where the number came from. One per control; never merged.
enum Mechanism : char {
    PANEL_BACKLIGHT,   // sysfs, IOCTL, DisplayServices, Mutter Backlight
    OS_NATIVE,         // logind (Linux), vendor compositor protocol
    DDC_CI,            // i2c-dev, dxva2, IOAVService, IOFramebuffer I2C
    GAMMA_TABLE,       // wlr-gamma-control, RandR, SetDeviceGammaRamp, CGSetDisplayTransferByTable
    OVERLAY,           // app-drawn click-through window (macOS, Lunar)
    COMPOSITOR_DIM,    // KDE set_dimming (temporary)
    KEYBOARD_BACKLIGHT,
}

// Raw range is kept beside the normalised level so the caller can show both.
struct Control {
    Mechanism mechanism;
    Availability availability;   // why not, if unavailable
    bool has_level;              // optional values cannot be stored in structs
    Level level;
    uint raw;                    // device value at read time
    uint raw_min;
    uint raw_max;
    bool writable;
}

struct DisplayBrightness {
    String display_id;           // matches display::Output.id
    Control[] controls;          // one entry per mechanism that exists
    bool supports_nits;
    Nits nits;                   // valid only when supports_nits
}

struct State {
    DisplayBrightness[] displays;
    bool keyboard_present;
    Level keyboard_level;        // valid only when keyboard_present
    bool ambient_auto_available;
    bool ambient_auto_enabled;
    bool edr_available;
    Level edr_headroom;          // the current headroom, not the potential
}

enum Cap : char {
    SET_PANEL_LEVEL,
    SET_DDC_LEVEL,
    SET_GAMMA_DIM,
    SET_OVERLAY_DIM,
    SET_KEYBOARD_LEVEL,
    SET_SMOOTH,                  // client-side ramp or OS delta
    AMBIENT_AUTO_TOGGLE,
    READ_NITS_ESTIMATE,
    READ_EDR_HEADROOM,
    NOTIFY_CHANGE,
    NOTIFY_KEYS,                 // hardware keys, where observable
}

// Transients. Overflow is reported; the cure is to re-read State.
enum BrightnessEventKind : char {
    LEVEL_CHANGED,
    KEY_PRESSED,                 // up, down, auto, keyboard up/down
    AMBIENT_AUTO_CHANGED,
}
struct BrightnessEvent {
    BrightnessEventKind kind;
    String display_id;           // empty for keyboard
    Mechanism mechanism;
    Level level;
}

struct Options {
    String backend;              // "" = probe order; else force one
    TransitionKind transition;   // INSTANT, SMOOTH
}
enum TransitionKind : char { INSTANT, SMOOTH }

// Backends, highest preference first, per OS. "private" = dlsym at run time.
// Linux:   logind_backlight, sysfs_direct (fallback only), logind_leds,
//          ddc_i2c_dev, mutter_backlight, kde_brightness, gamma_wlr, gamma_randr
// macOS:   displayservices (private), coredisplay_user (private), iodisplay_legacy,
//          ddc_ioav_service (private, Apple Silicon), ddc_iofb_i2c (Intel),
//          gamma_cg_table, overlay
// Windows: panel_ioctl (\\.\LCD), dxva2_high_level, dxva2_low_level, gamma_ramp
// Not in V1: WMI, Night Shift, Windows SDR white write, overlay on Windows.
```

```c3
module bleu::display;
import bleu::availability;

typedef ScaleFactor = float;       // 1.0, 1.25, 2.0 ...
typedef RefreshMilliHz = uint;     // wlr / wl_output unit (mHz); 59940 for 59.94 Hz
typedef Mm = uint;                 // physical size in millimetres

enum ConnectionKind : char { UNKNOWN, INTERNAL, HDMI, DISPLAYPORT, DISPLAYPORT_EMBEDDED, VIRTUAL, OTHER }
enum Transform : char { NORMAL, R90, R180, R270, FLIPPED, FLIPPED_R90, FLIPPED_R180, FLIPPED_R270 }
enum ColorEncoding : char { RGB, YCBCR444, YCBCR422, YCBCR420, INTENSITY }

struct Mode {
    uint width;
    uint height;
    RefreshMilliHz refresh;
    bool preferred;
    bool current;
}

bitstruct OutputFlags : uint {     // layout to be checked with c3c
    bool hdr;
    bool vrr;
    bool wide_gamut;
    bool auto_rotate;
    bool ddc_ci;
    bool auto_brightness;          // ALS toggle (KDE), if present
}

struct Output {
    String id;                     // stable id, e.g. connector name or CG uuid
    String name;                   // "DP-1", "\\.\DISPLAY1", "Color LCD"
    String make;
    String model;
    String serial;
    String edid_base64;            // empty if not exposed
    ConnectionKind connection;
    bool enabled;
    int x;
    int y;
    Mode current;                  // valid only when enabled
    Mode[] modes;
    ScaleFactor scale;
    Transform transform;
    bool primary;
    String mirror_of;              // empty = not mirrored
    Mm width_mm;                   // 0 = unknown
    Mm height_mm;
    OutputFlags flags;
    ColorEncoding encoding;
    uint bits_per_channel;         // 0 = unknown
}

struct State {
    Output[] outputs;
    String serial_of_topology;     // compositor serial or DisplayConfig topology id
}

struct Change {                    // one entry per output in a configuration
    String output_id;
    bool enable;
    Mode mode;                     // when enabling
    int x;
    int y;
    Transform transform;
    ScaleFactor scale;
    bool primary;
}

enum ApplyMode : char { VERIFY, TEMPORARY, PERSISTENT }   // maps: Mutter 0/1/2, wlr test/apply, Windows VALIDATE/APPLY(+SAVE)
enum ApplyOutcome : char { SUCCEEDED, FAILED, CANCELLED_STALE }

struct Configuration { Change[] changes; ApplyMode mode; }

enum Cap : char {
    ENUMERATE, HOTPLUG_EVENTS, SET_MODE, SET_POSITION, SET_SCALE, SET_TRANSFORM,
    SET_PRIMARY, SET_MIRROR, SET_ENABLE, SET_HDR, SET_VRR, SET_COLOR_DEPTH,
    VERIFY_CONFIG, REVERT_LAST_KNOWN,  // REVERT is the shell's job, not the protocol's
    POWER_OFF_OUTPUT, ICC_PROFILE_NAME,
}
enum DisplayEventKind : char { ADDED, REMOVED, CHANGED, TOPOLOGY_CHANGED }
```

```c3
module bleu::color;
import bleu::availability;

typedef Kelvin = uint;             // 1000..25000 is the range of the common references
typedef Level = float;             // reuse bleu::brightness::Level

enum ColorBackend : char { WLR_GAMMA, RANDR_GAMMA, MUTTER, KDE, CG_TRANSFER, WIN_RAMP, PRIVATE_NIGHT_SHIFT }
enum GammaSource : char { NONE, WAYLAND_GAMMA_CONTROL, RANDR, COREGRAPHICS, WIN32_RAMP }

struct ColorState {
    bool night_light_available;
    bool night_light_enabled;
    Kelvin temperature;            // valid only when night light is active
    Level strength;
    bool gamma_available;
    GammaSource gamma;
    String icc_profile;           // empty = not exposed
}

enum Cap : char {
    SET_TEMPERATURE, SET_GAMMA_RAMP, READ_ICC_PROFILE, SET_ICC_PROFILE,
    NIGHT_LIGHT_SCHEDULE,        // V2, private on macOS
    NIGHT_LIGHT_STATE,
}
```

Notes on the model:
* Keep the `Mechanism` split. A display can have a panel level, a DDC level
  and a gamma level at once, and each must be reported and set separately.
* `Control.raw_min` and `raw_max` capture ranges that differ per mechanism
  (sysfs `max_brightness`, dxva2 min/max, KDE 0..10000, Mutter min..max,
  KDE nits overrides). Normalise to `Level` only in the common layer.
* `Output.edid_base64` mirrors KDE's `edid` event. Other backends fill it from
  the EDID read (DDC `0x50` on Linux, `IODisplayCreateInfoDictionary` on macOS,
  registry on Windows; the Windows EDID path is `(UNVERIFIED)`).
* Backend availability: Windows `WMI` and macOS `Night Shift` are not V1.

## 6. Risks and cut lines

**Hard, and what cannot be done without private API or rights.**
* macOS: every panel and DDC route except `CGSetDisplayTransferByTable`,
  CG configuration, and reconfiguration callbacks is private (DisplayServices,
  CoreDisplay, IOAVService, CoreBrightness). They need runtime `dlsym`, can
  break on any OS update, and can block Mac App Store distribution (`(UNVERIFIED)`
  distribution rules: not checked). The Lunar code path that switches between
  them is tied to observed behaviour, not a documented contract.
* macOS: brightness keys need Accessibility trust for an event tap
  (`(single-source)`).
* Linux: the logind route requires a foreground session. Background services
  (a daemon started by the DE or at boot) get `Session is not in foreground`
  (L-SBD 671-720), so the shell must run inside the user's session.
* Linux DDC: needs `i2c-dev` and device permissions; permissions default is
  `(UNVERIFIED)`; a group rule is needed on most distributions.
* Windows: internal panel IOCTL depends on driver support (single-source
  note in the brightness fork); DDC depends on the monitor and adapter. The
  WMI route is `(UNVERIFIED)`.
* Wayland: there is no portable brightness protocol. Panel brightness is
  compositor-owned (Mutter `Backlight`, KDE `brightness`). sway and niri expose
  no brightness at all (D5, D7).
* Gamma: wlr-gamma-control is exclusive per output (failed on conflict, WL-GC).
  Mutter and KDE do not expose it; they have their own paths.
* Output configuration: wlr v4 has no HDR, colour depth, or mirroring field
  (D3). KDE has more, but only on KDE. Mutter uses a different D-Bus shape.
  No cross-compositor revert exists (WL-OM `failed` reverts only the failed apply;
  Windows has no revert at all; Mutter and KDE do not document a revert).
* Night light: no common protocol across compositors (Mutter exposes only
  `NightLightSupported`, KDE has none in these XMLs). The Windows blob is
  undocumented (`(UNVERIFIED)`).
* EDR/XDR: the Windows numbers are documented (SDR white, HDR and WCG types), the
  macOS selectors are `(single-source)`, and the macOS 26.3 breakage is
  `(UNVERIFIED)`.
* Nits: only where the OS exposes a linear or override value (DisplayServices
  linear, KDE overrides). Treat as an estimate.
* Reported levels mean different things per mechanism: sysfs `actual_brightness`
  is hardware read-back, `brightness` is the driver setpoint, gamma is a
  software multiplier, KDE `brightness` is a multiplier, and the Windows
  IOCTL level is the policy setting (section 2.1 and 2.3). Keep the mechanism
  name in every reported value.

**Recommended V1 cut (lowest-risk, public APIs first):**
* `brightness` V1: Linux `logind` backlight (with sysfs read) and logind `leds`
  for keyboard backlight; Windows `\\.\LCD` IOCTL for internal and dxva2
  high-level for external; macOS `DisplayServices` get/set (private, runtime
  resolved). Gamma dimming as its own `GAMMA_TABLE` mechanism on Wayland
  (wlr), Windows (`SetDeviceGammaRamp`), and macOS (`CGSetDisplayTransferByTable`).
* Defer: DDC on macOS (Intel and Apple Silicon) to V2 (private, larger
  surface), overlay dimming (Lunar only), EDR/XDR writes, ALS toggle (KDE only
  in these sources), nits, Windows WMI, Windows SDR white write (undocumented),
  `CoreDisplay_Display_SetAutoBrightnessIsEnabled`.
* `display` V1: enumeration and hotplug on Linux via wl_output + xdg-output
  (read-only, universal), wlr output management for apply on wlroots, Mutter
  `GetCurrentState` and `ApplyMonitorsConfig` as a second apply route;
  macOS CoreGraphics read plus the configuration transaction; Windows
  `QueryDisplayConfig` read plus `SetDisplayConfig` validate-then-apply.
* Defer: KDE-only protocol features beyond brightness and ICC (HDR, VRR policy,
  colour depth), HDR/VRR/colour-depth writes everywhere, the Windows revert
  (implement in the service: keep last known configuration), mirroring on
  wlr (not expressible), private CGS mode changes.
* `color` V1: wlr-gamma-control kelvin (redshift table), `SetDeviceGammaRamp`
  on Windows, `CGSetDisplayTransferByTable` on macOS. Defer Night Shift
  (private CoreBrightness, selectors unverified), the Windows night-light blob,
  ICC on every platform except reading the KDE name.

**Doubts for the lead.**
* Items the task named that are wrong or not in the sources: `GUID_VIDEO_BRIGHTNESS`
  (the real GUID is `GUID_DEVICE_POWER_POLICY_VIDEO_BRIGHTNESS`), `DISPLAYCONFIG_DEVICE_INFO_SET_SDR_WHITE_LEVEL`
  (absent from mingw), `CoreDisplay_Display_GetCurrentNits` (not in the Lunar
  bridging header; the closest is `GetLinearBrightness`), the macOS 26.3 XDR
  breakage (not in the Lunar code at this pin), `CGConfigureDisplayWithDisplayMode`
  and `CGDisplayCopyAllDisplayModes` (not in any fetched source).
* Lunar's order (appleNative → DDC → network) is confirmed in `getBestControl`,
  but its DDC gate (`supportsGammaByDefault`) is a Lunar-specific condition.
* Apple documentation was unreadable in this run. Every macOS public-API claim
  should be checked against the SDK headers on a Mac before it is coded.
* Two Learn pages for `DisplayConfigGetDeviceInfo` and the WMI classes were
  not retrieved, so their details rest on the headers only.
* This spike did not read ddcutil's own source or udev rules, so the Linux
  i2c permission model is `(UNVERIFIED)`.
