# bleu_session: implementation notes

Spec: `docs/research/session_windows_input.md`, section "session" and its v1 cut. This file records
what was built, what deviates from the research, and what was verified and how. The library's
README (`libs/bleu_session.c3l/README.md`) has the API, the coverage matrix and the not-done list.

## Built

* Shared (`src/common_*.c3`, `src/service.c3`, `src/idle_watch.c3`, `src/driver.c3`, `src/probe.c3`):
  the `State`/`Event`/`Command` model, the service surface, `IdleWatch` (one reader per watch, filtered
  by watch id), the idle registry (`common_idle.c3`), the polled state shared by macOS and Windows
  (`common_polled.c3`), and the ordering rule for changes (`common_events.c3`: apply, publish, announce).
* Linux: logind over `bleu_dbus` (`src/logind*.c3`). Live-tested.
* macOS: CoreGraphics idle and session dictionary, IOKit power notifications, and the private lock
  request in `macos_lock_private.c3` behind `Options.allow_private`. Type-checked only.
* Windows: WTS session notifications through `bleu::win::session`, the message loop's power
  broadcasts, `GetLastInputInfo`, `LockWorkStation`. Type-checked only.

## Deviations from the research

1. **macOS lock events are polled, not observed.** The research (and the brief) name
   `com.apple.screenIsLocked`. `bleu_objc` already has that constant, but a distributed notification is
   delivered where its observer's thread runs a run loop; the worker runs a CFRunLoop only for the
   power notifications. Polling `CGSessionCopyCurrentDictionary` every `idle_poll` gives the same states
   with the same unverified key. Revisit if the notification is verified on hardware.
2. **macOS sleep uses IOKit power notifications, not NSWorkspace.** `NSWorkspace` notifications are
   posted on the main thread, which a service worker does not run. `bleu_power` uses the same IOKit
   route for the same reason. The brief asked for NSWorkspace; this is the reason it was not used.
3. **`lock()` is `LockWorkStation` (Windows) and `Manager.LockSession` of the current session (logind).**
   The brief's `lock()` is kept; it is a request that completes once the OS accepted it. `bleu_power`
   already implements a session Lock and a Windows `LockWorkStation`; the two services now overlap on
   lock. The lead should decide whether `bleu_power` keeps its own lock action.
4. **`unlock()` is only a request.** logind's `UnlockSession` signals the session's locker; nothing here
   unlocks. Windows and macOS have no public unlock: UNSUPPORTED.
5. **Idle on Linux is refused, not emulated.** The research's L2 route (ext-idle-notify) needs `bleu_wl`,
   which is unfinished (its own README: the poller path is untested, only the control plane is done).
   `IdleHint` is read but never set, because only the shell sets it. Pending: see the README.
6. **Options.idle_thresholds are ordinary `State.idle` entries, not events of their own.** They become
   configured slots of the registry; their edges carry watch 0 and the threshold they refer to.
7. **logind signals used.** `PropertiesChanged` (subtree, every session), `PrepareForSleep`,
   `SessionNew` and `SessionRemoved`. The `Session.Lock` and `Session.Unlock` signals are not
   subscribed: they ask the session's locker to act, and the change they cause arrives as
   `LockedHint`, which is read. The session of this process comes from `GetSessionByPID`;
   `XDG_SESSION_ID` is not consulted.
8. **`select_driver` distinguishes UNSUPPORTED from UNAVAILABLE for a forced backend.** `bleu_battery`
   returns UNSUPPORTED when a forced backend does not probe; here UNSUPPORTED means the backend is not
   listed for this platform, and UNAVAILABLE means it is listed but not running. The battery service
   has the other behaviour; the lead may want to align them.

## Verified

