# The Bleu C ABI

`libbleu_capi` exposes Bleu's services to C, C++, Python (ctypes), Swift, Rust and any
language with a C FFI. This document is the convention every service follows. The
header is generated from the C3 sources: read it in `include/bleu/`, and never edit it.

| Piece | Where |
| --- | --- |
| C3 sources (the API) | `libs/bleu_capi.c3l/src/` (`core.c3`, `entry.c3`, `handles.c3`, `battery_api.c3`, `brightness_api.c3`) |
| Generated headers | `include/bleu/bleu.h` (umbrella), `core.h`, `battery.h`, `brightness.h` |
| Build | `tools/capi/build.sh` writes `out/capi/libbleu_capi.so`, `.a` and `exports.txt` |
| Header generator | `tools/capi/genheader.py` (Python 3 stdlib only) |
| Consumer tests | `tools/capi/tests/run.sh` (C11, C++17, Python ctypes, valgrind, two translation units) |
| Version | `BLEU_ABI_VERSION` (integer, 1 today); `bleu_abi_version()` returns the library's |

Build and check:

```
tools/capi/build.sh            # libraries into out/capi, headers into include/bleu
tools/capi/build.sh --check    # fails if include/bleu is stale
tools/capi/tests/run.sh        # consumers, after build.sh
```

Minimal use from C:

```c
#include <bleu/bleu.h>

bleu_battery_options_t options = { .struct_size = sizeof options };  /* defaults elsewhere */
bleu_battery_t *battery = NULL;
if (bleu_battery_open(&options, &battery) != BLEU_STATUS_OK) { /* see bleu_last_error */ }

bleu_snapshot_t *snapshot = NULL;
if (bleu_battery_wait(battery, 0, 5000, &snapshot) == BLEU_STATUS_OK) {
    const bleu_battery_state_t *state = bleu_battery_snapshot_state(snapshot);
    /* read state->on_mains, state->sources ... while the snapshot lives */
    bleu_snapshot_release(snapshot);
}
bleu_battery_close(battery);
```

## 1. Names and types

* Functions: `bleu_<service>_<verb>`. Service-free functions are the shared machinery:
  `bleu_snapshot_*`, `bleu_reader_*`, `bleu_packet_*`, `bleu_operation_*`, `bleu_last_error`,
  `bleu_status_name`, `bleu_free`, `bleu_abi_version`.
* Types: `bleu_<name>_t`. Enumerators: `BLEU_<TYPE>_<MEMBER>` (`BLEU_BATTERY_KIND_BATTERY`), and
  they are `#define`s, so an enum is an integer type of known width.
* Handles are opaque pointers: `bleu_battery_t`, `bleu_snapshot_t`, `bleu_reader_t`,
  `bleu_packet_t`, `bleu_operation_t`. Never dereference them and never free them with `free`.
* Plain data (states, events, options, results) are C structs with the same layout as the C3
  types they come from. Measurements the platform may not report are `bleu_maybe_<x>_t`
  (`{ value, has_value }`); "unknown" is never zero.

## 2. Status, errors and out-parameters

* Every fallible function returns `bleu_status_t` (`int32_t`; `BLEU_STATUS_OK` is 0). The numbers are
  the ordinals of `bleu::error::Status`, the wire contract IPC also uses. Append only.
* Results come through out-parameters, which are set to NULL before anything can fail.
* Exceptions, which return a value directly: `bleu_abi_version`, `bleu_status_name` (static
  string), the borrowed accessors (`*_snapshot_state`, `*_source_at`, `*_device_at`,
  `*_control_at`, `*_packet_event`, `*_set_result`), and the destructors (`*_release`,
  `bleu_free`), which return `void`. `bleu_<service>_close` does return a status, because it can
  refuse (section 3).
* `bleu_last_error(&detail)` copies the failure of the most recent call that failed on this
  thread: `status`, `domain` (which subsystem produced `native_code`), `native_code` and a
  NUL-terminated `message` of at most 255 bytes. Every entry point clears it on entry, so read it
  right after the failing call. For an operation, `bleu_operation_wait` copies the operation's
  native details here.
* `bleu_status_name(status)` gives `"NOT_FOUND"` and so on; unknown numbers give `"INVALID"`.

## 3. Options and handles

* An options struct starts with `uint32_t struct_size`: the caller writes `sizeof` the struct it
  compiled against. Zero every member you do not set: zero means the default (backend `AUTO`,
  poll interval 5 s, real system root). A NULL options pointer means all defaults.
* A shorter struct from an older caller is accepted: members beyond its `struct_size` are the
  defaults. A `struct_size` of 0 is `BLEU_STATUS_INVALID_ARGUMENT`.
* `bleu_<service>_open(options, &handle)` opens the first working backend. It fails with
  `UNAVAILABLE` when none works here and `UNSUPPORTED` when the named backend does not exist on
  this platform.
* `bleu_<service>_close(handle)` stops the service. It fails with `INVALID_STATE`, and the handle
  stays usable, while readers from it are not released. It removes all listeners. Do not call
  it while another thread is inside a call on the same handle.
