# bleu_power: implementation notes

Spec: `docs/research/battery_power.md` (the power half: sections 2, 5.2, 6 and the
v1 cut). Library and coverage: `libs/bleu_power.c3l/README.md`.

## Deviations from the research note

* `Backend` is `AUTO, LOGIND, MACOS, WIN32`, not the research's `PPD_MODERN` /
  `PPD_LEGACY` / `LOGIND` / ... list. The profile daemon is chosen inside the
  Linux mechanism (modern first, then legacy) and reported through `Cap`.
* `Cap` drops `PROFILE_DEGRADED` (degradation is part of `State`),
  `LOW_POWER_SET` (read-only in v1), `SUSPEND_THEN_HIBERNATE` (not in the cut).
* `inhibit` and `can` return operations, not values: both are D-Bus calls on the
  Linux worker (the connection is thread-bound), and `Inhibit` returns a descriptor
  that the worker must duplicate.
* `Options.bus_address` was added (Linux): tests point it at a private bus; "" means
  the system bus default.
* Windows: `REBOOT` and `LOGOUT` are unsupported. The research's cut lists them,
  but the lead's list for Windows names suspend, shutdown and lock only, so they
  were left out. `ExitWindowsEx` and `InitiateSystemShutdownExW` with reboot are
  the routes if they are wanted later.
* The sleep barrier on Linux is opt-in (`Options.sleep_barrier`), because a held
  delay lock delays every sleep by up to `InhibitDelayMaxUSec` when nobody acks.
* macOS keep-awake is three IOPMAssertion types through a local extern: the
  `bleu::iokit::power` module binds only the idle type.

## Verified

* Linux, live: `libs/bleu_power.c3l/tests/run.sh`, 90 checks in modern, legacy and
  none modes against a python-dbus-next mock of logind and power-profiles-daemon.
  Fd passing (Inhibit returns the write end of a pipe; the mock sees EOF when the
  client closes it) and the delay lock (held at start, acked, retaken) are checked
  end to end.
* Windows constants and layouts: `windows-sys` 0.59.0 (`System/Power/mod.rs`,
  `System/Threading/mod.rs`, `System/SystemServices/mod.rs`, `Foundation/mod.rs`);
  `PowerCreateRequest` failure returns `INVALID_HANDLE_VALUE` (Microsoft Learn,
  `nf-winbase-powercreaterequest`, read in this session).
* Type-checked for all six targets.

## Bugs found and fixed while running

* `bleu::rt::unix::Fd` is "open" when `value >= 0`, so a zero-initialised `Fd` is
  descriptor 0. The barrier started zeroed, and `shutdown` closed stdin; the number was
  then reused by the next wake-up eventfd, whose later signal failed inside
  `Mailbox.close` with BACKEND_FAILURE. The barrier is now initialised to `FD_NONE`
  in `create`. Any code that zero-initialises an `Fd` has the same trap.

## C3 0.8.5 findings (for docs/C3_GOTCHAS.md; not appended here)

* Generic functions: declare `fn void f(Operation{Value}* op, Value value) <Value>`
  (type parameter in angle brackets after the parameters; the name must not be all
  caps); call them with `f{Profile}(...)`. Optional parameters are not allowed.
* `any` is a type name: `bool any = false` fails. `usz.max` does not exist: use `~(usz)0`.
* In a generic module such as `bleu::operation`, `Operation{T}` is used without a
  module prefix once `bleu::operation` is imported.
* Enum members of another module are not visible unqualified in a test module
  (`Profile.UNKNOWN`), and `Backend` as a struct name collides with an enum `Backend`
  of the parent module once both are visible: name the private struct differently.
* Functions and constants of other modules need the module prefix even when the
  module is imported (`windows_api::getSystemPowerStatus`).
* A `$if` chain whose branches all return is clean; a trailing `return` after a
  `$if` that returns on Linux produces "This code will never execute".
* `c3c --sources` needs one argument per file (not a joined string).
