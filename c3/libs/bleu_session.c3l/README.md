# bleu_session

The session service: whether the screen is locked, whether the user is idle, whether the machine
is going to sleep, which login sessions and seats exist, and the lock, unlock and terminate
requests. Module root `bleu::session`. Depends on `bleu_core`, `bleu_rt`, `bleu_service`,
`bleu_objc`, `bleu_win`, `bleu_dbus`, `bleu_dl`.

No lock screen, no authentication, no PAM: the service requests a lock and observes the state; the
locker (a separate program) renders and authenticates. Inhibiting idle sleep is `bleu_power`'s job.
Design and the research behind it: `docs/research/session_windows_input.md`; implementation notes:
`docs/research/session_impl.md`.

## Public API

* `session::open(allocator, Options) -> Session*?`: `Options` = `backend` (AUTO, LOGIND, MACOS,
  WIN32), `bus_address`, `idle_thresholds` (`Duration[]`), `idle_poll`, `allow_private`.
* `Session.latest()`, `wait_after(seen, timeout)`, `watch`, `unwatch`: `Snapshot{State}`.
  `State`: `locked`, `idle_hint` (`Maybe{bool}`), `sleeping`, `current` (`SessionInfo`: id, user,
  uid, seat, type, active, remote), `seats`, `sessions`, `idle` (one `IdleStatus` per threshold).
* `Session.subscribe() -> stream::Reader{Event}*?`: LOCKED, UNLOCKED, WILL_SLEEP, DID_WAKE, and the
  IDLE/RESUMED edges of the configured thresholds (watch 0).
* `Session.lock()`, `unlock()`, `lock_session(id)`, `terminate_session(id)` -> `SessionOperation*?`
  (`Operation{Request}`): the value is the request that was carried out.
* `Session.watch_idle(threshold) -> IdleWatch*?`; `IdleWatch.next(timeout) -> EventKind?` (IDLE or
  RESUMED), `IdleWatch.close()`. Close every watch before the session.
* `Session.capability(Cap) -> Availability`: why a request is refused. Refused calls return
  `error::UNSUPPORTED` or `error::UNAVAILABLE`, never a silent no-op.
* `Session.backend_name()`, `Session.close()`.

## Coverage

Run = executed on Linux x86-64 against a private `dbus-daemon` and a `python-dbus-next` mock.
Compiled = type-checked for the target by `tools/check.sh` only; nothing was executed.

| Capability | Linux / logind | Linux / ext-idle-notify | macOS | Windows |
| --- | --- | --- | --- | --- |
| LOCK_STATE | Run | - | Compiled (key unverified) | Compiled |
| LOCK | Run | - | Compiled, private gate (off by default) | Compiled (LockWorkStation) |
| UNLOCK | Run (the mock plays the locker) | - | Not done (no public API) | Not done (no API) |
| LOCK_SESSION | Run | - | Not done (UNSUPPORTED) | Not done (UNSUPPORTED) |
| TERMINATE_SESSION | Run (refusal path only) | - | Not done (UNSUPPORTED) | Not done (UNSUPPORTED) |
| IDLE_WATCH | Not done (UNSUPPORTED, see below) | Not done (pending bleu_wl) | Compiled (polled) | Compiled (polled) |
| IDLE_HINT | Run | - | Not done (UNSUPPORTED) | Not done (UNSUPPORTED) |
| SLEEP_EVENTS | Run (PrepareForSleep, `Manager.Suspend`) | - | Compiled (IOKit power) | Compiled (WM_POWERBROADCAST) |
| SESSION_LIST | Run (sessions and seats) | - | Not done (UNSUPPORTED) | Not done (UNSUPPORTED) |
| Pure logic (idle edges, record dedupe, type names) | Run (`common_test.c3`, 5 tests) | - | - | - |

## Not done

* **Idle on Linux.** logind stores `IdleHint` for the shell; it does not measure input, so
  `watch_idle` is refused. The Wayland source is `ext-idle-notify-v1`: `bleu_wl` generates the
  bindings and tests them against its in-process mock, but no backend uses them yet, and
  `bleu_wl`'s own README says the poller path is untested. Pending until `bleu_wl` is finished; the
  backend would sit beside `logind.c3` and report `IDLE_WATCH` as DEGRADED.
* **Idle on macOS and Windows** is polled every `idle_poll` (1 s by default), so an edge can be
  up to one poll late. No idle time is returned: only edges, as on Wayland.
* **The macOS lock state** reads `CGSSessionScreenIsLocked` (UNVERIFIED on hardware; an absent key
  is read as unlocked).
* **The macOS lock request** needs `Options.allow_private` and `SACLockScreenImmediate` (UNVERIFIED);
  without the gate the capability is UNSUPPORTED_BACKEND.
* **Sleep on macOS** uses IOKit power notifications, not NSWorkspace: NSWorkspace posts on the main
  thread, which the worker does not run. Commands on macOS and Windows wait up to one poll.
* **Sessions on macOS and Windows**: no list; the Windows `current.id` is the WTS session id.
* **No locker, no PAM, no authentication, no idle inhibitor** (`bleu_power`).
* **logind errors:** `bleu_dbus` maps no `org.freedesktop.login1.*` names, so `NoSuchSession` is
  BACKEND_FAILURE with the text in `error::last()`.
* **Polkit:** LockSession, UnlockSession and TerminateSession may be refused by polkit
  (PERMISSION_DENIED or AUTH_REQUIRED); the behaviour under a real polkit policy is not tested.
* `Options.idle_thresholds` are not measured where IDLE_WATCH is unavailable; `State.idle` stays empty.
* A watch must be closed before its session: the stream's reader list is freed by `Session.close`.

## Verified how

* `tests/run.sh` (Linux x86-64, c3c 0.8.5, dbus-daemon 1.14.10, dbus-next 0.2.3): the live test
  `logind_live.c3` (state read, lock, unlock, lock_session, a refused terminate, the refused idle
  watch, and Suspend producing WILL_SLEEP then DID_WAKE), checked against the calls the mock logged
  in order; then the absent test, with no owner for org.freedesktop.login1. Three consecutive runs
  passed. The library's pure tests run inside the same `compile-test`.
* `tools/check.sh bleu_core bleu_rt bleu_service bleu_objc bleu_win bleu_dbus bleu_dl bleu_session`:
  clean on all six targets. macOS and Windows were type-checked only; no macOS or Windows code ran.
* `c3fmt --check` clean on `src/` and `tests/`.

Run the tests:

    libs/bleu_session.c3l/tests/run.sh