* Timeouts are milliseconds as `int64_t`: `-1` waits forever, `0` only polls, and a value above
  one year counts as forever. A timed-out wait returns `BLEU_STATUS_TIMEOUT` and is not an error to log.

## 4. State: snapshots

* `bleu_<service>_snapshot(handle, &snapshot)` returns the newest state, retained. It fails with
  `UNAVAILABLE` before the first reading.
* `bleu_<service>_wait(handle, seen, timeout_ms, &snapshot)` returns a state with a generation
  greater than `seen`. Start with `seen = 0` and pass the previous generation next time.
* `bleu_<service>_snapshot_state(snapshot)` returns `const bleu_<service>_state_t *`, borrowed:
  valid until the snapshot is released. It returns NULL for a snapshot of another service.
* `bleu_snapshot_generation`, `bleu_snapshot_retain` (an owned copy of any snapshot, including a
  watch view) and `bleu_snapshot_release`.
* Everything reached from a state (its strings, slices and nested records) is valid until the
  snapshot is released. Take a copy if you keep anything longer.
* Slices are `bleu_slice_t { void *ptr; size_t len; }`. The header cannot name a slice's element
  type, so read elements through the accessor: `bleu_battery_source_at(state, i)`,
  `bleu_brightness_device_at(state, i)`, `bleu_brightness_control_at(device, i)`. Text in a slice
  is UTF-8 and not NUL-terminated.

## 5. Listeners

* `bleu_<service>_watch(handle, callback, context, &id)` and `bleu_<service>_unwatch(handle, id)`.
  `callback` has the type `bleu_<service>_listener_t`:
  `void (*)(void *context, const bleu_snapshot_t *snapshot)`.
* The callback runs on the service's worker thread for every new state, and once on the calling
  thread from inside `watch` for the current state. Rules: it must return quickly and must not
  block; it must not call into its own handle's service calls (`snapshot`, `snapshot_json`, `wait`,
  `watch`, `unwatch`, `subscribe`, `refresh`, `set_level`, `close`): those return
  `BLEU_STATUS_INVALID_STATE` straight away. Accessors on snapshots and packets, and `capability` and
  `backend_name`, do not take the service's lock and work; calls into other handles are fine.
* The snapshot argument is a view, valid only during the call. `bleu_snapshot_retain` keeps it.
* After `unwatch` returns, the callback is not running and will not run again.

## 6. Events

* `bleu_<service>_subscribe(handle, &reader)` gives a reader that receives every event published
  after the subscription. Release it with `bleu_reader_release` before closing the service.
* `bleu_reader_next(reader, timeout_ms, &packet)`: `TIMEOUT` when nothing arrived, `DISCONNECTED`
  when the service closed and the queue is empty. Read the event with
  `bleu_<service>_packet_event(packet)` (borrowed), then `bleu_packet_release`.
* `bleu_reader_take_dropped` counts events lost to overflow since the last call. The cure for
  any loss is to read the state again: events are transients, the state is the truth.

## 7. Operations

A request that takes time (`bleu_brightness_set_level`) returns a `bleu_operation_t *` at once.

* `bleu_operation_wait(op, timeout_ms)`: `OK` means it succeeded; otherwise `TIMEOUT` (still
  running), `CANCELLED`, or the failure's status, with the native details in `bleu_last_error`.
* The result is read with the typed accessor of the request: `bleu_brightness_set_result(op)`
  returns `const bleu_brightness_applied_t *`. It is NULL unless the operation succeeded, and it is
  valid until `bleu_operation_release`.
