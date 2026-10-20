# Bleu architecture

Bleu is a desktop **service SDK** written in C3: everything a shell (bar, dock,
launcher, lock screen, notification centre, quick settings) needs from the
operating system, behind one small, uniform contract, on Linux, macOS and
Windows.

It is a set of **small libraries** (`libs/*.c3l`). A shell links only the
services it uses. Shared machinery is factored into infrastructure libraries so
that every backend is thin.

```
                     apps/dmsd  apps/bleud  apps/bleuctl            (applications)
                                  │
              libs/bleu_ipc   libs/bleu_registry   libs/bleu_capi   libs/bleu_json   (outward faces)
                                  │
 battery power network bluetooth audio brightness display color      (services)
 media notify tray session apps sysinfo clipboard windows secrets
 appearance hotkey input
          │            │             │            │           │
      bleu_dbus    bleu_wl      bleu_objc    bleu_win     bleu_ddc    (protocol / platform infra)
      bleu_xdg     bleu_plist   bleu_dl      bleu_rt
                                  │
                              bleu_core                              (vocabulary)
```

Nothing points up. A service depends on `bleu_core`, optionally `bleu_rt`, and
only the infrastructure its backends use.

## The contract every service follows

Seven ideas, identical across all services. If a service does not fit them, the
service is wrong, not the contract.

1. **State is plain data.** A service's state is a struct tree of scalars,
   enums, `typedef` quantities, `String`s and slices — nothing else (no
   pointers, unions or optionals). Therefore `std::encoding::json::marshal` can
   serialise any of it with no per-type code, and the C ABI can describe it.
   (`bleu::observe::Snapshot{State}`.)
2. **State is published, never mutated.** A backend builds a *complete*
   immutable `Snapshot{State}` (arena-owned, refcounted) and publishes it to an
   `Observable{State}`. Consumers read the latest, block for a newer
   generation, or register a listener. Missing intermediate states costs
   nothing because the next snapshot is the whole truth.
3. **Transients are streams.** Things that *happened* (a notification arrived, a
   hotkey fired, a Wi-Fi password is wanted) go through a bounded, broadcast
   `Stream{Event}`. Overflow is reported, and the cure is always "re-read the
   observable".
4. **Requests are operations.** Anything that takes time or can fail late
   (connect, pair, set a DDC value) returns an `Operation{Value}`: accepted →
   running → succeeded/failed/cancelled. Waitable, cancellable, callback-able.
   Accepting a request is not the same as the world changing; the world's
   change arrives through (2).
5. **Capabilities are explicit.** Every optional operation is a `Cap` enum value
   with an `Availability` (available, or *why not*: unsupported OS, backend
   missing, permission needed ...). Never a single `supported` bool; never a
   silent fallback that changes the meaning of the call.
6. **Errors are one vocabulary.** `bleu::error` excuses (`UNSUPPORTED`,
   `UNAVAILABLE`, `PERMISSION_DENIED`, `AUTH_REQUIRED`, ...) classify; the
   thread-local `error::last()` carries the native code and message. Every
   fault maps to a stable `Status` number for C and IPC.
7. **Backends are probed, ordered and replaceable.** `open(allocator, options)`
   walks the platform's backends by priority (e.g. NetworkManager → iwd →
   wpa_supplicant), returns the first that works, and exposes which one it
   chose. `Options.backend` forces one.

### The shape of a service library

```
libs/bleu_<service>.c3l/
  manifest.json
  src/
    model.c3         module bleu::<service>;          State, enums, Cap, Options  (platform-neutral)
    service.c3       module bleu::<service>;          Service: open/close/state/commands, probing
    backend.c3       module bleu::<service>::backend; interface Backend (what a backend implements)
    linux_<name>.c3  module bleu::<service>::linux_<name> @feat(LINUX);   one file group per backend
    macos_<name>.c3  module bleu::<service>::macos_<name> @feat(DARWIN);
    windows_<name>.c3 module bleu::<service>::windows_<name> @feat(WIN32);
    probe.c3         module bleu::<service>::probe;   which backends exist on this OS, in order
    <anything>_test.c3                                @test functions (pure logic only)
```

* Platform code is gated at **module level** with `@feat(LINUX)` /
  `@feat(DARWIN)` / `@feat(WIN32)`; excluded modules are not even parsed on
  other platforms, so a macOS backend may freely import `std::os::darwin`.
* `model.c3` and `service.c3` never mention an operating system.
* A backend never knows about other backends. Shared logic between backends of
  one service lives in a neutral file of that service (`common_*.c3`), shared
  logic between services lives in an infrastructure library.

