# Review of bleu_battery and bleu_power

Scope: `libs/bleu_battery.c3l` and `libs/bleu_power.c3l` (sources, tests, READMEs) as they are in the
working tree at review time. No file under `libs/` or `docs/` was edited; scratch programs and mutated
copies live in the session scratchpad and are named below. Method and output format: `docs/REVIEW_CHECKLIST.md`.

## Verdict

- **bleu_battery**: the UPower, sysfs and Windows unit conversions match their cited sources, and the live
  UPower suite asserts real values. Not ready: the public `subscribe()` stream never yields an event, a failed
  read publishes a definite "not on mains, no batteries" state, UPower ignores `PowerSupply`, and two sysfs
  assertions are mutation-blind (proved below).
- **bleu_power**: the logind path is carefully built, and its inhibitor-descriptor and sleep-barrier tests check
  real behaviour. Blocking defects: a release after `close()` is a use-after-free (proved under valgrind);
  once the bus is marked lost, releases are dropped silently and nothing reconnects; the macOS backend wedges
  sleep and wake events after the first `CAN_SLEEP` (reproduced); the integration suite can exit 0 with a
  broken hibernate path (proved by mutation).
- The macOS and Windows backends were read against the headers, not executed. Windows IOCTL codes, struct
  layouts, PowerState bits, `Rate` sign, sentinels, GUID, power-request and shutdown bindings match windows-sys
  0.59.0 and Microsoft Learn. IOKit keys and units match XNU and IOKitUser.

Counts: 29 findings. HIGH 5, MEDIUM 11, LOW 13 (battery 16: 1/6/9; power 13: 4/5/4).

## Findings: bleu_battery

