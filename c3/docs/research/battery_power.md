# Research: `battery` and `power` services

Status: read-only spike, 2026-10-20. Nothing was built or run on hardware. Every
native fact below was read from a primary source (spec, kernel doc, Apple/Microsoft
header or Learn page, upstream C source) or from a published crate or source file
that was fetched and read. Claims carry tags that refer to the double-validation
table in section 4:

* `[Vn]`: validated, two sources listed in section 4.
* `(single-source)`: one source only, named in section 4.
* `(UNVERIFIED)`: not confirmed. Do not implement from the claim without checking.

Both services are covered in one note because they read the same power-source
state (UPower, sysfs, IOPS/IORegistry, GetSystemPowerStatus) and share the sleep,
lid and AC events.

Route to the primary sources (all fetched during this spike):

* UPower spec: `https://gitlab.freedesktop.org/upower/upower/-/raw/master/dbus/org.freedesktop.UPower.Device.xml` and `.../org.freedesktop.UPower.xml`
* Kernel ABI: `https://raw.githubusercontent.com/torvalds/linux/master/Documentation/ABI/testing/sysfs-class-power` and `.../Documentation/power/power_supply_class.rst`
* power-profiles-daemon upstream: `https://gitlab.freedesktop.org/upower/power-profiles-daemon/-/raw/main/src/power-profiles-daemon.c` and `.../src/org.freedesktop.UPower.PowerProfiles.xml.in`
* logind: `https://www.freedesktop.org/software/systemd/man/latest/org.freedesktop.login1.html` and `https://raw.githubusercontent.com/systemd/systemd/main/docs/INHIBITOR_LOCKS.md`
* Microsoft Learn: `https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-system_power_status`, `.../power/battery-information-str`, `.../power/battery-status-str`, `.../power/battery-wait-status-str`, `.../power/power-setting-guids`, `.../api/powrprof/nf-powrprof-setsuspendstate`, `.../api/winbase/nf-winbase-powercreaterequest`, `.../api/winbase/nf-winbase-powersetrequest`, `.../api/winbase/nf-winbase-powerclearrequest`, `.../api/winbase/nf-winbase-setthreadexecutionstate`, `.../api/winuser/nf-winuser-exitwindowsex`, `.../api/winuser/nf-winuser-lockworkstation`, `.../api/winuser/nf-winuser-registerpowersettingnotification`
* Apple: `developer.apple.com/documentation/iokit/iopowersources_h` returns only a JavaScript shell (no text). The XNU `IOPM.h` header is fetched but has no assertion or power-source API. Apple API facts therefore come from generated Rust bindings (section 4 says which).
* Rust crates (static.crates.io tarballs, extracted and read): `starship-battery` 0.10.0, `upower_dbus` 0.3.2, `io-kit-sys` 0.4.1, `objc2-io-kit` 0.3.2, `objc2-foundation` 0.3.2, `keepawake` 0.6.1, `windows-sys` 0.59.0.
* Python: `psutil` master (`_pslinux.py`, `_pswindows.py`, `_psosx.py`).

---

## 1. What a shell needs

battery, in priority order:

1. Summary: display percentage 0..100, state (charging, discharging, full, empty, not charging, unknown), and power source kind (AC or battery). Used by a bar widget. Sources: UPower DisplayDevice; `GetSystemPowerStatus` on Windows; IOPS on macOS.
2. Time to empty and time to full, as a `Duration`, with an explicit "unknown" value. Sentinels differ per OS (section 2).
3. Per-source list with stable id, kind (battery, line power, UPS, peripheral), vendor, model, serial and technology. Needed by settings panels and multi-battery laptops.
4. Energy rate (signed power: charging vs discharging), voltage and temperature.
5. Health: full capacity against design capacity, cycle count.
6. AC online, and adapter wattage where the OS reports it (macOS only, section 2.2).
7. Low-battery warning level (UPower `WarningLevel`, Windows `BATTERY_CRITICAL`, IOPS warning level).
8. Peripheral batteries (mice, keyboards, headsets via UPower device types). Linux only in v1; see section 6.
9. Charge thresholds (set start and end limits). Linux only per the sources read.
10. History and statistics (optional). UPower `GetHistory` and `GetStatistics` only.
11. Change events for all of the above, so the shell does not poll.

power, in priority order:

1. Power profile: list, active profile, and the reason a profile is degraded (Linux PPD `PerformanceDegraded`); Windows overlay scheme; macOS Low Power Mode as a read-only bool.
2. Low Power Mode and battery saver: current state and change events.
3. Capability probing before offering each action (`CanSuspend`, `CanHibernate`, `CanPowerOff`, `CanReboot`, `CanHybridSleep` on Linux; equivalent checks elsewhere). Feeds the `Cap` enum.
4. Actions: suspend, hibernate, hybrid sleep, reboot, shutdown, lock, logout. Each must respect polkit or the OS permission model.
5. Inhibitors: keep-awake (idle, display, system), save-before-sleep delay locks, shutdown block.
6. Sleep and resume notification, with a delay barrier that the consumer must release before the machine sleeps.
7. Lid and AC events (lid closed, external power connected or removed).
8. Idle hint (Linux logind).
9. Charge-limit control (Linux only in v1).

---

## 2. Per-platform native route (Linux / macOS / Windows)

### 2.1 Linux

#### L-B1. UPower over D-Bus (battery, primary route)

**Interface** (`org.freedesktop.UPower` service, system bus):

* Root: object `/org/freedesktop/UPower`, interface `org.freedesktop.UPower`. Methods: `EnumerateDevices() -> ao devices`, `GetDisplayDevice() -> o`, `GetCriticalAction() -> s action`, `EnumerateKbdBacklights() -> ao`, `GetCriticalAction`. Signals: `DeviceAdded(o device)`, `DeviceRemoved(o device)`. Properties: `DaemonVersion s`, `OnBattery b`, `LidIsClosed b`, `LidIsPresent b`. `[V1 U2]`
* Display device: object `/org/freedesktop/UPower/devices/DisplayDevice`, fixed path. `[V1]`
* Device objects: interface `org.freedesktop.UPower.Device`. Methods: `Refresh()` (debug mode only, per spec), `GetHistory(s type, u timespan, u resolution) -> a(udu) data`, `GetStatistics(s type) -> a(dd) data`, `EnableChargeThreshold(b chargeThreshold)`. `[V1]`
* Device properties with their types (all `access="read"` except as noted): `NativePath s`, `Vendor s`, `Model s`, `Serial s`, `UpdateTime t`, `Type u`, `PowerSupply b`, `HasHistory b`, `HasStatistics b`, `Online b`, `Energy d`, `EnergyEmpty d`, `EnergyFull d`, `EnergyFullDesign d`, `EnergyRate d`, `Voltage d`, `ChargeCycles i`, `Luminosity d` (deprecated), `TimeToEmpty x`, `TimeToFull x`, `Percentage d`, `Temperature d`, `IsPresent b`, `State u`, `IsRechargeable b`, `Capacity d`, `Technology u`, `WarningLevel u`, `BatteryLevel u`, `IconName s`, `ChargeStartThreshold u`, `ChargeEndThreshold u`, `ChargeThresholdEnabled b`, `ChargeThresholdSupported b`, `ChargeThresholdSettingsSupported u` (bitmask), `VoltageMinDesign d`, `VoltageMaxDesign d`, `CapacityLevel s`. `[V1][V5]`

**Call sequence** (happy path, pseudocode):

1. Connect to the system bus. `[V1]`
2. `EnumerateDevices()`; for each path, read `Type`. Ignore `Type` 0.
3. `GetDisplayDevice()` for the summary. Read all properties with `GetAll`. `[V1]`
4. For each device, subscribe to `org.freedesktop.DBus.Properties.PropertiesChanged` on its path. Subscribe to `DeviceAdded` and `DeviceRemoved` on the root. `[V1]`
5. On `PropertiesChanged`, rebuild the snapshot from the changed object and publish it.
6. To change thresholds: `EnableChargeThreshold(b)` after checking `ChargeThresholdSupported`. The polkit action for this call is `(UNVERIFIED)`; it is not in any document read.
7. Stop: unsubscribe the signal match rules and release the connection. No native teardown is needed.

**Data layouts and constants** (values as written in the spec):

* `Type` (u): 0 Unknown, 1 Line Power, 2 Battery, 3 UPS, 4 Monitor, 5 Mouse, 6 Keyboard, 7 Pda, 8 Phone, 9 Media Player, 10 Tablet, 11 Computer, 12 Gaming Input, 13 Pen, 14 Touchpad, 15 Modem, 16 Network, 17 Headset, 18 Speakers, 19 Headphones, 20 Video, 21 Other Audio, 22 (the spec continues past 22; not all values were read). `[V4]`
* `State` (u), valid only for batteries: 0 Unknown, 1 Charging, 2 Discharging, 3 Empty, 4 Fully charged, 5 Pending charge, 6 Pending discharge. `[V1]`
* `Technology` (u): 0 Unknown, 1 Lithium ion, 2 Lithium polymer, 3 Lithium iron phosphate, 4 Lead acid, 5 Nickel cadmium, 6 Nickel metal hydride. `[V1]`
* `WarningLevel` (u): 0 Unknown, 1 None, 2 Discharging (UPS only), 3 Low, 4 Critical, 5 Action. `[V1]`
* `BatteryLevel` (u): 0 Unknown, 1 None (the device uses a percentage instead), 3 Low, 4 Critical, 6 Normal, 7 High, 8 Full. `[V1]`
* `ChargeThresholdSettingsSupported` (u bitmask): 1 start threshold, 2 end threshold, 4 firmware-controlled optimised charging. `[V1]`
* Units: `Energy`, `EnergyEmpty`, `EnergyFull`, `EnergyFullDesign` in Wh. `EnergyRate` in W; positive means discharging, negative means charging. `Voltage` in V. `Temperature` in degrees Celsius. `TimeToEmpty` and `TimeToFull` in seconds. `Percentage` and `Capacity` in 0..100. `UpdateTime` in seconds since the epoch. `[V1]`
* Threshold sentinel: `ChargeStartThreshold` or `ChargeEndThreshold` equal to `G_MAXUINT` means UPower skips writing that sysfs attribute. `[V5]`

