# bleu_sysinfo

Machine health for a desktop shell: processor load per core, memory and swap,
local disks and their usage, network rates per interface, temperatures where
the kernel exposes them, uptime and identity strings, the busiest processes,
and ending a process. Module root `bleu::sysinfo`. Depends on `bleu_core`,
`bleu_rt`, `bleu_service` and `bleu_win` (Windows only; the dependency is
listed for all targets).

The service samples on its own worker thread every `Options.interval` (1 s by
default, at least 200 ms) and publishes a whole new `State` only when something
changed. Rates and percentages are computed from the real time between samples,
so consumers never do deltas themselves.

## Public API

* `Sysinfo* sysinfo::open(Allocator, Options)`: first working backend; `Options`
  holds `backend`, `interval`, `process_count` (10 by default) and `root` (Linux fake-root prefix).
* `close()`, `backend_name()`, `capability(Cap)` → `Availability` (available, or why not).
* `latest()`: newest `Snapshot{State}*`, retained. Call `release()`.
* `wait_after(generation, timeout)`: block until a newer state exists.
* `watch(listener, ctx)` / `unwatch(id)`: call on the worker thread; keep them quick.
* `subscribe()`: `Reader{Event}*` for `MOUNT_ADDED`, `MOUNT_REMOVED`, `INTERFACE_ADDED`, `INTERFACE_REMOVED`.
* `kill(pid, KillMode)` → `Operation{KillReceipt}*`: `TERMINATE` (SIGTERM; `TerminateProcess` on Windows), `FORCE` (SIGKILL).
  Failures: `NOT_FOUND`, `PERMISSION_DENIED`, and `INVALID_ARGUMENT` before anything is signalled for pid 0,
  an id at or above 2^31 (a negative `pid_t` would name a process group or every process), this process, or pid 1
  without `FORCE` (`check_kill_target`, `src/kill_target.c3`, checked on the caller's thread and again on the worker).
* `State`: `cpu` (model, total usage, per-core usage and frequency, load average),
  `memory`, `mounts`, `interfaces`, `temperatures`, `processes`, `identity`.
  Unknown values are `Maybe` empties; a rate or share on the first sample is empty.

## Coverage matrix

Status words: **Run** = executed on Linux (fake root, or the live sandbox where noted);
**Compiled** = type-checked for the OS, not executed; **Not done** = not implemented, the
capability says `UNSUPPORTED_BACKEND` or `HARDWARE_ABSENT`.

| Capability | Linux `procfs` | macOS `mach` | Windows `win32` |
| --- | --- | --- | --- |
| CPU total and per-core usage | Run (fake root; live) | Compiled | Compiled |
| Per-core frequency | Run (fake root; live: absent here, reported as `HARDWARE_ABSENT`) | Not done | Compiled (`DEGRADED`) |
| CPU model | Run (fake root; live) | Compiled (sysctl `machdep.cpu.brand_string`, unverified on Apple Silicon) | Compiled (registry) |
| Load average | Run (fake root; live) | Compiled | Not done (Windows has none; empty) |
| Memory, swap | Run (fake root; live) | Compiled | Compiled |
| Memory cache | Run | Compiled | Not done (empty) |
| Disk mounts and usage | Run (fake root; live) | Compiled | Compiled |
| Network rates per interface | Run (fake root; live) | Compiled (32-bit counters) | Compiled |
| Temperatures | Run (fake root hwmon; live: no sensors here) | Not done (SMC is private) | Not done (ACPI via WMI) |
| Top processes: pid, name, cpu, rss | Run (fake root; live) | Compiled | Compiled |
| Command line | Run (fake root; live) | Not done | Not done |
| Process owner | Run (fake root; live) | Compiled | Compiled (`DEGRADED` without elevation) |
| Uptime, hostname, OS, kernel, arch | Run (fake root; live) | Compiled | Compiled |
| Process kill | Run: refusals before signalling, a child the test spawns is ended, NOT_FOUND | Compiled (same POSIX code as Linux) | Compiled |
| Topology events | Run (a mount added between samples) | Compiled | Compiled |

Fake-root tests are in `src/linux_test.c3`; parsers are golden-tested on real
sandbox output in `src/procfs_parse_test.c3` (fixtures in `fixtures/`).

## Not done

* Disk I/O rates, GPU, fans: outside the v1 cut.
* macOS: SMC temperatures and fans (private), per-core clocks, command lines
  (KERN_PROCARGS2), `kern.osproductversion` and `hw.machine` names not checked on a Mac.
* Windows: temperatures (WMI), command lines (PEB read), load average (no such thing).
  Per-core times come from `NtQuerySystemInformation` class 8 instead of
  `GetSystemTimes`, and the processor count comes from the same result instead of
  `GetLogicalProcessorInformationEx`; both are equivalent and documented in code.
* Linux: command lines over 8 KiB are reported empty, not truncated; processes that
  `hidepid` hides show no owner; `Options.root` is ignored elsewhere.
* Kill: the EPERM path is not run on Linux; Windows kills both modes with `TerminateProcess`.
  A pid can be reused between the caller's snapshot and the worker's signal: the kill names a bare
  pid, so the signal can reach a different process of the same user in that window. Closing it needs
  the start time the caller observed in the request (an API change) or a pidfd (Linux 5.3+).
* Per-core frequency is read by each processor's own number, so offline processors are skipped
  correctly. Malformed net-device and mount lines are skipped silently, not counted.
* A failed `poll(2)` in the sampler stops sampling with no event: queued kills fail with `DISCONNECTED`,
  but `latest()` keeps returning the last state without a notice (not reachable in tests).

## Verified how

* **Run on Linux x86-64** (glibc, this sandbox): the sysinfo `@test` functions pass
  (`c3c compile-test` with `--lib bleu_core --lib bleu_rt --lib bleu_service --lib bleu_win`):
  golden parsers on real kernel text, delta and ordering arithmetic, the kill gate (pure, every
  dangerous id), a live kill of a child the test spawns, abandoned kills failing with `DISCONNECTED`,
  the offline-CPU frequency mapping, truncated and malformed lines, and the fake-root integration test.
* **Compiled only**: `c3c compile-only --target` for `linux-x64`, `linux-aarch64`,
  `macos-x64`, `macos-aarch64`, `windows-x64`, `windows-aarch64`: all clean.
* Layouts and constants cited in the source: XNU headers (macOS), Wine mirror and ReactOS
  headers, ntapi 0.4.1 and sysinfo 0.33.1 (Windows), and the sandbox's glibc headers
  (`_SC_CLK_TCK`, `utsname`, `statvfs`, checked with gcc). See `docs/research/sysinfo_impl.md`.
