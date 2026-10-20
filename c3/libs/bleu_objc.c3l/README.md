# bleu_objc

The macOS (Darwin) infrastructure every macOS backend builds on: Objective-C
objects and messages, blocks, classes implemented in C3, CoreFoundation,
run loops and GCD, IOKit registry and power, and Mach/IOKit return codes.

Every source file is `@feat(DARWIN)`, so on Linux and Windows the library
contributes no code and still type-checks.

**Status: compiled only.** Nothing here has been run; there is no macOS in this
environment. `tools/check.sh bleu_core bleu_objc` is clean on all six targets, and
the macOS targets exercise every line against the real C3 Darwin bindings. The ABI
decisions and their sources are in `docs/research/bleu_objc.md`.

## Public API

Module roots `bleu::objc`, `bleu::cf`, `bleu::iokit`, `bleu::mach`, plus
`bleu::objc::foundation`, `bleu::objc::notify`, `bleu::objc::applescript`,
`bleu::cf::runloop`, `bleu::cf::dispatch`, `bleu::iokit::power`.

* `Obj`: owned object reference. `adopt` (take a +1), `borrow` (retain a +0), `copy`, `autorelease`, `close`, `is_kind_of`, `responds_to`, and typed sends `send_id/bool/long/ulong/double/void/rect/range`.
* `@autorelease_pool()` and `@objc_entry()` (pool + C3 temp scope for foreign callbacks; stand-in for `bleu::rt::foreign`).
* `Block`, `void_block`, `id_block`, `bool_error_block`, `id_error_block`, `int_block`: heap blocks for the Block ABI, released with `release`.
* `ClassBuilder`: `begin_class`, `add_context_ivar`, `method`, `method_void_object`, `adopt_protocol`, `finish`; `signature($Ret, samples...)` builds encodings at compile time; `set_context`/`context_of`.
* `foundation`: `from_string`/`to_string`, NSNumber, NSData, `count_of`, `array_at`, `dictionary_keys/value`, `raise_ns_error` (NSError to excuse).
* `notify`: `observe` (block), `observe_selector`, `CenterKind` (default, distributed, workspace).
* `applescript::run_script(source, allocator)`.
* `cf::Ref` (`adopt`, `borrow`, `close`), `string_value`, `number_long`, `data_bytes`, `property_to_plain` into `Plain`.
* `cf::runloop::RunLoopThread` (`start`, `wake`, `stop_and_join`); `cf::dispatch`: `SerialQueue`, `Timer`.
* `iokit`: `Service`, `services_matching`, `ServiceIterator`, `NotificationPort`, `on_matching`, `on_service_change`.
* `iokit::power`: `read_power_sources`, `external_adapter_details`, `power_source_change_source`, `attach_source`, `prevent_idle_sleep`, `register_system_power`, `PowerEvent`.
* `mach`: `MachCode` constset, `classify`, `raise_code`, `check`.

## Not done

* CoreWLAN error codes (`kCWErr*`) are not mapped: no header or binding for them was available here. The CoreWLAN backend must add them with its own citation.
* TCC refusals are mapped only where they surface as `errAEEventNotPermitted` (-1743) or POSIX/Cocoa permission codes.
* `com.apple.screenIsLocked` is an unverified name (see the research record).
* The block `signature` field is not emitted, and `global` block literals are not used (handlers carry a context).
* Sleep is never vetoed. `IOCancelPowerChange` is not exposed.
* The power time-remaining estimate and IOPM assertion timeouts are not bound.
* `bleu::rt::foreign` does not exist yet; `@objc_entry` uses `@pool_init` until it does.
* Dispatch work functions that use Objective-C must wrap their body in `@objc_entry`; the library does not do it for them.

## Verification

* Compiled for `macos-aarch64` and `macos-x64` (all DARWIN code), and for the four
  other targets (where it is empty). Run with `tools/check.sh bleu_core bleu_objc`.
* A temporary type error planted in a DARWIN file failed only the macOS targets,
  which confirms the gating.
* Nothing was executed. No Linux test applies, because every module is Darwin-only.
* `c3fmt` is clean for every file in `src/`. Note: `libs/bleu_core.c3l/src/error.c3`
  is not `c3fmt`-clean (formatting only; not changed here).
