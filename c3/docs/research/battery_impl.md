# `bleu_battery`: implementation notes

Companion to `docs/research/battery_power.md` (sections 2, 5.1 and 6). This file records
what was built, what was verified and how, every deviation from the research, and the
disposition of each UNVERIFIED item the research marked. The lib README has the coverage matrix.

## 1. Deviations from the research

* **`State.adapter_watts`** was added to `model.c3` as the last field, with `Maybe{uint}`.
  Backwards compatible: positional initialisers written before still mean the same thing,
  and no code in the tree used a positional `State`. macOS fills it from the adapter
  details; Linux and Windows leave it empty.
* **Time estimate on macOS.** The research's IOPS per-source "Time to Empty" key has an
  unverified unit, so the backend does not use it. It uses `IOPSGetTimeRemainingEstimate`
  (seconds, see section 2.2), applied to the internal battery in the direction of its state.
* **Charge state on mains.** `charge_state` (`common_state.c3`) is this library's rule and is
  shared by macOS and Windows: on mains, CHARGING / FULL / NOT_CHARGING; on battery,
  DISCHARGING or EMPTY at zero charge. The research gave the on-battery rule only (starship).
* **Windows summary as a source.** When no battery device answers, `GetSystemPowerStatus`
  is published as one source with the id `system`. Not in the research; needed so that a
  machine whose IOCTLs fail still shows its battery.
* **UPower DisplayDevice.** Not enumerated and not read. The state lists each physical device,
  so the aggregate would duplicate the batteries.
* **Windows device access** opens the battery with `GENERIC_READ` only. The research left
  write access UNVERIFIED; the three IOCTLs the backend uses are query codes, and the CTL_CODE
  access bits show read access (section 2.3), so write access is not requested.
* **Windows relative-capacity batteries are skipped** (`NOT_FOUND`), as the research's W-B2
  pitfall allows; they are not converted.
* **Windows identity and temperature** are not read in v1 (section 2.3 explains why).
* **Cycle count on macOS.** `CycleCount` 0 is published as a value. Starship treats 0 as
  unknown for sysfs, but a new battery legitimately has 0 cycles and macOS does not document
  0 as a sentinel.

## 2. Verified facts and the UNVERIFIED items

### 2.1 Linux (UPower)

The backend is run against a private `dbus-daemon` and a `dbus-next` 0.2.3 mock of
`org.freedesktop.UPower` (`tests/`). The mock's values are the spec's names and types; the
units (Wh, W, seconds, degrees Celsius) are from `org.freedesktop.UPower.Device.xml` only.
The research's V1 is "two sources for names and types, spec only for units", and that stands.

* `EnergyRate` sign: positive discharging (spec). Converted to Bleu's "positive into the
  battery" at the boundary (`power_from_rate`). Tested in `upower_test.c3` and `upower_live.c3`.
* `TimeToEmpty`, `TimeToFull` 0 = unknown; `ChargeCycles` -1 = unknown (spec, V3).
* `Temperature` in degrees Celsius: spec only (single source for the unit).

### 2.2 macOS (IOKit): resolved by reading Apple sources

Sources fetched from `raw.githubusercontent.com` (reachable) and read in full:

| Claim | Source A | Source B | Disposition |
| --- | --- | --- | --- |
| `IOPSGetTimeRemainingEstimate` exists (V26) | Apple IOKitUser `ps.subproj/IOPowerSources.c` line 94 | none | Resolved, single source (Apple, open source). Returns seconds; negative means no estimate. The sentinel values are in `IOPowerSources.h`, which was not fetched, so every negative value is treated as no estimate. |
| `Amperage` width (V29) | XNU `iokit/IOKit/pwr_mgt/IOPMPowerSource.h`: "Type: int", mA | starship-battery 0.10.0 `power_source.rs`: `i32` | Resolved: 32-bit signed, mA. |
| `Amperage` storage | XNU `iokit/Kernel/IOPMPowerSource.cpp`: `setAmperage` stores `OSNumber::withNumber(val, 32)`; `amperage()` returns `(int)unsigned32BitValue()` | starship `to_i32()` | Resolved: the low 32 bits are the signed value. `amperage_from_registry` truncates to `int`; a 64-bit read would show a large positive number for a negative current. Tested. |
| `Amperage` direction (V29) | none: the header and the kernel code do not say which sign is charging | starship takes `abs()` | **Open.** Not implemented: the flow's direction comes from the charge state, and only the magnitude of `Amperage` is used. |
| `Temperature` unit (V28) | starship: centi-Celsius (`value / 100`) | XNU header names the key `kIOPMPSBatteryTemperatureKey` with no unit; the brief says 0.01 K | **Open, field left empty.** Capability `TEMPERATURE` is `UNSUPPORTED_BACKEND`. |
| `FullyCharged`, `ExternalConnected`, `IsCharging`, `Voltage`, `DesignCapacity`, `CycleCount`, `Manufacturer` | XNU `IOPM.h` key names | starship `power_source.rs` | Two sources agree on the names. |
| `Model` / `Serial` vs `DeviceName` / `BatterySerialNumber` (V30) | XNU `IOPM.h` (`kIOPMPSModelKey`, `kIOPMPSSerialKey`) | starship (`DeviceName`, `BatterySerialNumber`) | **Conflict, live key UNVERIFIED on hardware.** The reader prefers starship's names and falls back to XNU's. |
| Registry class `IOPMPowerSource` (V27) | XNU `IOPM.h` / `IOPMPowerSource.h` | starship (`IOPM_SERVICE_NAME`) | Two sources agree. |
| Capacities in mAh; voltage in mV; time remaining in minutes | XNU `IOPMPowerSource.h` comments | starship (`milliampere_hour!`, `millivolt!`) | Two sources agree. |
| `MaxCapacity` on Apple silicon is a percentage; `AppleRawMaxCapacity` is mAh (single-source) | starship comment | none | The reader prefers the `AppleRaw*` keys, falls back to the plain ones. |
| Adapter `Watts` (V31) | XNU `IOPM.h` `kIOPMPSAdapterDetailsWattsKey` = "Watts" | `io-kit-sys` (research) | Two sources agree. |
| `FullyCharged` key | XNU `IOPM.h` `kIOPMFullyChargedKey` | starship | Two sources agree. |