### Threads

Every service owns exactly one **worker thread** (`bleu::rt::Worker`). Backends
do all native I/O there and publish from there. Public service methods are
callable from any thread: they enqueue a command on the worker's mailbox and
return an `Operation`, or read published state. Native callbacks that arrive on
foreign threads (CoreAudio, WASAPI, GCD) only enqueue to the mailbox; they
never publish directly, never block, and never call back into user code.

Listeners (`Observable.watch`) run on the publishing (worker) thread. They must
be quick; heavy consumers should `wait_after` on their own thread.

### Ownership

* Everything returned by a service is either a scalar, or lives in a refcounted
  `Snapshot`/`Operation` arena that the caller `release()`s.
* Services take an `Allocator` in `open`. Backends use `@pool()` temporaries for
  scratch and the snapshot arena for anything that escapes.
* Allocation failure aborts (C3 convention); I/O failure never does.

### Hidden and undocumented OS APIs

macOS and Windows expose capabilities only through private symbols (DisplayServices
brightness, Apple80211 Wi-Fi, SkyLight Spaces, MediaRemote, IVirtualDesktopManagerInternal,
PolicyConfig ...). Rules:

* Resolve private symbols at **run time** with `bleu::dl` (`dlopen`/`dlsym`/
  `GetProcAddress`), never by link-time reference. A missing or renamed symbol
  makes that capability `UNSUPPORTED_BACKEND`/`BACKEND_MISSING`, never a crash
  and never a failure to load the library.
* Each private use sits in its own file named `*_private.c3`, cites its source
  (project + file + line, or Apple header) in a comment block at the top, and
  states which OS versions it was observed on.
* A public-API path is always preferred when it exists; the private path is a
  separate backend with a lower priority, or a separate `Cap`.

### Honesty about what was verified

The code is type-checked for six targets (`tools/check.sh`). Only Linux is
executed in development, and only against fakes (a fake sysfs root, a private
`dbus-daemon` with mock services, socketpair-based protocol peers). Docs and
`COVERAGE.md` say precisely which backends were run and which were only
compiled. Do not claim more.

## Library catalogue

| Library | Module root | Role |
| --- | --- | --- |
| `bleu_core` | `bleu::error` `bleu::unit` `bleu::availability` `bleu::observe` `bleu::stream` `bleu::operation` | vocabulary: errors, quantities, snapshots, streams, operations |
| `bleu_rt` | `bleu::rt` | wakeups, poller, mailbox, worker thread, unix sockets with fd passing |
| `bleu_dl` | `bleu::dl` | runtime symbol resolution for private/optional APIs |
| `bleu_dbus` | `bleu::dbus` | pure-C3 D-Bus client and server (marshalling, auth, proxies, signals, properties, object export) |
| `bleu_wl` | `bleu::wl` | pure-C3 Wayland client + generated protocol bindings |
| `bleu_objc` | `bleu::objc` `bleu::cf` `bleu::iokit` | Objective-C runtime, CoreFoundation, IOKit helpers (macOS) |
| `bleu_win` | `bleu::win` | COM, WinRT, registry, UTF-16, message loop (Windows) |
| `bleu_ddc` | `bleu::ddc` | DDC/CI + MCCS protocol (transport-agnostic) |
| `bleu_xdg` | `bleu::xdg` | XDG dirs, desktop entries, icon lookup, mime associations |
| `bleu_plist` | `bleu::plist` | Apple property lists (XML + binary) |
| services | `bleu::<service>` | see contract above |
| `bleu_service` | `bleu::service` | the worker-thread hub every service runs on: commands, operations, publication |
| `bleu_ipc` | `bleu::ipc` | DMS line-JSON server and client over a Unix socket, with topic subscriptions (POSIX); the wire `dmsd` and `bleud` serve |
| `bleu_registry` | `bleu::registry` | the table of every service by name: one `Spec` per service (open, state, capabilities, commands), a `Slot` per opened service, `SERVICES` |
| `bleu_capi` | `bleu_*` C symbols | the C ABI and the generated header (`include/bleu`, `docs/CAPI.md`) |
| `bleu_json` | `bleu::json` | state → JSON, JSON-RPC envelope, used by the daemons |
| apps | `bleud`, `bleuctl`, `dmsd` | `bleud`: the daemon serving the registry over `bleu_ipc`; `bleuctl`: its command-line client (also `--embedded`); `dmsd`: DankMaterialShell's `core` server rebuilt on Bleu (POSIX only, see `apps/dmsd/README.md`) |
