# bleu_power

The power service: power profiles, Low Power Mode and battery saver, the lid,
external power, the idle hint, the actions a session can take (suspend, power
off, lock ...), keep-awake and other inhibitors, and the sleep barrier. Module
root `bleu::power`. Design: `docs/ARCHITECTURE.md`. Research and the v1 cut:
`docs/research/battery_power.md` (the "power" half). Implementation notes:
`docs/research/power_impl.md`.

## Public API

* `open(allocator, Options) -> Power*?` blocks until the mechanism has connected and read its first state; `close()` releases it.
* `backend_name()`, `capability(Cap) -> Availability`: what works here, and why not.
* `latest() -> Snapshot{State}*?`, `wait_after(seen)`, `watch`/`unwatch` for state; `subscribe() -> Reader{Event}*?` for `PREPARE_SLEEP`, `RESUMED`, `LID_CLOSED`/`LID_OPENED`, `EXTERNAL_POWER_CONNECTED`/`_DISCONNECTED`.
* `set_profile(Profile) -> Operation{Profile}*?`: the value is the profile the request wrote; the daemon's own answer is `ActiveProfile` in `latest()`.
* `hold_profile(Profile, reason) -> Operation{ProfileHold}*?`; `ProfileHold.release()`.
* `inhibit(InhibitKind, who, why) -> Operation{Inhibitor}*?`; `Inhibitor.release()`.
* `can(Action) -> Operation{Availability}*?`: the system's answer, with the reason when not.
* `perform(Action) -> Operation{Action}*?`: accepted by the system; state changes arrive as events and state.
* `ack(ticket)`: acknowledges a `PREPARE_SLEEP` barrier. Stale tickets are ignored.

Caller-side usage:

```c3
Power* power = power::open(mem, { .backend = AUTO, .sleep_barrier = true })!;
defer power.close();
if (try request = power.set_profile(POWER_SAVER)) { defer request.release(); request.wait()!; }
if (try hold = power.inhibit(KEEP_AWAKE_IDLE, "player", "playing video")) { defer hold.release(); ... }
Reader{Event}* events = power.subscribe()!;
// On PREPARE_SLEEP with a non-zero ticket: save state, then power.ack(event.ticket).
```

## Coverage

Run = exercised by `tests/run.sh` against a private system bus and the python-dbus-next
mock of logind and power-profiles-daemon (101 checks, passing, in four phases: three daemon modes,
modern, legacy and none, and a bus restart under a live client, `bounce`). Compiled only = type-checked for the target with `c3c`; never executed.
"Static" means the answer is a constant in the backend, not asserted by a check.

| Capability | Linux (logind) | macOS | Windows |
| --- | --- | --- | --- |
| Profile read / set | Run (modern, legacy); none: unavailable (Run) | Unsupported (static) | Unsupported (static) |
| Bus restart and reconnect | Run (`bounce`: service answers again, old inhibitor closes its descriptor) | n/a | n/a |
| Profile hold | Run (modern); legacy: unsupported (Run) | Unsupported (static) | Unsupported (static) |
| Low Power Mode read | Unsupported (static) | Compiled only | Unsupported (static) |
| Battery saver read | Unsupported (static) | Unsupported (static) | Compiled only |
| Keep-awake idle | Run | Compiled only | Compiled only |
| Keep-awake display | Unsupported (Run) | Compiled only | Compiled only |
| Keep-awake system | Compiled only | Compiled only | Compiled only |
| Sleep delay barrier | Run (off by default: unsupported, Run); on: Run | Unsupported (static) | Unsupported (static) |
| Block shutdown | Compiled only | Unsupported (static) | Unsupported (static) |
| Suspend | Run (perform, interactive flag, can) | Unsupported (static) | Compiled only |
| Hibernate | Run (polkit refusal maps to AUTH_REQUIRED; a synchronous refusal fails the suite) | Unsupported (static) | Unsupported (static) |
| Hybrid sleep | Refused at open when logind says `na` (Run: can answers na) | Unsupported (static) | Unsupported (static) |
| Power off | Compiled only | Unsupported (static) | Compiled only |
| Reboot | Compiled only | Unsupported (static) | Unsupported (static) |
| Lock | Run (session Lock) | Unsupported (static) | Compiled only |
| Logout | Compiled only (session Terminate) | Unsupported (static) | Unsupported (static) |
| Idle hint | Compiled only (read in state, not asserted) | Unsupported (static) | Unsupported (static) |
| Lid events | Run | Unsupported (static) | Unsupported (static) |
| External power events | Run | Compiled only (IOPS notification) | Compiled only (polled) |
| Sleep and wake events | Run (PREPARE_SLEEP, RESUMED) | Compiled only (no barrier) | Unsupported (static) |