* `tests/run.sh` (Linux x86-64, c3c 0.8.5_1, dbus-daemon 1.14.10, python-dbus-next 0.2.3, Python 3.13):
  - live: `logind_live.c3` against `mock_logind.py` on a private bus: the state read (session 32:
    alice, uid 1000, seat0, wayland, active, local; c1: tty, remote, no seat; IdleHint false), lock ->
    LOCKED and `State.locked`, unlock -> UNLOCKED, lock_session("c1"), terminate_session("nope") fails with
    BACKEND_FAILURE, watch_idle refused with UNSUPPORTED, Suspend -> WILL_SLEEP with `State.sleeping`,
    then DID_WAKE;
  - calls: the mock's log equals `LockSession 32 / UnlockSession 32 / LockSession c1 /
    TerminateSession nope / Suspend false`, in that order;
  - absent: with no owner for org.freedesktop.login1, open(LOGIND) is UNAVAILABLE;
  - pure: 5 `@test`s in `common_test.c3` (idle edges per watch and their order, configured thresholds,
    record dedupe, time conversions, type names).
  Three consecutive full runs passed.
* `tools/check.sh bleu_core bleu_rt bleu_service bleu_objc bleu_win bleu_dbus bleu_dl bleu_session`:
  clean on all six targets.
* A standalone `dbus-next` client showed the mock emits PrepareForSleep(true) immediately and
  PrepareForSleep(false) after the gap, so the delay found during testing was on the worker (below).

## Found in the shared libraries (for the lead)

* **`bleu_dbus`: a signal read during a blocking `Connection.call` waits in the inbox, and the poller
  does not see it.** `read_available` pulls the signal off the socket while a call waits for its reply;
  `parse_inbox` queues it for dispatch, which only `Connection.process` performs; the fd is then no
  longer readable, so a `poller.wait` sleeps on a message already held. Found here: the sleep signal
  was dispatched only when the next signal arrived. The fix in this library is to call `process()`
  after every blocking call and to skip the wait while a change is known. The same pattern exists in
  the battery and power loops (`refresh` makes blocking calls after `process`): the lead should check
  whether a signal can be stuck there until the poll interval. Suggested fix in `bleu_dbus`: after a
  blocking call, dispatch the queued messages, or expose `Connection.has_queued()` for callers.
* **`bleu_dbus`: `errors::for_name` maps no `org.freedesktop.login1.*` names** (NoSuchSession,
  AccessDenied-like login1 errors). Unknown names become BACKEND_FAILURE with the text in `error::last()`.

## Gotchas found (for `docs/C3_GOTCHAS.md`, which this brief does not let me edit)

* `Atomic{ulong}` needs `import std::atomic` (the error suggests `std::atomic::types`).
* `Snapshot{Event}` and `Snapshot{State}` need `import bleu::observe` in every file that names them.
* Two enums in one module with the same member (`Cap.LOCK` and `Request.LOCK`) are ambiguous without
  qualification; qualify every member you use.
* A module named `bleu::session` and a local field named `session`: fine as a field, but a local
  variable of the same name shadows the module for the rest of its scope (renamed to `object`).
* `bleu::win::message_loop` exports its own `EventKind`: qualify both (`session::EventKind` vs
  `message_loop::EventKind`).
* `if (catch err = optional) {...} else {...}` is the pattern for an optional value that must be used
  in the else branch; `if (catch x) {}` with a `//` comment is the way to ignore one.
* `assert(false, ...)` is rejected: use `unreachable("...")`.
* `catch` is only valid as an if/while condition: `assert(catch f() == E)` does not compile.
* A dbus-next service must return D-Bus structs as Python lists, not tuples (`(uo)` in a property
  reply fails with "must be Python type list").

## Open

* Wayland idle backend (`ext-idle-notify`): pending `bleu_wl`.
* macOS and Windows: no run has happened anywhere; the first run should check `CGSSessionScreenIsLocked`,
  the `SACLockScreenImmediate` symbol, `WTS_SESSION_LOCK = 0x7` (single source), and the IOKit power
  events on a real machine.