* `bleu_operation_phase` (`PENDING`, `RUNNING`, `SUCCEEDED`, `FAILED`, `CANCELLED`),
  `bleu_operation_detail` (the failure's native details), `bleu_operation_cancel` (asks the
  service to stop; whether it can is the service's decision, see section 11).
* `bleu_operation_release`. An operation that is still running keeps going, but nobody can read
  its result after this.
* Inside the library an operation is a type-erased handle: `COperation { OperationOps *ops; void *native; }`,
  where the `OperationOps` table of function pointers is written once per service
  (`brightness_api.c3`). Its result pointer is typed by the request function that returned the operation.

## 8. Threads

* Every exported function may be called from any thread, including threads the C3 runtime did not
  start (a `pthread`, a GUI thread). Each exported call runs in a temporary allocator; a nested
  call (from a listener) reuses it. Mechanism: `capi::@capi_scope` in `entry.c3`, which uses
  `rt::foreign::@foreign_entry` for the outermost call on a thread that has no temporary allocator.
* Handles may be shared between threads. The only rule is the one in section 3: do not close a
  handle while another thread is using it.

## 9. Strings and buffers

* Text you pass in is a NUL-terminated `const char *`; NULL means "unset" where the struct says so
  (`root`, `bus_address`). The library copies what it keeps.
* Text the library returns is written to `char **out, size_t *len`: `len` excludes the NUL, and the
  buffer is NUL-terminated. Free it with `bleu_free`. The same applies to `bleu_*_backend_name`.

## 10. JSON, with no binding at all

`bleu_<service>_snapshot_json(handle, &text, &len)` and `bleu_snapshot_json(snapshot, &text, &len)`
return the state as JSON (`bleu_json` rules): member names are the C3 names, enums are lower-snake
strings (`"charging"`), an unset measurement is `null`, `Level` is a number from 0 to 1, a duration is
integer microseconds, and a struct is an object. Any language with a JSON parser can use every
service this way. The test `capi_ctypes.py` checks the JSON against the struct values.

## 11. Versioning and evolution

* `BLEU_ABI_VERSION` (the header) and `bleu_abi_version()` (the library) are integers. A program
  that needs a feature compares the library's value with the constant it compiled against.
* Only append. A new function, a new options or request member (at the end of the struct,
  guarded by `struct_size`), a new enumerator (at the end) or a new service is an addition, and it
  bumps `ABI_VERSION` in `core.c3`. Never reorder, renumber, rename or remove. A breaking change
  is a new name.
* `bleu::error::Status` ordinals and the enum members of the services are part of the contract.
  The unit test `status_numbers_follow_the_error_vocabulary` checks the status numbers.
* Known limits of this version: capabilities and operation cancellation are reported as the
  services report them. For example, brightness ramps end `CANCELLED` when a newer request
  replaces them; `bleu_operation_cancel` alone does not stop a ramp (the brightness service does
  not poll the cancel flag yet).

## 12. The header generator

`tools/capi/genheader.py` reads c3c's own header (`--header-output`) and writes the public
headers:

* C3 export names are kept. Types from other Bleu modules are renamed: `bleu_battery__State` becomes
  `bleu_battery_state_t`, `bleu_capi_battery_api__BatteryListener` becomes `bleu_battery_listener_t`.
* Enum members become `#define`s (C3 emits them as global variables, which every translation unit that
  includes the header would define).
* `String` and `c3slice_t` become `bleu_slice_t`; `char` is C `char`; `char *` in a field or a
  return is `const char *`; struct pointers returned are `const`, and so are input struct
  parameters. Out-parameters and opaque handles are not const.
* Only the types an exported function reaches are emitted. Any fault (`c3fault_t`), `any`, `typeid`,
  `$`, `std_`, or C3 identifier in the output is a build error, so no C3-specific type can leak.
* `<* ... *>` blocks before an `@export` declaration become C comments. A struct marked
  `// capi:opaque` is declared only.
* Output is deterministic: running it twice gives identical files. `--check` fails when they differ.
* The exact list of exported functions goes to `exports.txt`. `build.sh` turns it into a linker
  version script (section 13).

## 13. Symbol visibility

A C3 dynamic library exports every function, including the methods of its own types (names such as
`bleu_battery__Battery.close`). On Linux, `build.sh` links with a version script generated from
`exports.txt` (`global:` the header's functions, `local: *`), and checks with `nm -D` that the shared
library exports exactly those names. Other hosts: the library exports all of C3's symbols, and
`build.sh` says so. Windows needs a `.def` file (`--windef`) and macOS an `-exported_symbols_list`
file; neither is written yet.

## 14. Adding a service

The C3 service library (`libs/bleu_<service>.c3l`) is not changed by the C API. Its owner does
not need to know the C names. Steps:

1. Copy `libs/bleu_capi.c3l/src/battery_api.c3` to `<service>_api.c3` and rename. Keep the shape:
   options (`struct_size` first, `@export("bleu_<service>_options_t")`), the opaque handle
   (`// capi:opaque`, `@export("bleu_<service>_t")`), the listener alias, the watch node, the
   `*Ops` tables, then the exported functions in the same order.
2. Every exported function starts with `capi::@capi_entry()` (or `capi::@capi_scope()` for
   accessors and destructors), and checks each pointer argument.
3. Put a `<* ... *>` doc block above every exported declaration: it becomes the C comment.
4. Add the name to `SERVICES` in `tools/capi/genheader.py`, the library to `libs` in
   `tools/capi/build.sh`, and the dependency to `libs/bleu_capi.c3l/manifest.json`.
5. Add a `@test` file for the pure parts, and extend `capi_smoke.c` and `capi_ctypes.py` with
   the new service's open, state, wait, watch and one operation.
6. `tools/capi/build.sh`, then `tools/capi/tests/run.sh`, then `tools/check.sh` for all six targets.

## 15. What is not in this version

* Slice elements are reached through accessors, not typed in the header (section 4).
* Brightness ramps do not honour `bleu_operation_cancel` (section 11).
* Only Linux is run; the other platforms are type-checked (`tools/check.sh`) and their backends
  are absent or unexecuted. Their symbol visibility is not restricted (section 13).
* Test hooks of the services (`open_bus` in brightness) are not exported.
* The consumer tests check leaks with valgrind (`tools/capi/tests/run.sh`): none in the current tree,
  and no suppressions are kept. The service-layer leaks found earlier are in `docs/research/bleu_capi.md`.