**Permissions:** UPower is a system daemon; no polkit action was read for any call here. `EnableChargeThreshold` authorisation is `(UNVERIFIED)`.

**Pitfalls:**

* `Energy*` properties are not valid unless `Type` is battery; `State` is battery-only; `Online` is line-power-only. `[V1]`
* `TimeToEmpty` and `TimeToFull` are 0 when unknown, not negative. `[V3]`
* `ChargeCycles` is -1 when unknown. `[V3]`
* `EnergyRate` sign is the opposite of sysfs `current_now`, which is negative when discharging (section 2.1 L-B2). Normalise at the boundary. `[V2]`
* `Percentage` may be coarser than `(energy - empty) / (full - empty)` on devices that only report a percentage; prefer `Percentage` for display and `Energy*` for health. `[V1]`
* The spec says `Refresh()` only works when the daemon runs in debug mode. Do not depend on it. `[V1]`

#### L-B2. sysfs `/sys/class/power_supply/<name>/` (fallback and non-UPower systems)

**Interface:** plain files, one attribute per file. The kernel ABI in `Documentation/ABI/testing/sysfs-class-power` defines the attributes; `power_supply_class.rst` gives the units. `[V6][V7]`

Attributes used (name, unit, meaning):

* `type`: `Battery`, `UPS`, `Mains`, `USB`, `Wireless`. `[V9]`
* `present`: 0 absent, 1 present. If missing, treat as present. `(single-source: ABI)`
* `status`: `Unknown`, `Charging`, `Discharging`, `Not charging`, `Full`. `(single-source: ABI)`
* `capacity`: integer percent 0..100. `capacity_level`: `Unknown`, `Critical`, `Low`, `Normal`, `High`, `Full`. `(single-source: ABI)`
* `energy_now`, `energy_full`, `energy_full_design`: µWh. `[V6]`
* `charge_now`, `charge_full`, `charge_full_design`: µAh. `[V6]`
* `power_now`: µW. `[V6]`. `current_now`: µA, negative when discharging, positive when charging. `(single-source: ABI for sign)`
* `voltage_now`, `voltage_max_design`, `voltage_min_design`, `voltage_present`: µV. `[V6]`
* `temp`: 1/10 °C. `[V6]`
* `cycle_count`: integer; 0 means not available. `[V12]`
* `time_to_empty_now` (kernel class name `TIME_TO_EMPTY`): seconds. `[V15]` (the ABI file read did not list it; the class doc names it).
* `manufacturer`, `model_name`, `serial_number`, `technology`, `health`. `(single-source: ABI)`
* `online`: 0 offline, 1 online fixed, 2 online programmable (USB and Mains). `(single-source: ABI)`
* `charge_control_start_threshold`, `charge_control_end_threshold`: 0..100 percent; "drivers round written values to the nearest supported value; reading back shows the actual threshold". `[V7]`
* `charge_behaviour`: `auto`, `inhibit-charge`, `inhibit-charge-awake`, `force-discharge`. `(single-source: ABI)`
* `scope`: read by starship-battery `sysfs/fs.rs` to select `Device` or `System`. It is not in the kernel ABI file read. `(UNVERIFIED)`

**Call sequence:**

1. List `/sys/class/power_supply/`. Keep entries whose `type` is `Battery`. (psutil matches by name prefix `BAT`; the kernel `type` file is the safer test.) `[V15]`
2. For each battery, read the attributes. Use the fallback order below for each quantity.
3. Watch for changes with udev `power_supply` uevents or inotify on the directory. `(UNVERIFIED: udev and uevent details not read)`
4. Stop: close the watch.

