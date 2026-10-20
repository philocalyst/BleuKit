# bleu_capi: research and decisions

Scope: the C ABI of the SDK (`libs/bleu_capi.c3l`), the header generator
(`tools/capi/genheader.py`), the build (`tools/capi/build.sh`) and the consumer tests
(`tools/capi/tests/`). Two exemplar services: battery and brightness. Conventions:
`docs/CAPI.md`. Compiler: C3 0.8.5_1 (`/opt/c3/c3`), gcc 13.3, g++ 13.3, Python 3.13,
valgrind 3.22, GNU ld (binutils).

## 1. What a C consumer needs

1. Open a service, read its state, wait for a change, and close it: from any thread.
2. Listen for changes without polling; events as a queue; requests that finish later, with
   a result and a cancel.
3. Errors as a number plus a message that says which OS call failed.
4. A header that compiles as C11 and C++, and a JSON form that needs no binding.
5. A library that exports only its own API, and an ABI that can grow without breaking callers.

## 2. Native route: how the C3 compiler presents the API

Verified by experiment (scratch programs under the session scratchpad; all results reproduced
by `tools/capi/build.sh` and `tools/capi/tests/run.sh`).

* **Export attributes.** `@export("c_name")` works on functions, structs, enums (`: int` or
  `: char`), and typedefs written `typedef N @export("c_name") = T;`. It is refused on `alias`.
  Sources: `/opt/c3/c3/releasenotes.md` lines 2113 ("Require `@export` functions to have
  `@export` types") and 2492 ("`@export` attribute to determine what is visible in precompiled
  libraries"); compiler messages confirmed the syntax.
* **Header contents.** `c3c --header-output <dir> dynamic-lib` writes `<lib>.h`. It describes
  every type that an exported function reaches, transitively, under mangled names
  (`bleu_battery__State`, `std_collections_maybe__Maybe$uint$`, `bleu_observe__Snapshot$...`).
  `String` and slices are `c3slice_t {void *ptr; size_t len;}` with no element type. A fault
  is `c3fault_t`, a pointer. Enums without `@export` are emitted as global variables
  (`bleu_error__Domain_NONE = 0;`), which would be defined in every translation unit.
  `genheader.py` does these rewrites; its output is checked to contain none of them.
* **Symbol visibility.** A C3 dynamic library exports every function, including C3's own method
  symbols (`bleu_battery__Battery.close`, `exp.internal_helper`). `--linker=custom <wrapper>`
  receives raw `ld` arguments, so the wrapper adds `--version-script=<exports.map>`. With
  `global:` the header's functions and `local: *`, `nm -D --defined-only` lists exactly those
  48 functions (checked by `build.sh` on every build). A `bleu_*` glob does not work: it still
  exports the methods, which start with `bleu_`.
* **Foreign threads.** Every entry point must work on threads C3 did not start. `bleu::rt::foreign`
  creates a temporary allocator with `@pool_init`, whose contract is `!top_temp`
  (`/opt/c3/c3/lib/std/core/allocators.c3:69`): it traps on a thread that already has one, and
  when nested. Both happen here: the service workers have a temporary allocator (their publish
  code uses it), and a listener runs inside an exported `watch` call and calls an accessor. So
  `capi::@capi_scope` (`entry.c3`) enters the pool only for the outermost call on a thread
  that has none. Reproduced: the C smoke test aborted with "This should never be called when
  temp already exists" before the fix.
* **Enums in C.** Members become `#define`s. Enumerator values are the C3 ordinals; the status
  numbers are the `bleu::error::Status` ordinals (`status_numbers_follow_the_error_vocabulary`).
* **Struct layout.** The header's structs are the C3 structs (same member order and types);
  the C tests write and read real values through them, and the Python test reads the same
  values through ctypes structures written from the header: charge 0.5, cycles 212, the
  `on_mains` flag, slices of `BAT0`/`ACME`, and the JSON agrees member by member.

## 3. Decisions

* **Handles are type-erased.** One C type per kind (`bleu_snapshot_t`, `bleu_reader_t`,
  `bleu_packet_t`, `bleu_operation_t`) holds a native pointer and a table of functions written once per
  service. The alternative, one generic instance per service, would multiply the exported names.
* **Typed accessors** return borrowed pointers (`bleu_battery_snapshot_state`), checked against the
  service tag. They are the only way to reach a slice's elements, because the header cannot type them.
* **Options are versioned** (`struct_size` first, zero = default), copied member by member. A
  struct from an older caller is read up to its size; a newer one is read up to the library's.
* **Status is `int32_t`**, the core's numbers. Out-parameters are set to NULL on failure.
* **Watch callbacks** run on the worker thread while the observable's `delivery` lock is held
  (`observe.c3`: listeners run one at a time). A call back into the same handle from a callback
  returns `INVALID_STATE` (a thread mark, `callback_owner`): the library refuses it up front rather
  than relying on the core's nesting rules. A callback receives a view that is only valid
  during the call; `bleu_snapshot_retain` makes it owned.
* **Close refuses** while readers are open (`INVALID_STATE`), because a reader points into the
  service's stream.
* **JSON** uses `bleu::json::to_json` and the same rules as the daemons: no per-type code.

## 4. Double validation

| Claim | Source 1 | Source 2 |
| --- | --- | --- |
| The ABI status numbers equal `error::Status` ordinals | C3 `@test` `status_numbers_follow_the_error_vocabulary` | C test: `bleu_status_name(BLEU_STATUS_NOT_FOUND)` is `"NOT_FOUND"`, and the ctypes test compares names |
| Struct offsets and sizes in the header match the compiled C3 structs | gcc compiles the header (`-Werror`) and reads the fields | ctypes computes offsets with CPython's own rules; the values read agree |
| Only the header's functions are exported | `nm -D --defined-only` on the built `.so`, diffed against `exports.txt` by `build.sh` | the scratch experiment: the same program without the script exports its own `internal_helper`; with it, the helper is local |
| No C3 fault type or slice type leaks into the header | `genheader.py` refuses `c3fault_t`, `c3any_t`, `c3typeid_t`, `c3slice_t`, `$`, `std_`, `__` in output | `grep` over `include/bleu/*.h` (done during the build) |
| Callbacks may run synchronously inside `watch` | C test `battery_watch_from_another_thread` and the C++ test count the immediate call | the C3 source: `Observable.watch` calls the listener when a state exists (`observe.c3`) |
| `Operation.cancel()` does not end a brightness ramp (single-source: the C test observed it) | the brightness engine: `engine.c3`, `cancel_ramps` runs only when a new request arrives; `cancel_requested` is never polled | the test replaced the ramp instead, and the result is CANCELLED |

## 5. Results (this session)

* `tools/capi/build.sh`: shared library and static library built; 48 exported functions;
  `nm` check passed; headers regenerated (deterministic: two runs give identical files).
* `tools/capi/tests/run.sh`: PASS. C11 shared (`capi_smoke`: all checks), C11 static, two
  translation units ("two translation units: ok"), C++17 (`capi_cxx`), Python ctypes
  (`capi_ctypes`), valgrind (0 capi leaks).
* `tools/check.sh bleu_core bleu_rt bleu_service bleu_json bleu_objc bleu_win bleu_dbus bleu_ddc bleu_dl
  bleu_battery bleu_brightness bleu_capi`: all six targets ok. (The list in the brief needs the
  transitive dependencies `bleu_objc bleu_win bleu_dbus bleu_ddc bleu_dl`; without them `c3c` stops with
  "Required library ... could not be found".)
* `c3fmt -i` on every C3 file of the library.

## 6. Leaks found in the service layer (not in bleu_capi)

Valgrind (definitely lost, 6 blocks, 3600 bytes) on the smoke test. Every block was allocated
inside `bleu::service::Hub.start` (`hub.c3:128`, `hub.c3:130`): the observable's watcher list
(`observe.c3:120`), the mailbox (`bleu_rt` `mailbox.c3:60`) and the worker's arrays. Reproduced
with a C3 program that only opens and closes `bleu::battery` (no capi): 464 bytes in 3 blocks.
`docs/C3_GOTCHAS.md` already records the cause (`Observable.close` no longer frees its lists;
`destroy` does, and the Hub must call it). These six are listed in `tools/capi/tests/valgrind.supp`
with a pattern that matches only frames through `Hub.start`. Remove the entry when the Hub calls
`destroy`; a capi-owned leak would still be reported.

## 7. Issues for the lead (other libraries, not changed here)

* `bleu_brightness`: the ramp ignores `Operation.cancel()` (see section 4). The C ABI passes the
  request through; the service should honour the flag or document that only replacement cancels.
* `bleu_brightness` `Brightness.unwatch` was `void` over `Observable.unwatch`, which is `void?`
  (fixed in the working tree by its owner while this work ran).
* `bleu_rt` `@foreign_entry`: it asserts on a thread that already has a temporary allocator, and when
  nested. Every thread the service workers run has one. Suggest `if (no temp) @pool_init(...)` inside
  the macro, so that other callers do not need the check that `capi::@capi_scope` makes.
* While this ran, `bleu_battery/src` had stray `</content>` lines (`publish.c3`, `common_state.c3`)
  that stopped the compile; the early builds used a copy with them removed. They were gone from the
  working tree by the final build.

## 8. Risks and cut lines

* Slice elements: typed only through accessors. A service with many nested slices needs one
  accessor per slice. The alternative (a generator table from C3 field types) is more code than
  it saves.
* Symbol restriction: implemented for Linux ELF. macOS needs `-exported_symbols_list` and Windows
  a `.def` file (`--windef`); neither is written, so those builds export all of C3's symbols.
* The header is generated by reading c3c's output. A C3 compiler change in how it names mangled
  types would break the rename rules; `genheader.py` fails (never guesses) on any shape it does not
  recognise, and the build fails with it.
* Concurrency rule: a handle must not be closed while another thread is inside a call on it. This
  is the usual C rule; the library does not enforce it with reference counts on handles.
* Only battery and brightness have a C API. The other services follow `docs/CAPI.md` section 14.
