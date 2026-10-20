# bleu_battery

Battery and power-source state as plain data, on Linux, macOS and Windows. The reference
service of the contract in `docs/ARCHITECTURE.md`. Module root `bleu::battery`; backends
`bleu::battery::sysfs`, `::upower`, `::iokit`, `::win32`. Research and the v1 cut:
`docs/research/battery_power.md` (sections 2, 5.1, 6); implementation notes and the status of
every UNVERIFIED item: `docs/research/battery_impl.md`.

## Public API

    Battery* battery = battery::open(mem, { .backend = AUTO, .poll = time::sec(5) })!;
    defer battery.close();
    if (try snap = battery.latest()) { defer snap.release(); ... snap.value.on_mains ... }
    Snapshot{State}* s = battery.wait_after(seen, time::sec(10))!;   // block for a newer state
    battery.watch(listener, ctx) / battery.unwatch(id)                // on the worker thread
    Reader{Event}* events = battery.subscribe()!;                     // SOURCE_ADDED, MAINS_CHANGED ...
    battery.refresh()!;                                               // read the hardware now
    battery.backend_name();                                           // "upower", "sysfs", "iokit", "win32"
    battery.capability(Cap.HEALTH);                                   // Availability: available, or why not

`State` holds `on_mains`, `adapter_watts` (macOS), `sources`, and `reading`: AVAILABLE for a full
reading, DEGRADED when some devices could not be read and are left out, BACKEND_STOPPED when the newest
read failed and `sources` is the last good reading. A failed read never publishes an empty state; before
the first good reading nothing is published and `latest()` is UNAVAILABLE. Every backend publishes through
`publish.c3`, which emits SOURCE_ADDED, SOURCE_REMOVED, MAINS_CHANGED and STATE_CHANGED from one shared pure
diff (`changes`, `common_state.c3`). Each `Source` has a stable `id`,
a `Kind`, a `ChargeState`, and `Maybe{...}` measurements: charge, power (positive into the
battery), time to empty and full, energy and design capacity, health, cycles, temperature.
Options: `backend` forces one (UNSUPPORTED if it cannot run here); `root` is a fake sysfs tree
for tests and disables UPower.

## Coverage

Status per capability and backend. "Run" = executed on Linux against a fake or mock; "Compiled-only"
= type-checked for the target only, never executed; "Not done" = not implemented in v1.

| Capability | Linux UPower | Linux sysfs | macOS IOKit | Windows win32 |
| --- | --- | --- | --- | --- |
| CHARGE (percent, state, sources) | Run (mock, `tests/run.sh`) | Run (fake tree, `battery_test.c3`) | Compiled-only | Compiled-only |
| TIME_ESTIMATE | Run (mock: TimeToEmpty) | Run (fake tree) | Compiled-only (IOPS estimate) | Compiled-only (computed) |
| POWER (flow, sign) | Run (mock: EnergyRate sign) | Run (fake tree) | Compiled-only (magnitude; direction from state) | Compiled-only (Rate) |
| HEALTH | Run (mock: EnergyFull / Design) | Run (fake tree) | Compiled-only | Compiled-only |
| CYCLES | Run (mock) | Run (fake tree) | Compiled-only | Compiled-only |
| TEMPERATURE | Run (mock; unit per spec) | Run (fake tree) | Not done (unit unresolved) | Not done (unit single-source) |
| IDENTITY (vendor, model, serial) | Run (mock) | Run (fake tree) | Compiled-only (key names conflict; see impl) | Not done (IOCTL string levels) |
| PERIPHERALS | Run (mock: DeviceAdded / DeviceRemoved, Type 5) | Not done (sysfs lists supplies, not peripherals) | Not done | Not done |
| Change notification | Run (PropertiesChanged, DeviceAdded/Removed) | Poll only (`REFRESH` forces a read) | Compiled-only (IOPS run loop + poll) | Compiled-only (window messages + poll) |
| Transient events (`subscribe()`) | Run (DeviceAdded refresh; diff unit-tested) | Run (`plugging_in_is_published_as_an_event`) | Compiled-only (same diff) | Compiled-only (same diff) |
| Stale reading after a failed read | Compiled-only (same path as sysfs) | Run (`a_failed_read_keeps_the_last_good_reading`) | Compiled-only | Compiled-only |
| Adapter watts | Not done | Not done | Compiled-only | Not done |
| Unit conversions and rules | Run (`upower_test`, `common_test`) | Run (`sysfs_test`) | Run (`iokit_test`: pure functions only) | Run (`win32_test`: pure functions only) |

Run on Linux: `c3c compile-test` over the six `*_test.c3` files, and `tests/run.sh` (live UPower).
Last run: the unit set passed (147 tests, including the linked rt, service, win and core tests), and
both live scripts passed (the UPower reads and changes, the refusal without the name). The UPower mock
reports a wireless mouse as Type 2 with PowerSupply FALSE, and the live suite checks it is a peripheral.

## Not done

* macOS and Windows backends have never been executed. Their pure conversions run; the native
  paths are type-checked for six targets only.
* macOS: `Amperage` direction is unverified (magnitude only); `Temperature` unit unresolved (empty);
  identity key names conflict (`DeviceName`/`Model` both read); only the first internal battery
  takes the IORegistry record; the IOPS minutes keys are not used.
* Windows: `BatteryTemperature` unit unresolved (empty); device name, manufacturer and serial
  IOCTL levels not read; `BatteryEstimatedTime` not read (time computed); relative-capacity batteries
  skipped; WinRT battery API not used. The `DEGRADED` capability note is a local helper (`battery::degraded`);
  the matching constructor belongs in `bleu_core` `availability`, which this library does not own.
* UPower: charge thresholds (read-only in the research, not in the model); history; the
  DisplayDevice aggregate; a bus restart is handled by reconnecting on the next poll tick and is
  not exercised by the tests.
* sysfs: uevent watching (poll only, as before); peripherals.
* No charge-limit writes, no `EnableChargeThreshold`, no peripherals on macOS and Windows.

## Verification and how to run it

* `tools/check.sh bleu_core bleu_rt bleu_service bleu_objc bleu_win bleu_dbus bleu_battery`
  (all six targets) is the type check. It passed for battery and its dependencies when run in
  isolation; re-run it on the full tree before relying on it.
* Unit tests (Linux):
  `c3c --libdir "$(tools/libdir.sh)" --lib bleu_core --lib bleu_rt --lib bleu_service --lib bleu_objc --lib bleu_win --lib bleu_dbus --lib bleu_battery compile-test libs/bleu_battery.c3l/src/{battery,sysfs,iokit,common,win32,upower}_test.c3 --sources libs/bleu_battery.c3l/src/*.c3`
* Live UPower (needs `dbus-daemon`, `python3`, and either `BLEU_BATTERY_PYTHON` with dbus-next
  or pypi access): `libs/bleu_battery.c3l/tests/run.sh`.