Pure logic (`src/convert.c3`, `src/common.c3`): the `@test` functions in
`src/convert_test.c3` run and pass on Linux (4 functions).

## Not done

* macOS: sleep, shutdown, restart, lock and logout (no route verified on hardware). The sleep barrier: `bleu::iokit::power` acknowledges `CAN_SLEEP` and `WILL_SLEEP` right after the handler returns, so an `ack` cannot hold the sleep; a deferred acknowledgement needs a change in `bleu_objc`. Low Power Mode is polled (every two seconds), not observed through `NSProcessInfoPowerStateDidChangeNotification`. Lid state. Block shutdown.
* Windows: power profiles (overlay scheme calls unverified), hibernate and hybrid sleep (hibernation is not probed), reboot, logout, the delay barrier (no verified equivalent), lid events (payload unverified). External power and battery saver are polled.
* Linux: display inhibitor (logind has none); Low Power Mode and battery saver (no such flag; the power-saver profile is the nearest); idle-hint write (`SetIdleHint`); holds on the legacy profile interface; charge thresholds, TLP, tuned, peripheral batteries (out of v1). The logout method uses `Session.Terminate`, whose polkit action was not verified. A barrier whose ticket logind has already passed on its own timeout is not reported.
* Releases: `ProfileHold.release` and `Inhibitor.release` are queued. After `close()` they are refused with DISCONNECTED (the handle is then spent, and a second release is a no-op); with a full queue they return BUSY and the handle stays live. A lock released while the bus is down is closed locally, so no bus is needed for it. A worker-side failure of a queued release is not reported.
* Reconnect: a lost bus is retried with a backoff (1 s doubling to 30 s). The capabilities are the ones found at open and are not re-read on reconnect.
* Sleep barrier (partial, P-05): when logind refuses to retake the delay lock, the bus is treated as lost and the reconnect takes the lock again. `Cap.DELAY_SLEEP_HOOK` stays YES, because capabilities are written once at open (the state is read from other threads); a `PREPARE_SLEEP` raised while the lock is not held carries ticket 0.
* The fault of a failed request reaches the caller as its excuse only; `error::last()` details stay on the worker thread (a core limitation: `Operation` carries a `fault`, not the detail).

## Verified how

* Linux: `tests/run.sh` (dbus-daemon, mock, C3 client; 101 checks, all passed in the modern, legacy, none and bounce phases).
* Use after free: the release-after-close checks run under valgrind (`--error-exitcode=99`). On the sources of commit `567faed` they report 3 invalid reads, in `Inhibitor.release` and `ProfileHold.release`. On the current sources: 0 invalid accesses, 42 checks passed.
* Mutants: a synchronous HIBERNATE refusal in `Power.perform` makes the suite exit 1 (`perform(HIBERNATE) reaches polkit` fails).
* Linux pure logic: `c3c compile-test` on the library's `src/*_test.c3`, passed (122 tests, including the linked libraries').
* Not run: the macOS and Windows backends (compiled only).
* All six targets: `c3c compile-only` for `linux-x64`, `linux-aarch64`, `macos-aarch64`, `macos-x64`, `windows-x64`, `windows-aarch64` with `bleu_core bleu_rt bleu_service bleu_dbus bleu_objc bleu_win bleu_power`, all clean. macOS and Windows code has never run.