**Fallback order** (from starship-battery `sysfs/source.rs`; the comments cite UPower's source, which was not read):

* Energy now: `energy_now`, else `energy_avg`, else `charge_now` (or `charge_avg`) times the voltage, else `capacity` percent times `energy_full`. `[V13]`
* Energy full: `energy_full`, else `charge_full` times the voltage, else `energy_full_design`, else 0. `[V13]`
* Rate: `power_now`, else `current_now`. If `charge_full` is present, `current_now` is µA and is multiplied by the design voltage. Otherwise it is µW. Then zero a rate above 100 W, below 10 µW, or equal to 65535 W (the ACPI "ones" value). `[V13]`
* State of charge: `capacity`, else energy now divided by energy full, else 0. `[V13]`
* `cycle_count` of 0 is reported as unknown. `[V12]`

**Data layouts:** `status`, `type`, `technology` are ASCII strings; numeric attributes are decimal text with a trailing newline.

**Permissions:** reads need no privilege. Writing `charge_control_*` needs root; the file mode was not checked `(UNVERIFIED)`.

**Pitfalls:**

* Some drivers provide `energy_*` and others provide `charge_*`. The fallback order above is required, not optional. `[V13]`
* Units vary by attribute. Do not read a value without knowing its unit: µWh and µAh are different quantities. `[V6]`
* The `charge_*`/`energy_*` pairs differ in unit, and the kernel warns they must not be mixed. `[V6]`

#### L-P1. power-profiles-daemon (performance, balanced, power-saver)

**Ownership:** the bus names `org.freedesktop.UPower.PowerProfiles` (modern) and `net.hadess.PowerProfiles` (legacy) are served by **power-profiles-daemon**, not by UPower. The UPower spec XML has no PowerProfiles interface. `[V16]`

**Interface** (modern, `org.freedesktop.UPower.PowerProfiles`, object path `/org/freedesktop/UPower/PowerProfiles`):

* `HoldProfile(s profile, s reason, s application_id) -> u cookie`. `[V17]`
* `ReleaseProfile(u cookie)`. `[V17]`
* `SetActionEnabled(s action, b enabled)` (modern only; the legacy interface rejects it). `[V17]`
* Signal `ProfileReleased(u cookie)`. `[V17]`
* Properties: `ActiveProfile s` (readwrite), `PerformanceInhibited s` (deprecated, unused since 0.9), `PerformanceDegraded s` (`"lap-detected"`, `"high-operating-temperature"`, or `""`), `Profiles aa{sv}` (keys `Profile` and `Driver`), `Actions as` (legacy), `ActionsInfo aa{sv}` (keys `Action`, `Description`, `Enabled`; modern only), `ActiveProfileHolds aa{sv}` (keys `ApplicationId`, `Profile`, `Reason`), `Version s`, `BatteryAware b` (readwrite). `[V18]`

Legacy interface: `net.hadess.PowerProfiles` at `/net/hadess/PowerProfiles`. The same profile properties; no `SetActionEnabled`; `ActionsInfo` is not returned. `[V16][V59]`

**Profile names:** `"power-saver"`, `"balanced"`, `"performance"`. `Profiles` lists one entry per type, sorted in that order. `[V18]`

**Hold rules** (from upstream `hold_profile`, `release_profile`, `holder_disappeared`):

* Only `performance` and `power-saver` may be held, else `INVALID_ARGS`. The profile must be available, else `INVALID_ARGS`. `[V17]`
* The hold is tied to the caller's bus name. If that name disappears, the hold is dropped (`holder_disappeared`). `[V17]`
* `ReleaseProfile` with an unknown cookie returns `INVALID_ARGS`. `[V17]`
* `HoldProfile` requires polkit action `org.freedesktop.UPower.PowerProfiles.hold-profile`. `SetActionEnabled` requires `org.freedesktop.UPower.PowerProfiles.configure-action`. `[V17]`

**Call sequence:**

1. Connect to the system bus. Call `GetAll` on the modern interface; if the name is absent, use the legacy interface. `[V16]`
2. Read `ActiveProfile`, `Profiles`, `PerformanceDegraded`, `ActiveProfileHolds`, `BatteryAware`.
3. Subscribe to `PropertiesChanged` on the chosen interface. `[V18]`
4. Set: write `ActiveProfile` as a string.
5. Hold: `cookie = HoldProfile("power-saver", reason, app_id)`. Keep the bus connection alive, because the hold ends with the name. Release with `ReleaseProfile(cookie)`. `[V17]`

**Permissions:** the polkit actions above, plus the bus name ownership rule.

**Pitfalls:**

* On Linux there is no direct "Low Power Mode" flag. The nearest mapping is `power-saver` (this mapping is an inference, `(UNVERIFIED)` against any upstream statement).
* `ActionsInfo` is modern-only; a client must check the interface it is talking to. `[V59]`
* A hold changes the active profile only if the target differs; `ActiveProfileHolds` changes even when `ActiveProfile` does not. `[V17]`

#### L-P2. TLP and tuned (fallbacks)

Not read. `(UNVERIFIED)`. Recommend leaving out of v1 (section 6).

#### L-P3. logind (actions, inhibitors, lid, idle, lock)

**Interface** (service `org.freedesktop.login1`, object `/org/freedesktop/login1`, interface `org.freedesktop.login1.Manager`, system bus): `[V19]`

* Capability methods, each returning `s`: `CanPowerOff`, `CanReboot`, `CanHalt`, `CanSuspend`, `CanHibernate`, `CanHybridSleep`, `CanSuspendThenHibernate`, `CanSleep`, `CanRebootParameter`, `CanRebootToFirmwareSetup`, `CanRebootToBootLoaderMenu`, `CanRebootToBootLoaderEntry`. `[V19]`
* Return values: `"na"`, `"yes"`, `"no"`, `"challenge"`, `"inhibited"`, `"inhibitor-blocked"`, `"challenge-inhibitor-blocked"`. `"na"` means hardware, kernel or drivers do not support it. `"challenge"` means polkit will prompt. `(single-source: login1 man page)`
* Action methods: `PowerOff(b interactive)`, `Reboot(b)`, `Halt(b)`, `Suspend(b)`, `Hibernate(b)`, `HybridSleep(b)`, `SuspendThenHibernate(b)`, `Sleep()` (picks the best supported sleep operation). Each has a `*WithFlags(t flags)` form. `SD_LOGIND_ROOT_CHECK_INHIBITORS = 1 << 0`, `SD_LOGIND_KEXEC_REBOOT = 1 << 1`. `[V19]`
* `Inhibit(s what, s who, s why, s mode) -> h pipe_fd`. `what` is a colon-separated list of `shutdown`, `sleep`, `idle`, `handle-power-key`, `handle-suspend-key`, `handle-hibernate-key`, `handle-lid-switch`. `mode` is `block`, `block-weak` or `delay`. `delay` is valid only for `sleep` and `shutdown`. `[V21]`
* `ListInhibitors() -> a(ssssuu)`. `[V19]`
* Session control: `LockSession(s)`, `UnlockSession(s)`, `LockSessions()`, `UnlockSessions()`, `TerminateUser(u)`, `TerminateSession(s)`, `ActivateSession(s)`. `[V19]`
* Session object methods: `Lock()`, `Unlock()` (signals), `SetIdleHint(b idle)`, `Terminate()`. `[V19]`
* Signals: `PrepareForSleep(b start)`, `PrepareForShutdown(b start)`. `[V19][V21]`
* Manager properties: `LidClosed b` ("true when the lid of a laptop is closed"), `OnExternalPower b`, `Docked b`, `IdleHint b`, `IdleSinceHint t`, `IdleSinceHintMonotonic t`, `BlockInhibited s`, `DelayInhibited s`, `PreparingForShutdown b`, `PreparingForSleep b`. `[V19]`

**Inhibitor semantics** (from `INHIBITOR_LOCKS.md`):

* An inhibitor is a file descriptor returned by `Inhibit`. Closing it, or the process dying, releases the lock. `[V21]`
* A delay lock is for applications that must act before sleep (save data, lock the screen). The lock is held until the application closes the fd after receiving `PrepareForSleep(true)`. Delay is bounded by `InhibitDelayMaxUSec` (example value 5000000 µs in the doc). `[V21][V23]`
* Watching `PrepareForSleep(true)` without holding a delay lock is racy. `[V21]`
* A delay-lock application should re-take the lock on `PrepareForSleep(false)` for the next cycle. `[V21]`
* Lid-switch locks may only use `block` mode. `[V21]` (source: `INHIBITOR_LOCKS.md`, section on lid-switch locks)
* Idle block locks can stop auto-suspend on mobile devices and should be used sparingly. `[V21]`

**Call sequence (save-before-sleep, delay lock):**

1. `fd = Inhibit("sleep", who, why, "delay")`. `[V21]`
2. Subscribe to `PrepareForSleep` on the manager.
3. On `PrepareForSleep(true)`: do the work, then `close(fd)` within `InhibitDelayMaxUSec`. `[V21]`
4. On `PrepareForSleep(false)`: `fd = Inhibit(...)` again. `[V21]`

**Call sequence (keep-awake, block):** `fd = Inhibit("idle", who, why, "block")`; close `fd` to stop. `[V21]`

**Permissions (polkit):** `org.freedesktop.login1.power-off`, `.reboot`, `.halt`, `.suspend`, `.hibernate` and their `-ignore-inhibit` and `-multiple-sessions` variants; inhibit actions `org.freedesktop.login1.inhibit-block-sleep`, `.inhibit-delay-sleep`, `.inhibit-block-shutdown`, `.inhibit-delay-shutdown`, `.inhibit-block-idle`, `.inhibit-handle-lid-switch` and the key-handling variants. `[V22]`

**Pitfalls:**

* `Can*` results are per user; the same machine can return `"yes"` for one user and `"challenge"` for another. `(single-source)`
* `Suspend` ignores inhibitors unless the caller has the `-ignore-inhibit` privilege; blocking inhibitors make the call fail with a clear error. `(single-source: login1 man page)`
* `SuspendThenHibernate` needs the RTC wake configuration; not tested.

#### L-P4. Session lock and logout

Use logind: `LockSession(session_id)` on the manager, or listen for `Lock` and `Unlock` signals on the session object. Logout is `TerminateSession(session_id)` or `TerminateUser(uid)`. polkit actions for these calls were not read `(UNVERIFIED)`.

### 2.2 macOS

#### M-B1. IOPowerSources (summary and events)

**Functions** (`IOKit.framework`; from `io-kit-sys` 0.4.1 `src/ps/power_sources.rs`, which declares an `extern "C"` block): `[V25]`

* `IOPSCopyPowerSourcesInfo() -> CFTypeRef` (blob)
* `IOPSCopyPowerSourcesList(blob) -> CFArrayRef`
* `IOPSGetPowerSourceDescription(blob, ps) -> CFDictionaryRef`
* `IOPSGetProvidingPowerSourceType(blob) -> CFStringRef` (values `"AC Power"`, `"Battery Power"`, `"Off Line"`) `[V24]`
* `IOPSNotificationCreateRunLoopSource(callback, context) -> CFRunLoopSourceRef` (argument list not printed; read the binding before use)
* `IOPSCopyExternalPowerAdapterDetails() -> CFDictionaryRef`
* `IOPSGetBatteryWarningLevel() -> IOPSLowBatteryWarningLevel` with values None 1, Early 2, Final 3. `[V25]`
* Notification keys: `kIOPSNotifyPowerSource`, `kIOPSNotifyTimeRemaining`, `kIOPSNotifyLowBattery`, `kIOPSNotifyAttach`, `kIOPSNotifyAnyPowerSource`. `(single-source)`
* `IOPSGetTimeRemainingEstimate`: not in `io-kit-sys` and not in any fetched source. `(UNVERIFIED)`

**Keys** (`IOPSKeys.h`, from `io-kit-sys` `src/ps/keys.rs`, which says it exports from that header): `[V24]`

* `"Current Capacity"` (`kIOPSCurrentCapacityKey`), `"Max Capacity"`, `"DesignCapacity"`, `"Nominal Capacity"`
* `"Time to Empty"` (`kIOPSTimeToEmptyKey`), `"Time to Full Charge"` (`kIOPSTimeToFullChargeKey`). Units are `(UNVERIFIED)`; the IORegistry `TimeRemaining` is in minutes (M-B2).
* `"Is Charging"`, `"Is Charged"`, `"Is Finishing Charge"`, `"Is Present"`, `"Power Source State"` (values `"AC Power"`, `"Battery Power"`, `"Off Line"`), `"Power Source ID"`
* `"Voltage"`, `"Current"`, `"Temperature"`, `"Name"`, `"Type"` (value `"InternalBattery"`, `"UPS"`), `"Transport Type"`
* `"BatteryHealth"`, `"BatteryHealthCondition"`, `"BatteryFailureModes"`, `"HealthConfidence"`, `"Internal Failure"`, `"Vendor ID"`, `"Product ID"`, `"Hardware Serial Number"`
* Adapter dictionary (`IOPSCopyExternalPowerAdapterDetails`): `"AdapterID"`, `"Watts"`, `"AdapterRevision"`, `"SerialNumber"`, `"FamilyCode"`, `"Current"`, `"Source"`. `[V31]`

**Call sequence:**

1. `blob = IOPSCopyPowerSourcesInfo()`.
2. `list = IOPSCopyPowerSourcesList(blob)`; for each element, `desc = IOPSGetPowerSourceDescription(blob, ps)`.
3. Read the keys above. `"Power Source State"` gives AC or battery; `IOPSGetProvidingPowerSourceType` gives the same for the whole system.
4. Events: `src = IOPSNotificationCreateRunLoopSource(cb, ctx)`; add it to the run loop; on callback, repeat from step 1. Stop: remove the source from the run loop and `CFRelease`. `(single-source: io-kit-sys signature)`
5. Release `blob` and `list` (CF ownership rules, standard).

**Permissions:** none (public API).

**Pitfalls:**

* On Apple-silicon machines `MaxCapacity` and `CurrentCapacity` in the IORegistry report percentages, so the raw keys must be used (M-B2). `(single-source: starship-battery; its comment cites this behaviour)`
* The Apple IOPS documentation page is not readable from the reachable hosts. Each function name above is therefore `(single-source)` on the binding.

#### M-B2. AppleSmartBattery IORegistry (detail: health, temperature, cycles, adapter wattage)

**Service match:** starship-battery matches the IORegistry class **`IOPMPowerSource`** (its `IOPM_SERVICE_NAME` constant), not `AppleSmartBattery`. The brief named `AppleSmartBattery`; whether the two classes expose the same keys is `(UNVERIFIED)`. `[V27]`

**Call sequence** (starship-battery `darwin/iokit/`):

1. `IOMasterPort(MACH_PORT_NULL, &port)`.
2. `match = IOServiceMatching("IOPMPowerSource")`.
3. `IOServiceGetMatchingServices(port, match, &iter)`.
4. For each `obj = IOIteratorNext(iter)`: `IORegistryEntryCreateCFProperties(obj, &props, kCFAllocatorDefault, 0)`.
5. Read the keys below, then `IOObjectRelease(obj)`.
6. Poll: repeat from step 4 on each refresh. Notification route: see M-B1 (IOPS run-loop source).

**Keys** (names `[V27]`; units from starship, `(single-source)` on units):

* `ExternalConnected` (bool), `IsCharging` (bool), `FullyCharged` (bool), `BatteryInstalled` (bool).
* `Voltage`: mV. `Amperage`: mA, signed in the IORegistry; starship takes `abs()` and discards the sign. `[V29]`
* `DesignCapacity`: mAh. `MaxCapacity` and `CurrentCapacity`: mAh. Prefer `AppleRawMaxCapacity` and `AppleRawCurrentCapacity` when present (starship). `(single-source)`
* `Temperature`: starship divides by 100 and reports Celsius. The brief says 0.01 K. Both cannot be right; `(UNVERIFIED)` against Apple. `[V28]`
* `CycleCount`: integer. `TimeRemaining`: minutes; `i32::MAX` means unknown (starship). `(single-source)`
* Identity: `Manufacturer`, `DeviceName`, `BatterySerialNumber` (starship). The IOPM header key names in `io-kit-sys` are `Model` and `Serial`. Which set is present on current macOS is `(UNVERIFIED)`. `[V30]`
* `AdapterDetails` (dictionary): `Watts`, `Amperage`, `Voltage`, `ID`, `Revision`, `SerialNumber`, `Family`, `Description`, `SourceID`, `ErrorFlags`, `SharedSource`, `Cloaked`. The key names are `[V31]`; the values are the same key strings in `io-kit-sys`, not measured.

**Battery state mapping** (starship `darwin/device.rs`): not external connected means discharging; else charging when `IsCharging`; else empty when current capacity is zero; else full when `FullyCharged`; else unknown. `(single-source)`

**Time mapping:** time to full is `TimeRemaining` only while charging; time to empty is `TimeRemaining` only while discharging. `(single-source)`

**Permissions:** none (read-only IORegistry).

**Pitfalls:**

* The key set is private; Apple does not document it. Each key is `(single-source)` or `[V27]`/`[V30]` as stated.
* `Amperage` is documented as signed in the brief and in the previous attempt's notes. Starship discards the sign. Bleu must keep it. The 64-bit width claim is `(UNVERIFIED)`; starship reads `i32`.

#### M-P1. Low Power Mode (read) and power saving

* Read: `[[NSProcessInfo processInfo] isLowPowerModeEnabled]`, the Objective-C property `lowPowerModeEnabled`. `[V35]`
* Change notification: `NSProcessInfoPowerStateDidChangeNotification`. `[V35]`
* Set: `pmset -a lowpowermode` (root). Privilege and exact behaviour `(UNVERIFIED)`; not read in any source. Recommend read-only in v1 (section 6).
* Private powerd or `IOPMLowPowerMode` routes: not researched `(UNVERIFIED)`.

#### M-P2. Keep-awake (sleep inhibitors)

**Interface** (`IOKit.framework`, `pwr_mgt`): `[V32]`

* `IOPMAssertionCreateWithName(CFStringRef assertionType, IOPMAssertionLevel level, CFStringRef name, IOPMAssertionID *id) -> IOReturn`. Level `kIOPMAssertionLevelOn = 255`, `kIOPMAssertionLevelOff = 0`. The name may be at most 128 characters.
* `IOPMAssertionRelease(IOPMAssertionID id) -> IOReturn`.
* `IOPMAssertionDeclareUserActivity(name, IOPMUserActiveType, &id)`. `IOPMUserActiveType`: Local 0, Remote 1.
* Assertion type strings used in practice: `"PreventUserIdleSystemSleep"`, `"PreventUserIdleDisplaySleep"`, `"PreventSystemSleep"`. `[V32]`

**Call sequence:**

1. `id = IOPMAssertionCreateWithName("PreventUserIdleSystemSleep", kIOPMAssertionLevelOn, "<reason>", &id)`. `[V32]`
2. To stop: `IOPMAssertionRelease(id)`. `[V32]`

**Pitfalls:** `(UNVERIFIED)`: whether the assertion is released automatically when the process exits. keepawake releases explicitly in `Drop`. `(single-source)`

**Permissions:** none (no entitlement needed for these assertion types in the sources read).

#### M-P3. Sleep and wake notifications

* `IORegisterForSystemPower(...)` registers a callback. `IODeregisterForSystemPower(&notifier)` stops it. `[V33]`
* Messages (generated constants): `kIOMessageCanSystemSleep = 0x270` (idle sleep is pending; the app may veto with `IOCancelPowerChange`, or must acknowledge with `IOAllowPowerChange`), `kIOMessageSystemWillSleep = 0x280` (not abortable; must acknowledge with `IOAllowPowerChange`), `kIOMessageSystemWillPowerOn = 0x320` and `kIOMessageSystemHasPoweredOn = 0x300` (do not acknowledge). `[V33][V34]`
* Acknowledgement: `IOAllowPowerChange(root_port, notification_id)` and `IOCancelPowerChange(...)`; a 30-second window is mentioned in the binding docs. `[V34]`

**Permissions:** none for registration. `(single-source)`

#### M-P4. Sleep, shutdown, restart and lock without privilege

* `IOPMSleepSystem(io_connect_t)`: sleeps the system. The `io_connect_t` comes from `IOPMFindPowerManagement` (not verified). `[V36]`
* `pmset sleepnow`: `(UNVERIFIED)`, not read.
* AppleScript to System Events (`shut down`, `restart`, `sleep`, `log out`): `(UNVERIFIED)`. Automation permission (TCC) is required on current macOS; not verified in this spike.
* Private symbols `SACShutdownSystem`, `SACLockScreenImmediate` in `login.framework`, and `CGSession -suspend`: `(UNVERIFIED)`. Any use must go through `bleu::dl` per ARCHITECTURE.md ("Hidden and undocumented OS APIs").

### 2.3 Windows

#### W-B1. GetSystemPowerStatus (summary; no device access)

**Interface:** `BOOL GetSystemPowerStatus(LPSYSTEM_POWER_STATUS)`. Structure `SYSTEM_POWER_STATUS` (Learn, winbase): `[V44]`

* `BYTE ACLineStatus`: 0 offline, 1 online, 255 unknown.
* `BYTE BatteryFlag`: bit 1 high (above 66 percent), bit 2 low (below 33 percent), bit 4 critical (below 5 percent), bit 8 charging, 128 no system battery, 255 unknown. Zero means not charging and between low and high.
* `BYTE BatteryLifePercent`: 0..100, or 255 unknown.
* `BYTE SystemStatusFlag`: 0 battery saver off, 1 on. `[V44]`
* `DWORD BatteryLifeTime`: seconds remaining, or `-1` (`0xFFFFFFFF`) if unknown or on AC. `[V45]`
* `DWORD BatteryFullLifeTime`: seconds at full charge, or `-1`. `[V45]`

**Call sequence:** `GetSystemPowerStatus(&sps)`; map the fields. Poll, or use the notifications in W-B2 and W-P5.

**Permissions:** none.

**Pitfalls:** `BatteryFlag` 128 means no battery, so a desktop machine returns valid AC data with no battery. The battery saver bit is Windows 10+ (`GUID_POWER_SAVING_STATUS`). `(single-source: Learn)`

#### W-B2. SetupDi and battery-class IOCTLs (per-device detail)

**Enumeration** (starship-battery `windows/ffi/mod.rs`): `[V37]`

1. `SetupDiGetClassDevsW(&GUID_DEVCLASS_BATTERY, NULL, NULL, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE)`.
2. Loop `SetupDiEnumDeviceInterfaces(hdev, NULL, &GUID_DEVCLASS_BATTERY, i, &ifdata)`.
3. `SetupDiGetDeviceInterfaceDetailW` twice (size, then fill) to get the device path.
4. `CreateFileW(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL)`.

`GUID_DEVCLASS_BATTERY` = `{72631E54-78A4-11D0-BCF7-00AA00B7B32A}`. `[V37]`

**IOCTL sequence** (per poll; starship-battery `windows/ffi/mod.rs`):

1. `DeviceIoControl(h, IOCTL_BATTERY_QUERY_TAG, in: DWORD timeout = 0, out: DWORD tag)`. A tag of 0 means the device is not valid. `[V37]`
2. `DeviceIoControl(h, IOCTL_BATTERY_QUERY_INFORMATION, in: BATTERY_QUERY_INFORMATION{BatteryTag = tag, InformationLevel = BatteryInformation (0), AtRate = 0}, out: BATTERY_INFORMATION)`. `[V38]`
3. For the same tag, query other levels the same way: `BatteryTemperature` (2), `BatteryEstimatedTime` (3), `BatteryDeviceName` (4), `BatteryManufactureName` (6), `BatterySerialNumber` (8); strings are read by a two-step size query. `[V37]`
4. `DeviceIoControl(h, IOCTL_BATTERY_QUERY_STATUS, in: BATTERY_WAIT_STATUS{BatteryTag = tag, Timeout = 0, PowerState = 0, LowCapacity = 0, HighCapacity = 0}, out: BATTERY_STATUS)`. `[V40]`
5. Stop: `CloseHandle(h)`; `SetupDiDestroyDeviceInfoList(hdev)`.

**Constants:** `[V37]`

* IOCTL codes: `IOCTL_BATTERY_QUERY_TAG = 0x294040`, `IOCTL_BATTERY_QUERY_INFORMATION = 0x294044`, `IOCTL_BATTERY_QUERY_STATUS = 0x29404C`, `IOCTL_BATTERY_SET_INFORMATION = 0x298048`. Decoded: device type `0x29`, method `METHOD_BUFFERED`, access read (write for SET_INFORMATION), functions `0x10`, `0x11`, `0x13`, `0x12`.
* `BATTERY_CAPACITY_RELATIVE = 0x40000000`, `BATTERY_SYSTEM_BATTERY = 0x80000000`, `BATTERY_IS_SHORT_TERM = 0x20000000` (bits of `Capabilities`). `[V42]`
* `PowerState` bits: `BATTERY_POWER_ON_LINE = 1`, `BATTERY_DISCHARGING = 2`, `BATTERY_CHARGING = 4`, `BATTERY_CRITICAL = 8`. `[V43]`
* Sentinels: `BATTERY_UNKNOWN_CAPACITY = 0xFFFFFFFF`, `BATTERY_UNKNOWN_VOLTAGE = 0xFFFFFFFF`, `BATTERY_UNKNOWN_TIME = 0xFFFFFFFF`, `BATTERY_UNKNOWN_RATE = 0x80000000`. `[V41]`

**Structures** (layouts from `windows-sys` 0.59 and Learn): `[V38][V39][V40]`

* `BATTERY_INFORMATION`: `ULONG Capabilities; UCHAR Technology; UCHAR Reserved[3]; UCHAR Chemistry[4]; ULONG DesignedCapacity; ULONG FullChargedCapacity; ULONG DefaultAlert1; ULONG DefaultAlert2; ULONG CriticalBias; ULONG CycleCount;`
* `BATTERY_STATUS`: `ULONG PowerState; ULONG Capacity; ULONG Voltage; LONG Rate;`
* `BATTERY_WAIT_STATUS`: `ULONG BatteryTag; ULONG Timeout; ULONG PowerState; ULONG LowCapacity; ULONG HighCapacity;`
* `BATTERY_QUERY_INFORMATION`: `ULONG BatteryTag; BATTERY_QUERY_INFORMATION_LEVEL InformationLevel; ULONG AtRate;`

**Units:** capacities and `DesignedCapacity` in mWh; `Rate` in mW (signed). `Voltage` in mV. Unless `Capabilities` has the relative bit, in which case the units are per-hour rates (Learn). `[V39]`

**Sign convention:** starship takes `abs()` of `Rate`, discarding direction. Bleu should derive direction from `PowerState` (`CHARGING` or `DISCHARGING`) and keep the sign. `(single-source: starship)`

**Temperature:** starship converts the `BatteryTemperature` query result as deci-Kelvin. Learn text for that level was not read. `(single-source)`

**Permissions:** the handle is opened with read and write access. Whether a non-administrator can do so was not verified `(UNVERIFIED)`.

**Pitfalls:**

* A relative-capacity battery (`BATTERY_CAPACITY_RELATIVE`) reports rates per hour, not mW. starship skips such batteries; Bleu should either skip or convert. `[V42]`
* `Rate` equal to `BATTERY_UNKNOWN_RATE` means no rate; treat it as 0 when not charging or discharging, as starship does. `[V41]`

#### W-B3. WinRT `Windows.Devices.Power.Battery`

Not read. `(UNVERIFIED)`. Leave out of v1.

#### W-P1. Power modes (overlay scheme)

* Power modes are identified by these GUIDs (Learn, `power-setting-guids`; values also in `windows-sys`): `[V46][V47]`
  * `GUID_MAX_POWER_SAVINGS` = `A1841308-3541-4FAB-BC81-F71556F20B4A`, shown as "Power Saver".
  * `GUID_TYPICAL_POWER_SAVINGS` = `381B4222-F694-41F0-9685-FF5BB260DF2E`, shown as "Automatic" (the balanced profile).
  * `GUID_MIN_POWER_SAVINGS` = `8C5E7FDA-E8BF-4A96-9A85-A6E23A8C635C`, shown as "High Performance". The naming is inverted from what the GUID suggests.
* `PowerSetActiveOverlayScheme` and `PowerGetEffectiveOverlayScheme`: not present in `windows-sys` 0.59 and not in the Learn cache. `(UNVERIFIED)`. Do not implement from memory.
* Battery saver: `SYSTEM_POWER_STATUS.SystemStatusFlag` and `GUID_POWER_SAVING_STATUS` (`E00958C0-C213-4ACE-AC77-FECCED2EEEA5`). `[V44]`

**Call sequence (battery saver):** `RegisterPowerSettingNotification(hwnd, &GUID_POWER_SAVING_STATUS, DEVICE_NOTIFY_WINDOW_HANDLE)`; handle `WM_POWERBROADCAST` with `PBT_POWERSETTINGCHANGE`; unregister with `UnregisterPowerSettingNotification` `(UNVERIFIED)` name. `[V51]`

#### W-P2. Keep-awake

Two routes:

1. Thread-scoped: `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)`. `ES_SYSTEM_REQUIRED = 0x1`, `ES_DISPLAY_REQUIRED = 0x2`, `ES_AWAYMODE_REQUIRED = 0x40` (needs `ES_CONTINUOUS`). `ES_USER_PRESENT` is not supported. The state applies until a later call with `ES_CONTINUOUS` clears it. `[V50]` The value of `ES_CONTINUOUS` was not read `(UNVERIFIED)`.
2. Process-scoped: `PowerCreateRequest(&REASON_CONTEXT) -> HANDLE`, then `PowerSetRequest(h, PowerRequestSystemRequired | PowerRequestDisplayRequired | PowerRequestAwayModeRequired | PowerRequestExecutionRequired)` and `PowerClearRequest(h, type)`. `PowerRequest*` constants: `PowerRequestDisplayRequired = 0`, `PowerRequestSystemRequired = 1`, `PowerRequestAwayModeRequired = 2`, `PowerRequestExecutionRequired = 3`. `[V49]`

Call sequence (route 2): `h = PowerCreateRequest(&ctx)`; `PowerSetRequest(h, PowerRequestSystemRequired)`; to stop, `PowerClearRequest(h, PowerRequestSystemRequired)` then `CloseHandle(h)` (the close step is standard, not read).

`PowerCreateRequest` and `PowerSetRequest` are exported by `kernel32.dll` in `windows-sys`. `[V49]`

**Pitfalls:** route 1 is per thread. Route 2 is the one a service should use. Whether `AwayModeRequired` is valid through `PowerSetRequest` alone `(UNVERIFIED)`.

#### W-P3. Sleep, hibernate, shutdown, reboot, logout, lock

* `SetSuspendState(BOOLEAN bHibernate, BOOLEAN bForce, BOOLEAN bWakeupEventsDisabled) -> BOOLEAN` (powrprof.dll). `bHibernate` TRUE hibernates, FALSE suspends. `bForce` has no effect. `[V48]`
* Hibernation availability (hiberfil configured) `(UNVERIFIED)`. Probing it reliably needs a second source (powercfg or the registry); not researched.
* `InitiateSystemShutdownExW(lpMachineName, lpMessage, dwTimeout, bForceAppsClosed, bRebootAfterShutdown, dwReason) -> BOOL` (advapi32.dll). Signature from `windows-sys` `[V52]`; Learn page not in the cache, so semantics `(single-source)`. Shutdown privilege `SeShutdownPrivilege` `(UNVERIFIED)`.
* `ExitWindowsEx(uFlags, dwReason)`: `EWX_LOGOFF = 0`, `EWX_HYBRID_SHUTDOWN = 0x00400000`. `[V53]`
* `LockWorkStation() -> BOOL` (user32.dll). Learn page fetched; semantics `(single-source)`. `[V54]`

**Pitfalls:** `SetSuspendState` returns FALSE if the system cannot sleep in that mode (for example, hibernate disabled). Check the return value. `(single-source: Learn returns BOOLEAN)`

#### W-P4. Lid and AC events

* `GUID_LIDSWITCH_STATE_CHANGE` = `BA3E0F4D-B817-4094-A2D1-D56379E6A0F3`. Name and GUID `[V46]`; payload not read `(UNVERIFIED)`.
* `GUID_ACDC_POWER_SOURCE` = `5D3E9A59-E9D5-4B00-A6BD-FF34FF516548`. Payload: DWORD `SYSTEM_POWER_CONDITION`, `PoAc = 0` first listed value; full enum not read. `[V56]`
* `GUID_BATTERY_PERCENTAGE_REMAINING` = `A7AD8041-B45A-4CAE-87A3-EECBB468A9E1`. Payload: DWORD percent. `[V46][V56]`
* `GUID_SYSTEM_AWAYMODE` = `98A7F580-01F7-48AA-9C0F-44352C29E5C0`. Payload: DWORD, `0x1` entering away mode. `[V46]`
* Register with `RegisterPowerSettingNotification`. Flags: `DEVICE_NOTIFY_WINDOW_HANDLE = 0` (WM_POWERBROADCAST), `DEVICE_NOTIFY_SERVICE_HANDLE = 1` (HandlerEx). Return value: HPOWERNOTIFY, NULL on failure. `[V51]`

---

## 3. Reference implementations (prove it works)

Read status: "code" means the file was read in this spike; "README" or "not read" means it was not.

| Project | Language | File (raw URL or crate path) | What to copy the idea of | Read |
| --- | --- | --- | --- | --- |
| starship-battery 0.10.0 | Rust | `https://static.crates.io/crates/starship-battery/starship-battery-0.10.0.crate`: `src/platform/linux/sysfs/source.rs`, `src/platform/linux/device.rs` | sysfs fallback chain, post-filters for rate and "ones" value | code |
| starship-battery 0.10.0 | Rust | same crate: `src/platform/darwin/iokit/power_source.rs`, `src/platform/darwin/device.rs`, `src/platform/darwin/iokit/sys.rs` | IOPMPowerSource IORegistry read, raw capacity keys, time mapping | code |
| starship-battery 0.10.0 | Rust | same crate: `src/platform/windows/ffi/mod.rs`, `src/platform/windows/device.rs`, `src/platform/windows/ffi/ioctl/status.rs` | SetupDi enumeration and the TAG, INFORMATION, STATUS IOCTL sequence, unit conversion | code |
| svartalf/rust-battery (`battery`) | Rust | previous attempt: `.../scratchpad/rust_prev/desktop-systems/forks/battery/src/platform/darwin/traits.rs` (doc comments with key names and units) | key names and units; same lineage as starship-battery, so not independent | code (partial) |
| upower_dbus 0.3.2 | Rust (zbus) | `https://static.crates.io/crates/upower_dbus/upower_dbus-0.3.2.crate`: `src/upower.rs`, `src/device.rs` | UPower proxy method and property names and types | code |
| power-profiles-daemon (upstream) | C (GLib) | `https://gitlab.freedesktop.org/upower/power-profiles-daemon/-/raw/main/src/power-profiles-daemon.c`; `.../src/org.freedesktop.UPower.PowerProfiles.xml.in`; `.../src/net.hadess.PowerProfiles.xml.in` | hold and release rules, bus names, property set, polkit action names | code |
| psutil | Python | `https://raw.githubusercontent.com/giampaolo/psutil/master/psutil/_pslinux.py` (`sensors_battery`, line 1435); `.../psutil/_pswindows.py` (`sensors_battery`, line 340); `.../psutil/_psosx.py` (`sensors_battery`, line 174) | sysfs name discovery and fallback fields; Win32 flag bits; macOS fallback | code |
| keepawake 0.6.1 | Rust | `https://static.crates.io/crates/keepawake/keepawake-0.6.1.crate`: `src/sys/macos.rs` | `IOPMAssertionCreateWithName` pattern and type strings | code |
| objc2-io-kit 0.3.2 | Rust (generated) | `https://static.crates.io/crates/objc2-io-kit/objc2-io-kit-0.3.2.crate`: `src/generated/pwr_mgt.rs` | assertion and system-power signatures, message codes, from SDK headers | code (generated) |
| io-kit-sys 0.4.1 | Rust (generated) | `https://static.crates.io/crates/io-kit-sys/io-kit-sys-0.4.1.crate`: `src/ps/keys.rs`, `src/ps/power_sources.rs`, `src/pwr_mgt/pm.rs` | IOPS and IOPM key strings, IOPS extern list | code (generated) |
| objc2-foundation 0.3.2 | Rust (generated) | `https://static.crates.io/crates/objc2-foundation/objc2-foundation-0.3.2.crate`: `src/generated/NSProcessInfo.rs` | `isLowPowerModeEnabled`, `NSProcessInfoPowerStateDidChangeNotification` | code (generated) |
| windows-sys 0.59.0 | Rust (generated) | `https://static.crates.io/crates/windows-sys/windows-sys-0.59.0.crate`: `src/Windows/Win32/System/Power/mod.rs`, `.../SystemServices/mod.rs`, `.../DeviceAndDriverInstallation/mod.rs` | constants, struct layouts, `link!` declarations | code (generated) |
| UPower spec | XML | `https://gitlab.freedesktop.org/upower/upower/-/raw/master/dbus/org.freedesktop.UPower.Device.xml` (and `.../org.freedesktop.UPower.xml`) | the D-Bus contract | spec read |
| systemd logind | man page and doc | `https://www.freedesktop.org/software/systemd/man/latest/org.freedesktop.login1.html`; `https://raw.githubusercontent.com/systemd/systemd/main/docs/INHIBITOR_LOCKS.md` | the logind contract and inhibitor semantics | spec read |
| Linux kernel | Documentation | `.../Documentation/ABI/testing/sysfs-class-power`; `.../Documentation/power/power_supply_class.rst` | sysfs attributes and units | spec read |
| Apple XNU `IOPM.h` | C header | `https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/iokit/IOKit/pwr_mgt/IOPM.h` | checked for assertion and power-source constants; none relevant | fetched, not mined |
| Microsoft Learn | HTML | pages listed in the Route section above | structures, flags, GUIDs, API semantics | pages read |
| Quickshell `Services.UPower`, KDE powerdevil, wayle, Windows `battery` crate, caffeinate, Amphetamine, Lunar, Hammerspoon, TLP, tuned | various | not reached | (not fetched in this spike) | not read |

---

## 4. Double validation

Each row is a claim used in section 2. The status column says whether it is confirmed by two independent sources, which is the required standard.

| ID | Claim | Source A | Source B | Status |
| --- | --- | --- | --- | --- |
| V1 | UPower Device property names, types, enums (State, Type, Technology, WarningLevel, BatteryLevel); DisplayDevice path | UPower `Device.xml` | `upower_dbus` 0.3.2 proxy method names and types | two (units: spec only) |
| V2 | UPower `EnergyRate` is W, positive when discharging; kernel `current_now` is negative when discharging | UPower `Device.xml` (EnergyRate doc); kernel ABI (`current_now`) | none for the sign relation | single-source each side; the sign flip is the key pitfall |
| V3 | `TimeToEmpty`, `TimeToFull` = 0 when unknown; `ChargeCycles` = -1 when unknown | UPower `Device.xml` | none | single-source |
| V4 | UPower `Type` values including Mouse 5, Keyboard 6, Headset 17 | UPower `Device.xml` | none | single-source |
| V5 | Threshold properties and the `G_MAXUINT` skip rule; they write `charge_control_*_threshold` | UPower `Device.xml` | kernel ABI names the same attributes | two |
| V6 | sysfs units: µV, µA, µAh, µWh, seconds, tenths of °C; `temp` in 1/10 °C | kernel `power_supply_class.rst` (quoting `include/linux/power_supply.h`) | kernel ABI (`temp`, `voltage_*`, `current_now`); starship `fs.rs` conversions | two |
| V7 | `charge_control_end_threshold` 0..100, driver rounds, read-back is actual | kernel ABI | UPower `Device.xml` (uses the attribute) | two |
| V8 | `capacity_level` values | kernel ABI | none | single-source |
| V9 | `status` and `type` value strings | kernel ABI | none | single-source |
| V10 | `charge_behaviour` values | kernel ABI | none | single-source |
| V11 | `online` values 0, 1, 2 | kernel ABI | none | single-source |
| V12 | `cycle_count` 0 means unavailable | kernel ABI | starship `cycle_count()` returns None on 0 | two |
| V13 | Fallback chain and rate filters (100 W, 10 µW, 65535 ones) | starship `sysfs/source.rs` (cites UPower; UPower not read) | none | single-source |
| V14 | Attribute names `energy_now`, `charge_now`, `power_now`, `current_now`, `energy_full`, `energy_full_design`, `voltage_now` | kernel `power_supply_class.rst` (class names) | starship and psutil read the same names | two |
| V15 | psutil discovery by `BAT*` and the `time_to_empty_now`, `energy_now`, `charge_now` fields | psutil `_pslinux.py` | starship `source.rs` (same fields) | two |
| V16 | Bus names `org.freedesktop.UPower.PowerProfiles` and `net.hadess.PowerProfiles`, paths; served by PPD, not UPower | PPD `power-profiles-daemon.c` (`#define`s) and its `.xml.in` files | UPower spec XML contains no PowerProfiles interface | two (ownership claim: PPD code and absence in UPower XML) |
| V17 | PPD `HoldProfile` and `ReleaseProfile` semantics, `ProfileReleased` signal, polkit action names | PPD `power-profiles-daemon.c` (`hold_profile`, `release_profile`) | PPD `.xml.in` method and signal definitions | two (one project) |
| V18 | PPD property names and types | PPD `.xml.in` | PPD `power-profiles-daemon.c` property name strings | two (one project) |
| V19 | logind method signatures (`Inhibit(ssss) -> h`, `CanX -> s`, `PowerOff(b)`, `PrepareForSleep(b)`) | logind man page | `INHIBITOR_LOCKS.md` (Inhibit signature) | two |
| V20 | `Can*` return value strings | logind man page | none | single-source |
| V21 | Inhibitor fd lifetime, delay mode, `PrepareForSleep` pattern, lid-switch block-only | `INHIBITOR_LOCKS.md` | logind man page (signals, lock properties) | two |
| V22 | polkit action ids for power and inhibit actions | logind man page (`Security` section) | `INHIBITOR_LOCKS.md` (inhibit-* names) | two |
| V23 | `InhibitDelayMaxUSec` default | `INHIBITOR_LOCKS.md` example value 5000000 | none | single-source (example value) |
| V24 | IOPS key strings (`Current Capacity`, `Time to Empty`, `Is Charging`, `Power Source State`, `Watts`, etc.) | `io-kit-sys` `ps/keys.rs` (generated from `IOPSKeys.h`) | none (Apple page not readable) | single-source |
| V25 | IOPS function names and their extern declarations | `io-kit-sys` `ps/power_sources.rs` | `objc2-io-kit` (no IOPS bindings; not a second source) | single-source |
| V26 | `IOPSGetTimeRemainingEstimate` exists | none | none | UNVERIFIED |
| V27 | IORegistry class `IOPMPowerSource`; keys `Voltage`, `Amperage`, `DesignCapacity`, `CurrentCapacity`, `MaxCapacity`, `CycleCount`, `TimeRemaining`, `ExternalConnected`, `IsCharging` | starship `power_source.rs` and `sys.rs` | `io-kit-sys` `pwr_mgt/pm.rs` key string values (names match) | two (names); units single-source |
| V28 | `Temperature` unit is centi-°C (starship) vs 0.01 K (brief) | starship `power_source.rs` (`/100.0` to °C) | previous fork (same lineage, not independent) | UNVERIFIED (conflict with brief) |
| V29 | `Amperage` sign and width | starship (`i32`, `abs()`) | none | UNVERIFIED for 64-bit and for sign |
| V30 | Identity key names: starship `DeviceName`, `BatterySerialNumber` vs IOPM `Model`, `Serial` | starship `power_source.rs` | `io-kit-sys` `pm.rs` (`kIOPMPSModelKey`, `kIOPMPSSerialKey`) | conflict; UNVERIFIED which is live |
| V31 | Adapter `Watts` key | `io-kit-sys` `ps/keys.rs` (`kIOPSPowerAdapterWattsKey = "Watts"`) | `io-kit-sys` `pwr_mgt/pm.rs` (`kIOPMPSAdapterDetailsWattsKey = "Watts"`) | two |
| V32 | `IOPMAssertionCreateWithName` signature; level On 255 and Off 0; type strings `PreventUserIdleSystemSleep`, `PreventUserIdleDisplaySleep`, `PreventSystemSleep` | `objc2-io-kit` `pwr_mgt.rs` (signature, levels, doc name `kIOPMAssertPreventUserIdleDisplaySleep`); `keepawake` `macos.rs` (strings) | none beyond these | two |
| V33 | System-power message codes `kIOMessageCanSystemSleep` 0x270, `SystemWillSleep` 0x280, `SystemWillPowerOn` 0x320, `SystemHasPoweredOn` 0x300; `IORegisterForSystemPower`, `IODeregisterForSystemPower` | `objc2-io-kit` `pwr_mgt.rs` and `mod.rs` | none | single-source |
| V34 | Acknowledgement rules (`IOAllowPowerChange`, `IOCancelPowerChange`, 30-second window) | `objc2-io-kit` doc comments | none | single-source |
| V35 | `NSProcessInfo.isLowPowerModeEnabled` and `NSProcessInfoPowerStateDidChangeNotification` | `objc2-foundation` `NSProcessInfo.rs` | none | single-source |
| V36 | `IOPMSleepSystem(io_connect_t)` exists | `objc2-io-kit` `pwr_mgt.rs` | xnu `IOPMLibDefs.h` has `kPMSleepSystem` (a different message code, not the function) | single-source |
| V37 | Battery IOCTL codes `0x294040`, `0x294044`, `0x29404C`, `0x298048`; `GUID_DEVCLASS_BATTERY`; SetupDi and IOCTL call order | `windows-sys` `System/Power/mod.rs` and `DeviceAndDriverInstallation/mod.rs` | CTL_CODE decode of the values (method, access, function) and starship `ffi/mod.rs` call order | two |
| V38 | `BATTERY_INFORMATION` and `BATTERY_QUERY_INFORMATION` layouts | Microsoft Learn `battery-information-str` | `windows-sys` struct definitions | two |
| V39 | `BATTERY_STATUS` fields; `Rate` in mW; `Voltage` in mV | Microsoft Learn `battery-status-str` | starship `status.rs`; `windows-sys` struct | two |
| V40 | `BATTERY_WAIT_STATUS` layout and use as input to `IOCTL_BATTERY_QUERY_STATUS` | Microsoft Learn `battery-wait-status-str` (layout) | starship `ffi/mod.rs` (use) | two |
| V41 | Unknown sentinels: capacity, voltage, time 0xFFFFFFFF; rate 0x80000000 | `windows-sys` constants | starship `status.rs` checks | two |
| V42 | `Capabilities` bits: SYSTEM_BATTERY 0x80000000, CAPACITY_RELATIVE 0x40000000, IS_SHORT_TERM 0x20000000 | `windows-sys` constants | starship `info.rs` uses them; Learn `battery-information-str` names the relative bit | two |
| V43 | `PowerState` bits 1, 2, 4, 8 | Microsoft Learn `battery-status-str` | `windows-sys` constants | two |
| V44 | `SYSTEM_POWER_STATUS` fields and values (ACLineStatus, BatteryFlag bits 128 and 8, 255 unknown, SystemStatusFlag) | Microsoft Learn `ns-winbase-system_power_status` | psutil `_pswindows.py` (flags 128 and 8, AC line 1) | two |
| V45 | `BatteryLifeTime` -1 unknown or on AC | Microsoft Learn | none | single-source |
| V46 | Power-setting GUID values (MAX, TYPICAL, MIN, POWER_SAVING_STATUS, ACDC, PERCENTAGE, LIDSWITCH, AWAYMODE) | Microsoft Learn `power-setting-guids` | `windows-sys` constants | two |
| V47 | `GUID_MIN` is High Performance; `GUID_MAX` is Power Saver; `GUID_TYPICAL` is Automatic | Microsoft Learn `power-setting-guids` | none | single-source |
| V48 | `SetSuspendState` signature; `bHibernate` meaning; `bForce` has no effect | Microsoft Learn `setsuspendstate` (semantics) | `windows-sys` `link!` (signature) | two (signature); semantics single-source |
| V49 | `PowerCreateRequest`, `PowerSetRequest`, `PowerClearRequest`; request type values 0..3 | Microsoft Learn `nf-winbase-powercreaterequest`, `powersetrequest`, `powerclearrequest` | `windows-sys` `link!` and `PowerRequest*` constants | two |
| V50 | `SetThreadExecutionState` flag values (`ES_SYSTEM_REQUIRED` 1, `ES_DISPLAY_REQUIRED` 2, `ES_AWAYMODE_REQUIRED` 0x40) | Microsoft Learn `setthreadexecutionstate` | none | single-source |
| V51 | `RegisterPowerSettingNotification` flags (0 window, 1 service handle); return HPOWERNOTIFY | Microsoft Learn `registerpowersettingnotification` | none | single-source |
| V52 | `InitiateSystemShutdownExW` signature | `windows-sys` `link!` (advapi32) | Learn page not in cache | single-source |
| V53 | `ExitWindowsEx` values `EWX_LOGOFF` 0, `EWX_HYBRID_SHUTDOWN` 0x00400000 | Microsoft Learn `exitwindowsex` | none | single-source |
| V54 | `LockWorkStation` returns BOOL and locks the desktop | Microsoft Learn `lockworkstation` (page read, text not mined) | none | single-source |
| V55 | `BatteryTemperature` query unit is deci-Kelvin | starship `windows/device.rs` (`decikelvin!`) | Learn text not read | UNVERIFIED beyond single-source |
| V56 | `GUID_ACDC_POWER_SOURCE` payload DWORD with `PoAc = 0`; `GUID_BATTERY_PERCENTAGE_REMAINING` payload DWORD percent | Microsoft Learn `power-setting-guids` | none | single-source |
| V57 | sysfs `scope` attribute | starship `sysfs/fs.rs` | kernel ABI (not listed) | UNVERIFIED |
| V58 | UPower spec contains no PowerProfiles interface | UPower `org.freedesktop.UPower.xml` and `Device.xml` (grep of `profile`: no hits) | PPD source defines the bus names | two (negative claim) |
| V59 | `ActionsInfo` and `SetActionEnabled` are modern-only | PPD `power-profiles-daemon.c` (legacy interface rejects `SetActionEnabled`) | PPD modern `.xml.in` lists `ActionsInfo`; legacy file not compared | single-source (code) |

---

## 5. Proposed Bleu model

Sketch only: not type-checked, not compiled. Shapes follow `docs/ARCHITECTURE.md` (state is plain data; snapshot publish; `Cap` for each optional operation; `Event` for transients; `Options` with a backend list). Per STYLE.md, optionals are not stored in structs: each optional field carries a `bool has_*` flag.

### 5.1 `bleu::battery` (`libs/bleu_battery.c3l/src/model.c3`)

```c3
module bleu::battery;

// Quantities. Units are fixed by name; convert at the backend boundary.
typedef Percent      = float;   // 0.0 .. 100.0, clamped by the backend
typedef MilliWatt    = int;     // signed: > 0 charging into the battery, < 0 discharging
typedef MilliWattHour = ulong;  // capacity; relative-capacity batteries are skipped in v1
typedef MilliVolt    = uint;
typedef Celsius      = float;   // converted from deci-Kelvin, centi-Celsius or tenths of Celsius at the boundary

enum Kind : char { UNKNOWN, LINE_POWER, BATTERY, UPS, PERIPHERAL }
enum State : char { UNKNOWN, CHARGING, DISCHARGING, NOT_CHARGING, EMPTY, FULL,
                    PENDING_CHARGE, PENDING_DISCHARGE }
enum Chemistry : char { UNKNOWN, LION, LIPO, LIFEPO4, LEAD_ACID, NICD, NIMH }
enum WarningLevel : char { UNKNOWN, NONE, LOW, CRITICAL, ACTION }

// One power source (battery, adapter, UPS or peripheral). Plain data.
struct Source {
    String id;                   // stable: sysfs name | UPower NativePath | IOPS "Power Source ID" | Windows device path
    Kind kind;
    bool present;
    bool rechargeable;
    State state;
    bool has_percent;     Percent percent;
    bool has_energy_rate; MilliWatt energy_rate;
    bool has_time_to_empty; Duration time_to_empty;   // microseconds (std Duration)
    bool has_time_to_full;  Duration time_to_full;
    bool has_capacity;    MilliWattHour full;         // "full charge now"
    bool has_design;      MilliWattHour design;       // design capacity
    bool has_cycles;      uint cycles;
    bool has_voltage;     MilliVolt voltage;
    bool has_temperature; Celsius temperature;
    Chemistry chemistry;
    WarningLevel warning;
    String vendor;               // "" when unknown
    String model;
    String serial;
    bool has_charge_end;  Percent charge_end_limit;    // Linux only in v1
    bool has_charge_start; Percent charge_start_limit;
}

// Whole snapshot: arena-owned slices, published via Observable{State}.
struct State {
    bool ac_online;              // line power present; Windows ACLineStatus, UPower OnBattery inverse
    bool has_adapter_watts;      // macOS only in v1
    uint adapter_watts;
    Source[] sources;            // includes DisplayDevice aggregate as index 0 when available
    bool has_display;
    uint display_index;
}

enum Cap : char {
    SUMMARY, SOURCE_LIST, TIME_ESTIMATE, ENERGY_RATE, HEALTH, CYCLES, TEMPERATURE,
    ADAPTER_WATTS, PERIPHERALS, CHARGE_LIMIT_READ, CHARGE_LIMIT_SET, WARNING_LEVEL,
    HISTORY, EVENTS
}

enum EventKind : char { SOURCE_ADDED, SOURCE_REMOVED, SOURCE_CHANGED, WARNING_CHANGED, AC_CHANGED }

// Transient; carries the source id, not a copy of state.
struct Event {
    EventKind kind;
    String source_id;
}

enum BatteryBackend : char { AUTO, UPOWER, SYSFS, IOKIT_IOPS_IOREG, WIN_IOCTL, WIN_STATUS }

struct Options {
    BatteryBackend backend;      // AUTO runs the platform's priority list below
    bool history;
}
```

Backend priority per OS:

* Linux: `UPOWER` (1), `SYSFS` (2). Fallback: sysfs when the bus name is absent.
* macOS: `IOKIT_IOPS_IOREG` (1). One backend merges IOPS (source kind, time estimates, adapter watts) with the IORegistry `IOPMPowerSource` read (health, temperature, cycles, identity).
* Windows: `WIN_IOCTL` (1) for per-device detail; `WIN_STATUS` (2) when no device is present or when a device query fails. `WIN_STATUS` gives only the summary.

Fields unavailable per platform (sources read):

| Field | Linux | macOS | Windows |
| --- | --- | --- | --- |
| Summary percent, state, AC | yes (UPower or sysfs) | yes (IOPS) | yes (GetSystemPowerStatus) |
| Time to empty or full | yes (UPower, 0 = unknown) | yes (IOPS and IORegistry; units to verify) | yes (status; -1 unknown); IOCTL estimated time |
| Energy rate | yes (sign differs by layer) | yes (Amperage x Voltage; sign to verify) | yes (IOCTL Rate; sign by PowerState) |
| Health (design vs full) | yes (energy_full vs energy_full_design) | yes (raw capacities) | yes (IOCTL BATTERY_INFORMATION) |
| Cycle count | yes | yes (CycleCount) | yes (BATTERY_INFORMATION) |
| Temperature | yes (temp, UPower) | yes (Temperature, unit to verify) | yes (IOCTL level 2, unit single-source) |
| Vendor, model, serial | yes (UPower, sysfs) | yes (IORegistry; key set to verify) | yes (IOCTL levels 4, 6, 8) |
| Adapter wattage | no (not in UPower or sysfs read) | yes (AdapterDetails Watts) | no |
| Charge thresholds | yes (UPower; sysfs) | no (not researched) | no |
| Peripherals | yes (UPower device types) | no (not researched) | no (not researched) |
| History | yes (UPower GetHistory) | no | no |

### 5.2 `bleu::power` (`libs/bleu_power.c3l/src/model.c3`)

```c3
module bleu::power;

enum Profile : char { UNKNOWN, POWER_SAVER, BALANCED, PERFORMANCE }
enum Degraded : char { NONE, LAP_DETECTED, HIGH_TEMPERATURE, OTHER }   // OTHER keeps unknown strings

enum Cap : char {
    PROFILE_READ, PROFILE_SET, PROFILE_HOLD, PROFILE_DEGRADED,
    LOW_POWER_READ, LOW_POWER_SET,
    KEEP_AWAKE_IDLE, KEEP_AWAKE_DISPLAY, KEEP_AWAKE_SYSTEM,
    DELAY_SLEEP_HOOK, BLOCK_SHUTDOWN,
    SUSPEND, HIBERNATE, HYBRID_SLEEP, SUSPEND_THEN_HIBERNATE, POWER_OFF, REBOOT,
    LOGOUT, LOCK, IDLE_HINT, LID_EVENTS, AC_EVENTS, BATTERY_SAVER_READ
}

struct State {
    bool has_profile;  Profile active;
    uint profile_count;          // profiles reported by the backend (Linux: up to 3)
    Degraded degraded;
    bool low_power_mode;         // macOS; false elsewhere
    bool has_low_power_mode;
    bool battery_saver;          // Windows SystemStatusFlag
    bool has_battery_saver;
    bool idle_hint;              // Linux logind
    bool lid_closed;             // Linux logind; Windows GUID_LIDSWITCH_STATE_CHANGE payload (unverified)
    bool on_external_power;
}

enum EventKind : char {
    PROFILE_CHANGED, DEGRADED_CHANGED, LOW_POWER_CHANGED, BATTERY_SAVER_CHANGED,
    PREPARE_SLEEP, RESUMED, PREPARE_SHUTDOWN, LID_CLOSED, LID_OPENED, AC_CHANGED
}

// PREPARE_SLEEP is a delay barrier: the consumer must call ack(ticket).
// Linux: close the logind delay fd. macOS: IOAllowPowerChange (kIOMessageSystemWillSleep).
// Windows: no verified equivalent in v1.
struct Event {
    EventKind kind;
    uint ticket;                 // 0 when not a barrier
}

// An inhibitor is an opaque handle; closing it is the release.
struct Inhibitor {
    uint id;                     // Linux: fd number tracked internally; macOS: IOPMAssertionID; Windows: PowerCreateRequest handle
    bool active;
}

struct Options {
    PowerBackend backend;        // AUTO selects by OS
    bool allow_private;          // false keeps every private symbol off
}

enum PowerBackend : char { AUTO, PPD_MODERN, PPD_LEGACY, LOGIND, MACOS_NSPROCESS_IOPM, WIN_POWRPROF }
```

Backend priority per OS:

* Linux: profiles `PPD_MODERN` (1), `PPD_LEGACY` (2); actions, inhibitors, lid, idle hint, lock `LOGIND` (1).
* macOS: `MACOS_NSPROCESS_IOPM`. Low Power Mode read via NSProcessInfo. Assertions and system power via IOKit. Sleep, shutdown, lock have no verified public route and need a cut decision (section 6).
* Windows: `WIN_POWRPROF` for SetSuspendState, kernel32 for power requests and SetThreadExecutionState, user32 for LockWorkStation, advapi32 for shutdown.

---

## 6. Risks and cut lines

Hard, or not possible without private API or admin rights:

* **macOS sleep, shutdown, restart, lock without privilege.** The public route is `IOPMSleepSystem` with a connection (not verified end to end). The other routes are AppleScript (Automation permission, `(UNVERIFIED)`), `pmset` (`(UNVERIFIED)`), and private SAC or CGSession symbols (private; must go through `bleu::dl`). Recommended cut: leave sleep, shutdown, restart and lock out of macOS v1 until a route is verified on hardware.
* **macOS Low Power Mode setting.** Only the read path is public and verified. Setting it needs root (`pmset`) `(UNVERIFIED)`. Recommended cut: read-only.
* **Windows power mode (overlay scheme).** `PowerSetActiveOverlayScheme` and `PowerGetEffectiveOverlayScheme` are not verifiable from the sources reachable. Recommended cut: report the active GUID only if its read function is verified; otherwise leave out.
* **Windows hibernate and hybrid sleep.** `SetSuspendState` with `bHibernate` fails when hibernation is off. Probing that needs powercfg or the registry (not researched). Recommended cut: offer suspend and hibernate only after a real `SetSuspendState` check; do not offer hybrid sleep.
* **Linux charge thresholds.** Writing `charge_control_*` needs root or a polkit action; the UPower authorisation is `(UNVERIFIED)`. Recommended cut: read-only in v1; the write path goes through UPower `EnableChargeThreshold` only.
* **Peripheral batteries on macOS and Windows.** Not researched (Bluetooth battery APIs). Recommended cut: Linux-only in v1, using UPower device types.
* **Delay inhibitors on Windows.** Windows has no verified equivalent of logind's delay lock in this spike. Keep-awake (PowerCreateRequest, SetThreadExecutionState) is verified; the save-before-sleep barrier is not. Recommended cut: the `DELAY_SLEEP_HOOK` cap is `UNSUPPORTED` on Windows.
* **Temperature and sign conventions across layers.** Three layers use three conventions: UPower `EnergyRate` (W, positive discharging); sysfs `current_now` (A, negative discharging); Windows `Rate` (mW, sign given by `PowerState`); IORegistry `Amperage` (mA, signed, starship discards sign). A conversion table in one file is required, or the sign will be wrong on one platform.
* **Apple `Temperature` unit.** Brief says 0.01 K; starship says centi-Celsius. Do not ship a conversion until read on hardware.
* **Key sets that may differ on current macOS.** `DeviceName` vs `Model`, `BatterySerialNumber` vs `Serial`, `IOPMPowerSource` vs `AppleSmartBattery`. Verify on a real Mac before depending on any one of them.
* **Missing IOPS time function.** `IOPSGetTimeRemainingEstimate` is not verified. Use the IORegistry `TimeRemaining` (minutes) only after checking it on hardware.
* **Linux `Refresh()`.** Debug-mode only (spec). Do not rely on it.

Corrections to the brief, found while reading sources:

* `org.freedesktop.UPower.PowerProfiles` is served by **power-profiles-daemon**, not UPower. The UPower spec does not define it. `[V16][V58]`
* The macOS IORegistry class starship reads is `IOPMPowerSource`, not `AppleSmartBattery`. `[V27]`
* The brief's "0.01 K" temperature conflicts with starship's centi-Celsius; neither is verified against Apple. `[V28]`
* The brief's "signed 64-bit Amperage" is not what starship reads (`i32`, `abs()`). `[V29]`
* `GUID_MIN_POWER_SAVINGS` is High Performance, and `GUID_MAX_POWER_SAVINGS` is Power Saver. The names read backwards. `[V47]`
* The brief's `IOPSGetTimeRemainingEstimate` is not in any source read. `[V26]`

Recommended v1 cut line:

1. Linux: UPower summary, details and events; sysfs fallback; PPD profiles (modern and legacy); logind capability probing, inhibitors (idle, sleep delay), lid and AC events, idle hint, suspend, hibernate, reboot, poweroff, lock and logout. Charge thresholds read-only.
2. Windows: GetSystemPowerStatus summary and the battery-class IOCTL detail; battery saver flag; keep-awake through `PowerCreateRequest`; `SetSuspendState` suspend; shutdown, reboot, lock, logout.
3. macOS: IOPS and IOPMPowerSource read path; keep-awake assertions; Low Power Mode read; sleep and wake notifications with acknowledgement. Sleep, shutdown and lock deferred until a route is verified on hardware.
4. Defer: TLP and tuned fallbacks, WinRT battery, Windows overlay scheme, peripheral batteries on non-Linux, charge-limit writes, history, and all private macOS symbols.
