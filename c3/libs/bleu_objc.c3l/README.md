# bleu_objc

The macOS (Darwin) infrastructure every macOS backend builds on: Objective-C
objects and messages, blocks, classes implemented in C3, CoreFoundation,
run loops and GCD, IOKit registry and power, and Mach/IOKit return codes.

Most files are `@feat(DARWIN)`, so on Linux and Windows they contribute no code.
Four modules are pure logic and compile on every target, so their unit tests run
on Linux: `bleu::objc::codes` (Mach, IOKit and NSError code tables),
`bleu::objc::encoding` (Objective-C type encodings), `bleu::objc::block_layout`
(block ABI structs) and `bleu::iokit_power` (power-source state and IOKit power
messages).

**Status: compiled and unit-tested on Linux; the Darwin code is compiled only.**
Nothing Darwin-specific has been run; there is no macOS in this environment. The
review of this library, and every change made from it, is in
`docs/reviews/bleu_objc.md`.

## Public API

Module roots `bleu::objc`, `bleu::cf`, `bleu::iokit`, `bleu::mach`, plus
`bleu::objc::foundation`, `bleu::objc::notify`, `bleu::objc::applescript`,
`bleu::objc::codes`, `bleu::objc::encoding`, `bleu::cf::runloop`,
`bleu::cf::dispatch`, `bleu::iokit::power`.

* `Obj`: owned object reference. `adopt` (take a +1), `borrow` (retain a +0), `copy`, `autorelease`, `close`, `is_kind_of`, `responds_to`, and typed sends `send_id/bool/long/ulong/double/void/rect/range`.
* `@autorelease_pool()` and `@objc_entry()` (pool + C3 temp scope for foreign callbacks; stand-in for `bleu::rt::foreign`).
* `Block`, `void_block`, `id_block`, `bool_error_block`, `id_error_block`, `int_block`: heap blocks for the Block ABI, released with `release`.
* `ClassBuilder`: `begin_class`, `add_context_ivar`, `method`, `method_void_object`, `adopt_protocol`, `finish`; `encoding::signature($Ret, samples...)` builds encodings at compile time (SEL is `:`); `set_context`/`context_of`.
* `foundation`: `from_string`/`to_string` (class-checked), NSNumber, NSData (class-checked `data_bytes`), `count_of`, `array_at`, `dictionary_keys/value`, `raise_ns_error` (NSError to excuse).
* `codes`: `MachCode`, `classify_mach(int)`, `classify_ns(domain, code)`.
* `notify`: `observe` (block), `observe_selector`, `CenterKind` (default, distributed, workspace).
* `applescript::run_script(source, allocator)`: the result is allocated from `allocator`; `tmem` is safe inside the caller's pool.
* `cf::Ref` (`adopt`, `borrow`, `close`), `string_value`, `number_long` (refuses a fraction or overflow), `data_bytes`, `property_to_plain` into `Plain`.
* `cf::runloop::RunLoopThread` (`start`, `wake`, `stop_and_join`; restartable); `cf::dispatch`: `SerialQueue`, `Timer`.
* `iokit`: `Service`, `services_matching`, `ServiceIterator`, `NotificationPort`, `on_matching`, `on_service_change`.
* `iokit::power`: `read_power_sources` (an error when IOPowerSources returns NULL), `external_adapter_details`, `power_source_change_source`, `attach_source`, `prevent_idle_sleep`, `register_system_power`, `PowerSourceState`, `PowerEvent`.
* `mach`: `raise_code`, `check` (the table is in `codes`).

## Not done

* CoreWLAN error codes (`kCWErr*`) are not mapped: no header or binding for them was available here. The CoreWLAN backend must add them with its own citation.
* TCC refusals are mapped only where they surface as `errAEEventNotPermitted` (-1743) or POSIX/Cocoa permission codes.
* `com.apple.screenIsLocked` is an unverified name (see the research record).
* The block `signature` field is not emitted, and `global` block literals are not used (handlers carry a context).
* Sleep is never vetoed. `IOCancelPowerChange` is not exposed.
* The power time-remaining estimate and IOPM assertion timeouts are not bound.
* `bleu::rt::foreign` does not exist yet; `@objc_entry` uses `@pool_init` until it does.
* Dispatch work functions that use Objective-C must wrap their body in `@objc_entry`; the library does not do it for them.
* Charge of a power source with no `Max Capacity` reads as 0%, not as unknown (review R-14).
* The power-source name cache is not kept: each lookup creates its key string (review R-13).

## Verification

* `tools/check.sh bleu_core bleu_objc` type-checks on all six targets (the Darwin code
  is checked for `macos-aarch64` and `macos-x64`).
* Unit tests (`src/*_test.c3`, 15 tests on the four pure modules) were run on Linux:
  `c3c --libdir "$(tools/libdir.sh)" --lib bleu_core --lib bleu_objc compile-test <files>`
  from a private directory. All 15 pass; a deliberate change to one table entry makes
  its test fail.
* Nothing Darwin-specific was executed. The `SEL` encoding test (`encoding_test.c3`,
  `selector_code`) is `@feat(DARWIN)` and was type-checked for macOS only.
* `c3fmt --check` is clean for every file in `src/`.