| ID | Severity | Where | Defect | Evidence | Suggested fix |
| --- | --- | --- | --- | --- | --- |
| B-01 | HIGH | `model.c3:96-99`; `service.c3:108`; README "Public API" | `Battery.subscribe()` is documented to deliver SOURCE_ADDED, SOURCE_REMOVED, MAINS_CHANGED and STATE_CHANGED. No backend calls `hub.emit`; the only event-related code is the Windows message filter. A consumer waiting on the stream waits forever. Breaks ARCHITECTURE contract item 3. | `grep -rn emit libs/bleu_battery.c3l/src` finds no call. | Emit on the diff in each backend's publish path, or remove the enum members, the method and the README line. |
| B-02 | MEDIUM | `linux_sysfs.c3:66`; `linux_upower.c3:171`; `macos_iokit.c3:137`; `windows_battery.c3:177` | On a failed read, `refresh` publishes `snapshot.value = { }`: `on_mains = false` and no sources. That states "not on mains, no battery", which is a claim, not "unknown". A read failure cannot be told apart from a desktop with no battery. Contradicts ARCHITECTURE "no silent fallbacks" and the model's "unknown is not zero". | Code path; the only signal is an empty source list. | Keep the last good state and mark it stale, or add an availability/reason field to `State`. |
| B-03 | MEDIUM | `upower_read.c3:90` (kind from `Type` only); `upower_convert.c3` `device_kind` | The UPower spec says a `Battery` device is a laptop battery only when `PowerSupply` is true: "set TRUE for laptop batteries and UPS devices, but set FALSE for wireless mice or PDAs". The library never reads `PowerSupply` (no use under `libs/bleu_battery.c3l`), so a Type-2 peripheral becomes a BATTERY source. The mock cannot show it: every fixture battery is Type 2 with no `PowerSupply`. | Spec: `org.freedesktop.UPower.Device.xml`, property `PowerSupply`. grep. | Read `PowerSupply`; a Battery with false is PERIPHERAL. |
| B-04 | MEDIUM | `windows_ioctl.c3:218` | `.cycles = maybe::value(info.cycle_count)` always. Microsoft Learn (`battery-information-str`, CycleCount): "If the battery does not support a cycle counter, this member is zero." Zero is reported as a count. | Learn page fetched. | `cycle_count == 0 ? {} : value`; add a `win32_test`. |
| B-05 | MEDIUM | `battery_test.c3:53` (`time_to_full.has_value` only); `battery_test.c3:58-74` (no discharging fixture); `sysfs_test.c3` | Two mutants survive the whole suite. M1: the discharge sign is dropped in `sysfs_read.c3:117`, 76/76 pass. M3: `time_to_full` is replaced by a constant, 76/76 pass. The README's "POWER (flow, sign) Run (fake tree)" holds only for charging. Positive control M4 (UPower sign flipped) is caught (1 failure). | Mutation runs on scratch copies (see Tests). | Assert `power < 0` on a discharging fixture, and `time_to_full == 2 400 000 000` µs on the charging one (11 100 mWh at 16 650 mW). |
| B-06 | MEDIUM | `linux_sysfs.c3:79`; `linux_upower.c3:180`; `macos_iokit.c3:150` (`run`); `windows_battery.c3:233` (`run`) | `if (catch poller.init(...)) return;` leaves the worker without publishing or reporting. `open()` has already succeeded (it does not wait for a first reading, `service.c3:46-60`), so `latest()` is UNAVAILABLE forever and `wait_after` times out with no fault. | Code path. | Create the poller before signalling readiness, as bleu_power's `Startup` latch does, so `open` returns the fault. |
| B-07 | MEDIUM | `macos_iokit.c3:174-179` | If `loop.stop_and_join()` fails, `run` closes `notifier.source` and returns. `destroy` then frees the `Backend` that holds `Notifier`, while the loop thread may still run `on_power_source_changed`, which dereferences `notifier.mailbox`. The comment "it exits with the process" does not hold: the process keeps running. | Code path; not run on macOS. | On join failure, leak the backend, or have the callback check an atomic "closed" flag. |
| B-08 | LOW | `linux_sysfs.c3:16`; `sysfs_read.c3:166`; `upower_convert.c3:128` | Dead field `previous_sources`. `sort_by_id` is written twice. | grep. | Delete the field; move the sort to `common_state.c3`. |
| B-09 | LOW | `sysfs_read.c3:108-117` | The ABI says `current_now` is signed ("Negative values are used for discharging batteries, positive values for charging batteries"). The code takes the magnitude and takes the direction from `status`, so a battery reporting status "Unknown" with a negative current gets positive (charging) power. | ABI text fetched (`sysfs-class-power`, `current_now`). | Use the sign of `current_now`; use `status` only for unsigned `power_now`. |
| B-10 | LOW | `sysfs_convert.c3:18-31` | `USB_PD_DRP` is missing from `kind_from_type`; the kernel's `POWER_SUPPLY_TYPE_TEXT` has it. It maps to UNKNOWN, so the supply does not count toward `on_mains`. | `drivers/power/supply/power_supply_sysfs.c` fetched. | Add the case. |
| B-11 | LOW | `win32_convert.c3:40`; `sysfs_convert.c3:84-86`; `docs/C3_GOTCHAS.md:168` | Three doc errors. `summary_seconds` says "microseconds" but takes seconds (the arithmetic is right). `hours_at` says "too small to extrapolate" but returns 0 only for a non-positive flow. The gotcha "`switch` on a `String` is not supported" is contradicted by `sysfs_convert.c3:18,37`, which compiles on all six targets and whose tests pass. | Read; compiled; tests pass. | Fix the comments; correct the gotcha. |
| B-12 | LOW | `service.c3:53` | `self.driver_state = driver.create(...)!;` returns without freeing `self`. bleu_power's `open` frees on the equivalent path. Unreachable today (no backend's `create` can fail). | Code path. | Free `self` on the error path. |
| B-13 | LOW | `sysfs_read.c3:151-153`; `upower_read.c3:141`; `windows_battery.c3:198, 212` | A device whose read fails is dropped silently (`continue`, `if (try ...)`), and a SetupAPI failure falls back to the summary with no signal. A present battery can vanish with no trace. | Code path. | Count skipped devices and report them. |
| B-14 | LOW | `linux_upower.c3:117` | `int fd = backend.connection.fd()!;` returns from `connect` with the connection still open. Reachable only if `fd()` fails (it fails only when not open), so unreachable today. | `connection.c3:292`. | Use `catch` and close. |
| B-15 | LOW | `battery_test.c3:7` | The fake tree is `/tmp/bleu-battery-<stem>-<clock>`: a predictable name, never removed. | Code path. | `mktemp -d`, removed at the end. |
| B-16 | LOW | `linux_upower.c3` and `windows_battery.c3` `create` | `availability::no(Reason.DEGRADED, ...)` is used for capabilities that are available with caveats. `no()` reads as "unavailable", but `ok()` is true for DEGRADED. | `availability.c3`. | Add a `degraded(note)` constructor. |