The conversion `mAh x mV / 1000 = mWh` and `mA x mV / 1000 = mW` follow from the units above.

**Not run on a Mac.** No macOS machine was available. Everything under `macos_iokit.c3`,
`iokit_read.c3` and the run-loop notification path is type-checked for both macOS targets only.

### 2.3 Windows: resolved from Learn and `windows-sys`

* **Rate sign (V39, the research's sign question):** Microsoft Learn `battery-status-str`:
  "A nonzero, positive rate indicates charging; a negative rate indicates discharging." So
  `BATTERY_STATUS.Rate` is already Bleu's convention: no conversion. Learn-only (one primary
  source for the sign).
* **Units:** capacities mWh, rate mW, voltage mV (Learn `battery-status-str`,
  `battery-information-str`); `windows-sys` 0.59.0 has the same field types.
* **`BATTERY_CAPACITY_RELATIVE` = 0x40000000** (V42): Learn `battery-information-str` names the
  bit and says the rates are then per hour; `windows-sys` `BATTERY_CAPACITY_RELATIVE` = 1073741824.
  Two sources agree.
* **Sentinels:** `BATTERY_UNKNOWN_CAPACITY` and `_TIME` = 0xFFFFFFFF, `_RATE` = 0x80000000
  (`windows-sys`; Learn for the capacity and rate sentinels). `SYSTEM_POWER_STATUS` 255 = unknown
  for the bytes, 0xFFFFFFFF for the lifetime (Learn `ns-winbase-system_power_status`, and
  psutil `_pswindows.py` for the 128 and 8 flags).
* **IOCTL codes** `0x294040` (TAG), `0x294044` (INFORMATION), `0x29404C` (STATUS): `windows-sys`
  constants; decoded with the CTL_CODE layout they are device 0x29, METHOD_BUFFERED, FILE_READ_ACCESS.
  Two sources agree (starship and `windows-sys`).
* **SetupAPI structures** are `repr(C, packed(1))` in `windows-sys`, which matches `#pragma pack(1)`
  in SetupAPI.h. The detail buffer's fixed part is `cbSize` plus one WCHAR, so `cbSize` is 6 and
  the path starts at byte 4. `SP_DEVICE_INTERFACE_DATA` is 32 bytes, so its natural layout
  matches the packed one.
* **`BatteryTemperature` unit (V55):** deci-Kelvin in starship only. The DDI reference pages for
  the battery IOCTLs are not reachable from this environment (the proxy returns 404 for them), so
  it stays **Open**. Capability `TEMPERATURE` is `UNSUPPORTED_BACKEND`, and the field is empty.
* **`BatteryEstimatedTime` (level 3)**: not read. The time estimate is computed from capacity and
  rate, and the summary uses `BatteryLifeTime` (Learn).
* **Write access (research `UNVERIFIED`)**: not needed, see section 1.

**Not run on Windows.** Nothing in `windows_*.c3` has run. The tests cover only the pure
conversions (`win32_test.c3`), which run on Linux.

## 3. Pitfalls found while writing

* `poller` in window-message mode returns a readiness for the message queue and does not
  dispatch the messages itself: the caller must call `message_loop::dispatch_pending()` after
  each wait (`windows_battery.c3`).
* `Source` is ambiguous in a module that also imports `bleu::rt::poller` (which has its own
  `Source`); qualify it as `battery::Source`.
* `c3c compile-test` runs the `@test` functions of every linked library, not only the named
  test file, so the live output lists other libraries' tests too.
* `c3c` writes `out/` and `build/` into the working directory; `tests/run.sh` runs it from the
  work directory so the lib tree stays clean.
