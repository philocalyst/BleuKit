# bleu_capi

The C ABI of Bleu: stable exported C functions, opaque handles, plain C structs, and the
header generated from them. Module root `bleu::capi` (the services' C adapters are
`bleu::capi::battery_api` and `bleu::capi::brightness_api`). Depends on the services and
`bleu_json`. Conventions: `docs/CAPI.md`. Sources and decisions: `docs/research/bleu_capi.md`.

## What it is

Each service has a C file that exports its API: options, an opaque handle, `open`/`close`,
snapshots and `wait`, listeners, event readers, operations, and the JSON form. The shared
machinery (status and errors, snapshots, readers, packets, operations, `bleu_free`, the ABI
version) is in `core.c3`, `entry.c3` and `handles.c3`. The header is generated from these
sources by `tools/capi/genheader.py`; the library and header are built by `tools/capi/build.sh`.

## Public API (summary; battery shown, brightness is parallel)

* Version and errors: `bleu_abi_version`, `bleu_status_name`, `bleu_last_error`, `bleu_free`.
* Battery: `bleu_battery_open(options, &h)`, `bleu_battery_close(h)`,
  `bleu_battery_snapshot(h, &s)`, `bleu_battery_wait(h, seen, timeout_ms, &s)`,
  `bleu_battery_snapshot_state(s)`, `bleu_battery_source_at(state, i)`,
  `bleu_battery_snapshot_json(h, &text, &len)`, `bleu_battery_watch` / `_unwatch`,
  `bleu_battery_subscribe` (then `bleu_reader_next`, `bleu_battery_packet_event`),
  `bleu_battery_capability`, `bleu_battery_refresh`, `bleu_battery_backend_name`.
* Brightness: the same, plus `bleu_brightness_set_level(h, &request, &op)`,
  `bleu_brightness_set_result(op)`, `bleu_brightness_device_at`, `bleu_brightness_control_at`.
* Shared: `bleu_snapshot_{retain,release,generation,json}`, `bleu_reader_{next,take_dropped,release}`,
  `bleu_packet_release`, `bleu_operation_{wait,cancel,phase,detail,release}`.

## Not done

* Slice elements are reached through accessors; the header does not type them.
* Brightness ramps ignore `bleu_operation_cancel` (a replacing request ends them).
* Windows and macOS builds are type-checked only; their symbol lists are not restricted.
* Services other than battery and brightness have no C API yet (see CAPI.md section 14).
* Test hooks (`open_bus`) are not exported.

## Verified how

* Run on Linux x86-64, C3 0.8.5: `tools/capi/build.sh` (exports restricted to the header, `nm -D`
  checked: 48 functions). `tools/capi/tests/run.sh`: a C11 program (`-Wall -Wextra -pedantic -Werror`)
  against the shared and the static library, a C++17 program, a Python ctypes program checked against
  the JSON path, two translation units linked together, and valgrind (no capi leak; six
  service-layer leaks suppressed, see the research note). Four `@test`s in `src/abi_test.c3`.
* Type-checked on all six targets: `tools/check.sh bleu_core bleu_rt bleu_service bleu_json bleu_objc
  bleu_win bleu_dbus bleu_ddc bleu_dl bleu_battery bleu_brightness bleu_capi`.