## Findings: bleu_power

| ID | Severity | Where | Defect | Evidence | Suggested fix |
| --- | --- | --- | --- | --- | --- |
| P-01 | HIGH | `macos_power.c3:203-219` (`deliver_sleep`); `:216` (`case PowerEvent.OTHER: return;`) | `return` leaves the function on the first CAN_SLEEP, WILL_NOT_SLEEP or OTHER in the list, before the clear at `:219`. WILL_SLEEP and HAS_POWERED_ON behind it are never published, and the list grows. Every idle sleep delivers CAN_SLEEP first (`bleu_objc` `power.c3:379`), so PREPARE_SLEEP and RESUMED are dead for the life of the process. | Scratch program reproducing the same control flow: after CAN then WILL, PREPARE published 0, queued 2; after wake, RESUMED published 0, queued 3; control with WILL alone, published 1. Not run on macOS. | Use `continue`, and clear the list on every path. |
| P-02 | HIGH | `service.c3:280-290` (`ProfileHold.release`, `Inhibitor.release` read `self.owner.hub`); `service.c3:86-92` (`Power.close` frees the struct) | Use-after-free. A hold or inhibitor released after `close()` dereferences the freed `Power`. `model.c3` documents that closing releases every inhibitor, and nothing stops a later `release()`. | Valgrind on a scratch probe (open, inhibit, close, then release): "Invalid read of size 1 ... 440 bytes inside a block of size 1,304 free'd ... Power.close (service.c3:92)", read at `Inhibitor.release (service.c3:287)`. A plain run aborts with the mutex contract failure (exit 132). | Let holds and inhibitors reference a refcounted hub, not the service; a release after close becomes a checked no-op returning DISCONNECTED. |
| P-03 | HIGH | `linux_logind.c3:139` (note_failure), `:343`, `:376` (set `bus_alive = false`); `:170` (only place it becomes true); `linux_calls.c3:13-17` (`dispatch`), `:53-54`; `service.c3:313-325` (`abort_command`) | Once `bus_alive` is false, which happens on a DISCONNECTED failure, a non-timeout poller error, or a failed `process()`, nothing sets it back. `dispatch` then aborts every command with DISCONNECTED, and `abort_command` skips the release kinds. So `Inhibitor.release()` and `ProfileHold.release()` return success while the lock fd stays in `b.locks` and the hold stays at the daemon until `Power.close()`. Every later request fails. | Code path. No test covers it. `bleu_rt` already retries EINTR (`poller_posix.c3:64`), so the trigger is a real poller error or a real disconnect. | Keep release requests pending and replay them on reconnect; reconnect as UPower does; never latch "lost" for the rest of the process. |
| P-04 | MEDIUM | `linux_logind.c3:334` (`poller.init(...)!!` in `serve`); `:359-360` (`b.bus.fd()!!`, `poller.add(source)!!`); `windows_power.c3:139` (`poller.init(...)!!`) | `!!` on fallible I/O aborts the process (for example EMFILE). ARCHITECTURE: I/O failure never aborts. | Code path. | Create the poller in `start()`, before `startup.succeed()`, so `open` fails with the fault; treat an `add` failure as a lost bus. |
| P-05 | MEDIUM | `linux_logind.c3:438-444` (`end_sleep`); `fill_capabilities` `:316-317` | If the retake of the delay lock after resume fails, the error is dropped (`note_failure` only reacts to DISCONNECTED). From then on PREPARE_SLEEP carries ticket 0 and nothing waits, while `Cap.DELAY_SLEEP_HOOK` still reports YES. The integration test covers only the successful retake. | Code path (the comment at 438-440 says so). | Publish the loss in `State`, and keep the Cap honest. |
| P-06 | MEDIUM | `bleu_dbus/src/errors.c3:39-40` (`.NotAuthorized` maps to AUTH_REQUIRED, everything else not in the table to BACKEND_FAILURE); `service.c3:254-255` (doc: refused = PERMISSION_DENIED, needs authentication = AUTH_REQUIRED); `integration/main.c3:280`; `integration/mock_daemons.py:120` | (a) `PolicyKit1.Error.NotAuthorized` is a refusal, which the doc calls PERMISSION_DENIED, but it maps to AUTH_REQUIRED. (b) `PolicyKit1.Error.Cancelled` (the user dismissed the dialog; the name is in polkit's own table, `polkiterror.c`) falls to BACKEND_FAILURE. (c) logind's own refusal names are not in the table and fall to BACKEND_FAILURE (unverified, see S-9). The test asserts (a) against the mock's canned reply, so it cannot catch a wrong mapping. | polkit table fetched; mock and test lines. | InteractiveAuthorizationRequired to AUTH_REQUIRED; PolicyKit1 NotAuthorized to PERMISSION_DENIED; Cancelled to AUTH_REQUIRED; verify and add the logind names. |
| P-07 | MEDIUM | `linux_logind.c3:316-320` (`fill_capabilities`) | Suspend, Hibernate, HybridSleep, PowerOff and Reboot are YES at open, without reading `Can*`. `can()` can answer `na` or `no` (the integration test asserts `na` for hybrid sleep), but `Cap` still says YES, and `perform()` checks only the Cap. The request reaches logind and fails later with a mapped excuse. Contract: capabilities are explicit and honest. | Code path; `main.c3:260-266` checks `can()` only. | Read the `Can*` answers at open and derive the Caps from them. |
| P-08 | HIGH | `integration/main.c3:172-173, 186-188, 215-217, 247-263, 275-285, 336` | Silent-pass branches. `if (catch err = call) check(...)` and `if (try op = call) { ... }` with no else record nothing when the call fails. Line 336 (`if (try reader = svc.subscribe())`, no else) skips the whole barrier block. Lines 275-285 are the HIBERNATE polkit check: if `perform` refuses synchronously, the AUTH check never runs. | Mutation P2 (scratch copy: `Power.perform` refuses HIBERNATE synchronously): suite exit 0, 38 PASS (control: 39), 0 FAIL, and the "maps to AUTH_REQUIRED" line absent. Mutation P1 (release never closes the descriptor) is caught ("releasing the inhibitor closes its descriptor"). | Add `else { check(false, ...) }` to each branch. |
| P-09 | MEDIUM | `tests/run.sh:68`; `integration/main.c3` (no guard) | `DBUS_SYSTEM_BUS_ADDRESS` is set from `head -n1` of the address file without a check for an empty value. Empty means the C3 client and the mock use the default system bus. The mock's READY gate should stop the run when a real logind already owns `org.freedesktop.login1` (the mock cannot take the name), but that is an indirect defence I did not exercise, and the C3 binary has no guard of its own. The suite calls `perform(SUSPEND)`, `perform(HIBERNATE)`, `perform(LOCK)` and `Session.Lock`; POWER_OFF, REBOOT and Terminate are not called but are one call away. An over-long socket path produced exactly this empty address in a mutation run. | run.sh:68; observed while running the mutants. | run.sh fails if the address is empty; main.c3 refuses to run unless `DBUS_SYSTEM_BUS_ADDRESS` names a socket under the work directory. |
| P-10 | LOW | `linux_calls.c3:93` | `set_profile` returns the requested profile, not the one the daemon accepted, but `service.c3` and `model.c3` say the value is the accepted profile. | Code path. | Read `ActiveProfile` back, or fix the doc. |
| P-11 | LOW | `model.c3:45`; `linux_state.c3:41` | `Degraded degraded` is a plain enum whose zero member NONE means "not degraded". An unreadable state reports NONE, which breaks the model's own rule that unknown fields are empty. | Code path. | Add UNKNOWN as the zero member. |
| P-12 | LOW | `windows_power.c3:166-167` (`refresh`) | On a GetSystemPowerStatus failure, `refresh` returns without publishing, so the last values stay. The comment says the fields become unknown. | Code path. | Publish unknowns, or fix the comment. |
| P-13 | LOW | `windows_api.c3` and `bleu_battery` `windows_summary.c3` | The same Win32 struct (`SYSTEM_POWER_STATUS`) is declared in two libraries. | grep. | Move it to `bleu_win`. |

## Suspicions (unproven)

- **S-1** (battery, macOS) `Amperage` direction. The headers give the unit (mA) and type (`int`), not the sign
  (`IOPMPowerSource.h:107-109`). The code ignores the sign and takes direction from the charge state
  (`iokit_read.c3:194-195`). `iokit_test` checks the sign conversion, but nothing consumes it. Needs a source
  that states the sign, or hardware.
- **S-2** (battery, macOS) `Temperature`: the key exists (`IOPM.h:617`) and no unit is given. The README's
  "unresolved" is correct.
- **S-3** (battery, macOS) identity key order. `iokit_read.c3:198` prefers `DeviceName`, which no XNU header
  defines. `Model` (`kIOPMPSModelKey`, `IOPM.h:609`) is the documented key. Prefer `Model`.
- **S-4** (power, macOS) `NSProcessInfo.isLowPowerModeEnabled` is sent with no version check (`macos_power.c3:278`).
  The selector is newer than some supported macOS versions; I did not verify the version.
- **S-5** (battery, Linux) `power_now` in µW, and its sign convention, are not in the cited ABI file. The
  kernel header lists energy, charge, time and temperature units, not power. The µW assumption has one source.
- **S-6** (battery, UPower) `Pending discharge` maps to NOT_CHARGING (`upower_convert.c3`). The spec gives the
  names only.
- **S-7** (battery, UPower) `IsPresent` defaults to true when absent (`upower_read.c3:95`).
- **S-8** (battery, macOS) `on_mains` is true whenever `AdapterDetails` exists (`iokit_read.c3:101-106`). That
  may differ from AC being connected.
- **S-9** (power, logind) the logind refusal error names (`org.freedesktop.login1.Error.*`). The systemd error
  tables could not be retrieved, so I could not confirm the names.
- **S-10** (power, logind) the `PerformanceDegraded` strings are not checked against power-profiles-daemon.
- **S-11** (power, logind) the polkit action behind `Session.Terminate` is unverified (the README says so).
- **S-12** (power, Windows) `SystemStatusFlag` bit 1 as battery saver (`windows_api.c3`): the Learn page was cut
  before that member.

## What is good

- Battery units match their sources. UPower Wh to mWh, EnergyRate sign inverted (spec: positive when
  discharging), TimeToEmpty s to µs, ChargeCycles -1 as unknown, and the Type, State and Technology enums all
  match the spec. sysfs µWh, µAh x µV, µA x µV and tenths of °C match the kernel header and the ABI. IOKit
  mAh x mV and mA x mV are divided by 1000 correctly, and the 32-bit `Amperage` truncation matches
  `IOPMPowerSource.cpp:325-331, 497-505`.
- Windows: the BATTERY_INFORMATION, BATTERY_STATUS, BATTERY_QUERY_INFORMATION and BATTERY_WAIT_STATUS layouts
  (36, 16, 12 and 20 bytes) match batclass.h. The three IOCTL codes are the correct CTL_CODE(0x29, 0x10/0x11/0x13,
  METHOD_BUFFERED, FILE_READ_ACCESS) values. The PowerState bits, the Rate sign, the sentinels, the battery class
  GUID and the SetupAPI flags match windows-sys 0.59.0 and Learn. The pack(1) detail-buffer size of 6 is right.
- The UPower live suite is a real behavioural test: it asserts charge, energy, health, both signs of `power`,
  time-to-empty, identity and temperature, and the DeviceAdded and DeviceRemoved refreshes (mutation M4 is caught).
- The fake-root sysfs test asserts an exact generation count (`publishes_only_real_changes`: one new generation
  after a real change, none after no change).
- Power: IOPMAssertion type strings and kIOPMAssertionLevelOn (255) match IOPMLib.h. The Windows
  REASON_CONTEXT layout and version/flag values, the POWER_REQUEST types, and the signatures of
  PowerCreateRequest, PowerSetRequest, SetSuspendState, InitiateSystemShutdownExW and LockWorkStation match
  windows-sys 0.59.0. The request handle is closed on every path.
- logind inhibitors: the reply's descriptor is duplicated, and the original is closed with the reply. The mock
  reports a lock as closed only at EOF, so the release-closes-descriptor tests are meaningful (P1 is caught).
- The sleep barrier: the ticket is set only when the barrier is held, a stale ack is ignored, and the retake
  after resume is tested. The worker starts through a latch, so `open` cannot hang on a backend that fails
  before it signals.
- The polkit `InteractiveAuthorizationRequired` mapping to AUTH_REQUIRED is correct, and `interactive = true` is set
  on the manager actions as the spec intends.
- The integration suite never calls POWER_OFF, REBOOT or Terminate, and the mock records and refuses rather than
  performing actions.

## Tests run and results

- `tools/check.sh bleu_core bleu_rt bleu_service bleu_objc bleu_win bleu_dbus bleu_battery`: all six targets ok.
- `tools/check.sh bleu_core bleu_rt bleu_service bleu_dbus bleu_objc bleu_win bleu_power`: five targets ok. The
  first run failed on windows-aarch64 at `bleu_service/src/hub.c3:71` (an unrelated uncommitted edit in the shared
  working tree, present during that run). Re-run on that target alone: ok.
- Battery unit tests (`compile-test` on the six `*_test.c3` files, private working directory, `-o` to a scratch path):
  76 tests run, 76 passed, including all 19 battery tests.
- `libs/bleu_battery.c3l/tests/run.sh` (dbus-next in a venv): live suite passed (78 tests including
  `upower_live_test::reads_the_line_and_the_battery` and `follows_property_changes_and_device_signals`); absent
  suite passed.
- `libs/bleu_power.c3l/tests/run.sh` (dbus-next in a venv): modern, legacy and none modes, 90 PASS, 0 FAIL,
  "POWER INTEGRATION OK".
- Mutation runs (scratch copies; `libs/` untouched):
  - M1 sysfs discharge sign dropped: 76/76 pass (survived; B-05).
  - M3 sysfs `time_to_full` constant: 76/76 pass (survived; B-05).
  - M4 UPower EnergyRate sign flipped (positive control): 75 pass, 1 fail (caught).
  - P1 inhibitor descriptor never closed: suite exit 1, "releasing the inhibitor closes its descriptor" FAIL (caught).
  - P2 `Power.perform` refuses HIBERNATE synchronously: suite exit 0, polkit check missing (survived; P-08).
- Scratch reproductions:
  - macOS `deliver_sleep` control flow (P-01): PREPARE and RESUMED published 0 times; control publishes 1.
  - Release-after-close under valgrind (P-02): invalid read at `Inhibitor.release (service.c3:287)`, freed in `Power.close (service.c3:92)`.
- Scratch files: `scratchpad/mut/` (mutants and runner), `scratchpad/sleep.3LMC/sleep_probe.c3`,
  `scratchpad/uaf/uaf.c3`.

Not run: any macOS or Windows binary. The macOS and Windows findings come from reading, the cited headers and the
scratch reproductions above.

## Sources fetched (primary)

- UPower `dbus/org.freedesktop.UPower.Device.xml` (gitlab.freedesktop.org/upower/upower, master).
- Linux `Documentation/ABI/testing/sysfs-class-power`, `include/linux/power_supply.h`,
  `drivers/power/supply/power_supply_sysfs.c` (raw.githubusercontent.com/torvalds/linux, master).
- XNU `iokit/IOKit/pwr_mgt/IOPM.h`, `IOPMPowerSource.h`, `IOPMPowerSource.cpp`; IOKitUser `ps.subproj/IOPowerSources.c`,
  `ps.subproj/IOPowerSources.h`, `pwr_mgt.subproj/IOPMLib.h` (raw.githubusercontent.com/apple-oss-distributions).
- Microsoft Learn: `battery-status-str`, `battery-information-str`, `ns-winbase-system_power_status`.
- windows-sys 0.59.0 crate (static.crates.io): `System/Power`, `System/Shutdown`, `System/Threading`,
  `Devices/DeviceAndDriverInstallation`.
- polkit `src/polkit/polkiterror.c` (gitlab.freedesktop.org/polkit/polkit, master).
- systemd: `src/login/logind-core.c`, `logind-dbus.c` fetched; the bus-error name tables were not retrievable.

## Resolution (fix pass)

Status of each finding after the fix pass. "Compiled only" means type-checked for all six targets and not run.
Mutant and valgrind evidence are in the scratchpad (`mut/`, `bp/`).

| ID | Status | Change and evidence |
| --- | --- | --- |
| B-01 | FIXED | One shared diff (`changes`, `common_state.c3`) emitted by `publish.c3` for every backend. Tests: `changes_name_each_transition_once` and friends; fake-tree `plugging_in_is_published_as_an_event`. |
| B-02 | FIXED | Failed read republishes the last good state with `reading = BACKEND_STOPPED`; before any good reading nothing is published. Test: `a_failed_read_keeps_the_last_good_reading`. |
| B-03 | FIXED | `device_kind(type, PowerSupply)`: Type 2 with PowerSupply FALSE is PERIPHERAL. Mock mouse is now Type 2 + FALSE; `upower_test` covers it; live suite passes. |
| B-04 | FIXED | `device_cycles`: zero is unknown. Test: `zero_cycles_are_unknown`. |
| B-05 | FIXED | Exact discharge and time-to-full assertions. Re-targeted M1 (sign dropped in `power_from_current`): killed by `reads_a_discharging_laptop` and `current_now_keeps_its_sign_whatever_the_status`. M3 (time_to_full constant): killed by `reads_a_charging_laptop`. |
| B-06 | FIXED | `Startup` latch in `driver.c3`: every backend's `run` reports success or the poller's fault, and `open` returns it. Linux backends run; macOS and Windows compiled only. |
| B-07 | FIXED (compiled only) | Notifier mutex and `closed` flag; a failed loop join sets `orphaned`, so the backend is not freed while the loop may call it. |
| B-08 | FIXED | `previous_sources` removed; one `sort_by_id` in `common_state.c3`. |
| B-09 | FIXED | `current_now` keeps its sign; `power_now` takes its direction from the status (`flow_from_power`). Tests in `sysfs_test`. |
| B-10 | FIXED | `USB_PD_DRP` is MAINS. Test in `sysfs_test`. |
| B-11 | FIXED | The three doc errors corrected; the String-switch gotcha corrected in `docs/C3_GOTCHAS.md`. |
| B-12 | FIXED | `open` frees the service when `create` fails (`err` path). |
| B-13 | FIXED | Skipped devices and a SetupAPI failure set `reading = DEGRADED`. Compiled and reviewed; no dedicated test. |
| B-14 | FIXED | `fd()` failure closes and frees the connection. |
| B-15 | FIXED | `mkdtemp` directory, removed with `path::rmtree`. |
| B-16 | FIXED locally | `battery::degraded(note)`; the core constructor belongs to `bleu_core` (not owned here, reported to lead). |
| P-01 | FIXED (compiled only) | `continue` instead of `return` in `deliver_sleep`; every queued message is consumed. The IOKit message values are the ones in `bleu_objc` `power_codes.c3`. |
| P-02 | FIXED | Reference-counted `Link` (`link.c3`); release after close is refused with DISCONNECTED. Valgrind: original sources 3 invalid reads, current sources 0. Integration checks `run_after_close_checks`. |
| P-03 | FIXED | Reconnect with backoff (`reconnect_delay`), capabilities kept from open, inhibitor and barrier releases work without the bus. Integration phase `bounce` passes (service answers again, old inhibitor's descriptor closes, new inhibitor taken). |
| P-04 | FIXED | Poller created before `startup.succeed()`; `add` and `fd` failures are a lost bus; no `!!` on I/O in `serve`. |
| P-05 | PARTIAL | A refused retake marks the bus lost and the reconnect retakes the lock. `Cap.DELAY_SLEEP_HOOK` stays YES (written once at open) and no `State` field was added; documented in the README. |
| P-06 | WONTFIX (other library) | The `PolicyKit1.Error.NotAuthorized` / `Cancelled` mapping is in `bleu_dbus/src/errors.c3`, owned by another agent. Suggested as a separate task. |
| P-07 | FIXED | Caps for Suspend, Hibernate, HybridSleep, PowerOff and Reboot come from the `Can*` answers at open (`na` and `no` refuse; `challenge` and `inhibitor-blocked` stay available). |
| P-08 | FIXED | Every silent-pass branch now fails the suite. Mutant P2 (synchronous HIBERNATE refusal): suite exit 1, `perform(HIBERNATE) reaches polkit` FAIL. |
| P-09 | FIXED | `run.sh` refuses an empty bus address; `main.c3` refuses any address that does not name `bus-socket`. |
| P-10 | FIXED | Doc corrected: the value is the profile the request wrote; the daemon's answer is `ActiveProfile`. |
| P-11 | FIXED | `Degraded.UNKNOWN` is the zero member; the integration check expects UNKNOWN without a daemon. |
| P-12 | FIXED | A failed power-status read publishes its fields as unknown instead of keeping the old values. |
| P-13 | WONTFIX (other library) | `SYSTEM_POWER_STATUS` is declared in `bleu_battery` and `bleu_power`; the single declaration belongs in `bleu_win`, which this pass does not own. |
| S-* | not in scope | Unproven suspicions were not part of the fix pass. |

Test results at the end of the fix pass: battery unit set 147 passed (including linked libraries); battery live
suite passed; power unit set 122 passed; power integration 101 PASS, 0 FAIL in modern, legacy, none and bounce.
