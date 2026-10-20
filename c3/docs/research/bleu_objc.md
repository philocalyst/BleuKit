# bleu_objc: ABI research record

Every native layout, constant, signature and sequence in `libs/bleu_objc.c3l` is
listed here with the sources it was checked against. Nothing in this library has
been run: it is compiled for `macos-aarch64` and `macos-x64` by `tools/check.sh`,
and no macOS runtime was available. A decision marked **single source** rests on
one primary or generated binding; **not verified** means no source was found in this
environment.

Source keys used below:

* **OSS-hdr**: Apple open-source headers, `raw.githubusercontent.com/apple-oss-distributions/<repo>/main/<path>`
  (objc4, xnu, IOKitUser, CF, libdispatch).
* **Block-ABI**: https://clang.llvm.org/docs/Block-ABI-Apple.html
* **objc2**: crate `objc2` 0.6.0, `src/runtime/message_receiver.rs` and `src/runtime/bool.rs` (Rust bindings; BOOL and msgSend variants).
* **objc2-foundation** 0.3.1, **objc2-app-kit** 0.3.1, **objc2-core-services** 0.3.1, **objc2-io-kit** 0.3.1:
  generated from the macOS SDK headers (`src/generated/*.rs`).
* **io-kit-sys** 0.4.1, **core-foundation-sys** 0.8.7, **mach2** 0.4.2, **block2** 0.5.1, **dispatch2** 0.3.0, **libc** 0.2.170:
  hand-written or generated Rust bindings (`src/*.rs`).
* **stdlib**: `/opt/c3/c3/lib/std` (C3 0.8.5), especially `os/darwin/objc.c3` and `gfx/private/gfx_macos.c3`.
* **swift-corelibs / swift-foundation**: `raw.githubusercontent.com/swiftlang/...`.
* **tao** 0.34.0 crate, `src/platform_impl/macos/window_delegate.rs`.

## 1. Objective-C messaging

| Decision | Source A | Source B | Status |
| --- | --- | --- | --- |
| x86_64: return structs of at most 16 bytes use plain `objc_msgSend`; larger ones use `objc_msgSend_stret`. Implemented by the stdlib `send` macro (`$RType::size > 16` on non-AARCH64). | objc4 `runtime/Messengers.subproj/objc-msg-x86_64.s` defines `_objc_msgSend_stret` (line 57, 1004). | objc2 `message_receiver.rs` lines 126-150: `size_of::<T>() <= 16` → `objc_msgSend`, else `objc_msgSend_stret`. | two sources |
| arm64: there is no `objc_msgSend_stret`; every struct return uses `objc_msgSend`. | objc4 `objc-msg-arm64.s` line 790 ("No stret specialization"). | objc2 `message_receiver.rs` lines 60-66: "`objc_msgSend_stret` is not even available in arm64". | two sources |
| `NSRange` is two `NSUInteger` (16 bytes) and so returns in registers on both architectures. | objc2-foundation `src/range.rs` lines 13-17 (`location`, `length`). | stdlib `NSUInteger` alias (`os/darwin/foundation.c3`): `ulong` on 64-bit. | two sources (stdlib is a working implementation) |
| `CGRect` is four `CGFloat` (`double` on 64-bit): 32 bytes, so `stret` on x86_64. | stdlib `os/macos/core_graphics.c3` (`CGRect`, `CGFloat = double` for ARCH_64_BIT). | stdlib `gfx_macos.c3` uses `CGPoint` returns via `send`. | two sources |

## 2. BOOL and type encodings

| Decision | Source A | Source B | Status |
| --- | --- | --- | --- |
| On arm64 macOS, `BOOL` is C `_Bool` (encoding `B`); on x86_64 macOS it is `signed char` (encoding `c`). `type_code(bool)` selects by `$feat(AARCH64)`. | objc4 `runtime/objc.h` lines 68-91: `OBJC_BOOL_IS_BOOL` honours `__OBJC_BOOL_IS_BOOL` when defined, otherwise `TARGET_OS_OSX` gives `signed char`. | objc2 `runtime/bool.rs` lines 13-37: `BOOL = bool` for `target_arch = "aarch64"`, `i8` otherwise; comment says clang always defines `__OBJC_BOOL_IS_BOOL`, cfgs "determined experimentally via cross compiling". | two sources; the arm64 value rests on objc2's experimental note, which the objc.h fallback does not contradict |
| Type codes: `v c i q C I Q f d @` for void, bool, signed, unsigned, float, object pointers. Pointers are encoded as objects (`@`) because AppKit and CoreWLAN callback arguments are `id`. | objc4 `runtime/runtime.h` `class_addMethod` (encoding string). | stdlib `gfx_macos.c3` encodings such as `"v@:@"`, `"c@:"`, `"^v"` for ivars. | two sources |
| The context ivar has encoding `^v`. | stdlib `gfx_macos.c3`: `add_ivar("gfx_window", void*, "^v")`. | objc4 `runtime.h` `class_addIvar(cls, name, size, alignment, types)`. | two sources |

## 3. Runtime and classes

| Decision | Source A | Source B | Status |
| --- | --- | --- | --- |
| `objc_allocateClassPair`, `class_addMethod`, `class_addIvar`, `class_addProtocol`, `objc_getProtocol`, `objc_registerClassPair` signatures. | objc4 `runtime/runtime.h`: lines 718-723 (class_addMethod), 764 (class_addIvar), 778 (class_addProtocol), 919 (objc_allocateClassPair), 929 (objc_registerClassPair), 1200 (objc_getProtocol). | stdlib `os/darwin/objc.c3` declares the first four with the same arguments. | two sources |
| Classes must be built between allocate and register, and not used afterwards. | objc4 `runtime.h` line 756 ("may only be called after objc_allocateClassPair and before objc_registerClassPair"). | stdlib `gfx_macos.c3` `_osx_register_classes`, which follows that order. | two sources |
| `autoreleasepool` push/pop. | stdlib `os/darwin/objc.c3` `objc_autoreleasePoolPush` / `Pop`. | not separately verified: the functions are exported by libobjc. | single source |

## 4. Blocks

| Decision | Source A | Source B | Status |
| --- | --- | --- | --- |
| Block literal layout: `isa`, `int flags`, `int reserved`, `invoke`, `descriptor`, then captured variables. | Block-ABI "High Level": `struct Block_literal_1`. | block2 `src/abi.rs` (`BlockHeader` fields, flags). | two sources |
| Flag bits: `BLOCK_HAS_COPY_DISPOSE = 1 << 25`, `BLOCK_IS_GLOBAL = 1 << 28`, `BLOCK_HAS_SIGNATURE = 1 << 30`. | Block-ABI flag enum. | block2 `src/abi.rs` lines 52, 62, 80. | two sources |
| Descriptor: `reserved` (ulong), `size` (ulong), `copy_helper(dst, src)`, `dispose_helper(src)`; helpers receive block-literal pointers. | Block-ABI descriptor and the `__block_copy_4(struct __block_literal_4 *dst, ...)` example. | block2 `src/abi.rs` lines 260, 265, 305, 310 (`copy: fn(dst, src)`, `dispose: fn(src)`). | two sources |
| `isa` is the address of `_NSConcreteStackBlock` (or `_NSConcreteGlobalBlock`). | Block-ABI "isa initialised to &_NSConcreteStackBlock". | block2 `src/ffi.rs` line 41 (`pub static _NSConcreteStackBlock`). | two sources |
| `_Block_copy` and `_Block_release` are libSystem exports. | Block-ABI (runtime functions named in the ABI). | block2 `src/ffi.rs` lines 53 and 63. | two sources |
| Signature field is not set (`BLOCK_HAS_SIGNATURE` clear). The field is optional. | Block-ABI: "The signature field is not always populated." | block2 `src/abi.rs` lines 209-297 (descriptor variants selected by `BLOCK_HAS_SIGNATURE`). | two sources; the copy, release and invoke paths in this library never read the field |

## 5. Core Foundation

| Decision | Source A | Source B | Status |
| --- | --- | --- | --- |
| `CFIndex` is `signed long`; `CFTypeID` and `CFOptionFlags` are `unsigned long` on LP64; `Boolean` is `unsigned char`. | OSS-hdr `CF/main/CFBase.h`: lines 381-388 (LP64 branch), `typedef unsigned char Boolean`. | core-foundation-sys `src/base.rs` lines 14 (`Boolean = u8`), 28 (`CFTypeID = usize`), 31 (`CFIndex = isize`). | two sources |
| `kCFNumberSInt64Type = 4`, `kCFNumberDoubleType = 13`. | OSS-hdr `CF/main/CFNumber.h` lines 51-66. | core-foundation-sys `src/number.rs` lines 25, 34. | two sources |
| `kCFStringEncodingUTF8 = 0x08000100`. | OSS-hdr `CF/main/CFString.h` line 129. | core-foundation-sys `src/string.rs` line 43. | two sources |
| `CFRunLoopSourceContext` version 0 field order: `version, info, retain, release, copyDescription, equal, hash, schedule, cancel, perform`. | OSS-hdr `CF/main/CFRunLoop.h` lines 107-118. | core-foundation-sys `src/runloop.rs` line 53. | two sources |
| `CFRunLoopRunInMode` return values (`kCFRunLoopRunHandledSource = 4`). | OSS-hdr `CF/main/CFRunLoop.h` lines 50-56. | — | single source (not used by the library) |
| Wake-up: `CFRunLoopSourceSignal` + `CFRunLoopWakeUp`. The header does not state thread safety; this is the standard wake pattern. | OSS-hdr `CFRunLoop.h` lines 88 and 145. | — | single source; documented as a usage pattern, not a guarantee |
| `CFDictionaryGetKeysAndValues` (out-arrays), `CFArrayGetValueAtIndex`, `CFDataCreate`, `CFDataGetBytePtr`, `CFStringCreateWithBytes`, `CFNumberIsFloatType`. | OSS-hdr `CFDictionary.h` line 580; `CFArray.h` lines 302, 362; `CFData.h` lines 43, 59, 62; `CFString.h` line 200; `CFNumber.h` line 112. | core-foundation-sys `src/dictionary.rs` line 84, `array.rs` line 86, `data.rs` lines 31, 41, `number.rs` line 71. | two sources |

## 6. Dispatch

| Decision | Source A | Source B | Status |
| --- | --- | --- | --- |
| `DISPATCH_QUEUE_SERIAL` is `NULL`; `dispatch_async_f(queue, context, work)`. | OSS-hdr `libdispatch/main/dispatch/queue.h` line 755 (`#define DISPATCH_QUEUE_SERIAL NULL`), line 300. | — | single source (header); the Rust `dispatch2` crate generates the same functions from it |
| `DISPATCH_TIME_NOW = 0`. | OSS-hdr `dispatch/time.h` line 78. | dispatch2 `src/time.rs` line 26. | two sources |
| `DISPATCH_SOURCE_TYPE_TIMER` is `&_dispatch_source_type_timer`. | OSS-hdr `dispatch/source.h` line 187. | — | single source; the symbol is read by address, as libdispatch exports it |
| Source created inactive; `dispatch_resume` on an inactive source activates it; a source must be activated before it is disposed; `dispatch_resume` on an active source with zero suspension count is an error. | OSS-hdr `source.h` lines 362-371 and `object.h` (dispatch_resume text). | — | single source (header) |
| `dispatch_source_set_event_handler_f` handler receives the source context set by `dispatch_set_context`. | OSS-hdr `source.h` line 439 ("the context ... passed to the event handler function is the context of the source"). | dispatch2 `src/generated/mod.rs` lines 2413-2417 (`set_event_handler_f(handler: dispatch_function_t)`, same handler type); `dispatch_set_context` at line 185. | two sources (the context rule is from the header alone) |
| `dispatch_release` on a dispatch object. | OSS-hdr `dispatch/object.h` line 283. | dispatch2 `src/generated/mod.rs` line 158. | two sources |

## 7. IOKit, IOReturn and power

| Decision | Source A | Source B | Status |
| --- | --- | --- | --- |
| `err_system(0x38)` is `0xE0000000`; `iokit_common_err(n)` and `iokit_common_msg(n)` are `0xE0000000 | n`. | OSS-hdr `xnu/iokit/IOKit/IOReturn.h` lines 69-70, 89, 91, 136. | objc2-io-kit `src/macros.rs` lines 40-43 (`err_system!(0x38) | err_sub!(0) | message`). | two sources |
| `kIOReturn*` codes used in `MachCode` (for example `kIOReturnNotPermitted` `0x2E2`, `kIOReturnNotFound` `0x2F0`, `kIOReturnTimeout` `0x2D6`, `kIOReturnBusy` `0x2D5`). | OSS-hdr `xnu/iokit/IOKit/IOReturn.h` lines 140-197. | io-kit-sys `src/ret.rs` lines 26 (`0x2c1`), 68 (`0x2d6`), 92 (`0x2e2`), 120 (`0x2f0`). | two sources |
| `KERN_*` values (`KERN_INVALID_ARGUMENT = 4`, `KERN_NO_ACCESS = 8`, `KERN_OPERATION_TIMED_OUT = 49`, `KERN_NOT_FOUND = 56`, ...). | OSS-hdr `xnu/osfmk/mach/kern_return.h` lines 72-338. | mach2 `src/kern_return.rs` lines 11, 15, 56. | two sources |
| `mach_error_string(int)` returns `char*` (static text). | libc 0.2.170 `src/unix/bsd/apple/mod.rs` line 6392. | Apple `libsyscall/mach/mach_error.h` was not retrievable (404). | single source |
| `io_object_t` is `mach_port_t`, which is `unsigned int`. | io-kit-sys `src/types.rs` line 120 (`io_object_t = mach_port_t`). | mach2 `src/port.rs` line 13 (`mach_port_t = c_uint`). | two sources |
| `kIOMainPortDefault` is a `mach_port_t` variable. | OSS-hdr `IOKitUser/IOKitLib.h` line 112. | objc2-io-kit `src/generated/mod.rs` line 8488 (`pub static kIOMainPortDefault`). | two sources |
| `IOServiceGetMatchingServices`, `IOServiceAddMatchingNotification` (`IONotificationPortRef`, notification type string, `CFDictionaryRef` consumed), `IOServiceAddInterestNotification`, `IOIteratorNext`, `IOObjectRelease`, `IOServiceClose`. | OSS-hdr `IOKitLib.h` lines 443-446, 475-481, 496-502, 392-393, 267, 644-645. | io-kit-sys `src/lib.rs` lines 136, 155, 160, and `IOServiceClose`. | two sources |
| `IOServiceInterestCallback(refcon, service, messageType, messageArgument)` and `IOServiceMatchingCallback(refcon, iterator)`. | OSS-hdr `IOKitLib.h` lines 85-103. | io-kit-sys `src/lib.rs` (`IOServiceMatchingCallback` at line 57). | two sources |
| `kIOServicePlane = "IOService"`, `kIOGeneralInterest = "IOGeneralInterest"`, `kIOFirstMatchNotification = "IOServiceFirstMatch"`, `kIOTerminatedNotification = "IOServiceTerminate"`. | OSS-hdr `IOKitUser/IOKitLib.h`/`xnu IOKitKeys.h` lines 49, 202-210. | io-kit-sys `src/keys.rs` (`kIOServicePlane`). | two sources |
| `kIORegistryIterateRecursively = 1`. | OSS-hdr `IOKitLib.h` lines 1011-1015. | — | single source |
| `IORegistryEntryCreateCFProperties` and `IORegistryEntrySearchCFProperty` return owned CF containers. | OSS-hdr `IOKitLib.h` line 1202 ("release with CFRelease"). | — | single source |
| Power-source functions: `IOPSCopyPowerSourcesInfo`, `IOPSCopyPowerSourcesList`, `IOPSGetPowerSourceDescription` (get rule), `IOPSNotificationCreateRunLoopSource`, `IOPSCopyExternalPowerAdapterDetails`. | OSS-hdr `IOKitUser/ps.subproj/IOPowerSources.h` lines 273, 287, 305, 342, 375. | io-kit-sys `src/ps/power_sources.rs` lines 43, 47, 55 (and the list/description calls). | two sources |
| Power-source keys: `Power Source State`, `Current Capacity`, `Max Capacity`, `Is Charging`, `Is Present`, `Name`, `Type`, `Time to Empty`, `Time to Full Charge` (minutes, -1 while calculating); values `AC Power`, `Battery Power`, `Off Line`. | OSS-hdr `ps.subproj/IOPSKeys.h` (e.g. lines 311, 329, 343, 389, 404, 417, 446, 497, 511, 740, 756-768). | io-kit-sys `src/ps/keys.rs` lines 50, 58. | two sources |
| `IOPMAssertionCreateWithName(type, level, name, &id)`, `IOPMAssertionRelease(id)`, `IOPMAssertionID` is `uint32_t`, `kIOPMAssertionLevelOn = 255`, `kIOPMAssertPreventUserIdleSystemSleep = "PreventUserIdleSystemSleep"`. | OSS-hdr `IOKitUser/pwr_mgt.subproj/IOPMLib.h` lines 392, 433, 662, 776-782, 292, 1004. | none in the fetched crates. | single source |
| `IORegisterForSystemPower(refcon, &port, callback, &notifier)` returns the root `io_connect_t`; IOKit allocates the notification port (the port is released by the caller). `IODeregisterForSystemPower(&notifier)`, `IOAllowPowerChange(root, notificationID)`. | OSS-hdr `IOPMLib.h` lines 179-208. | none in the fetched crates. | single source |
| Sleep messages: `kIOMessageCanSystemSleep 0x270`, `kIOMessageSystemWillSleep 0x280`, `kIOMessageSystemWillNotSleep 0x290`, `kIOMessageSystemWillPowerOff 0x250`, `kIOMessageSystemHasPoweredOn 0x300`, `kIOMessageSystemWillPowerOn 0x320`, `kIOMessageSystemWillRestart 0x310`. | OSS-hdr `xnu/iokit/IOKit/IOMessage.h` lines 143-181 (and 0x250 at 109). | objc2-io-kit `src/generated/mod.rs` lines 8033-8047. | two sources |
| Acknowledge `kIOMessageCanSystemSleep` and `kIOMessageSystemWillSleep` with `IOAllowPowerChange`; never acknowledge `WillPowerOn`/`HasPoweredOn`. Sleep is not vetoed by `IOAllowPowerChange`; a missing acknowledgement stalls sleep for 30 s. | OSS-hdr `IOPMLib.h` lines 130-160. | — | single source (header) |

## 8. Foundation, errors and notifications

| Decision | Source A | Source B | Status |
| --- | --- | --- | --- |
| `NSUTF8StringEncoding = 4`. | objc2-foundation `src/generated/NSString.rs` line 58. | — | single source (generated from the SDK) |
| `NSCocoaErrorDomain`, `NSPOSIXErrorDomain`, `NSOSStatusErrorDomain` strings. | swift-corelibs-foundation `Sources/Foundation/NSError.swift` lines 29, 32, 33. | objc2-foundation `src/generated/NSError.rs` lines 16, 22, 28. | two sources |
| CocoaError codes: `NSFileNoSuchFileError 4`, `NSFileLockingError 255`, `NSFileReadNoPermissionError 257`, `NSFileReadNoSuchFileError 260`, `NSFileWriteNoPermissionError 513`, `NSUserCancelledError 3072`, `NSFeatureUnsupportedError 3328`. | objc2-foundation `src/generated/FoundationErrors.rs` lines 8-56. | swift-corelibs `FoundationErrors.swift` lines 15-101 gives the names (values are in swift-foundation, not retrieved). | single source for the values |
| errno values: `EPERM 1`, `ENOENT 2`, `ENOMEM 12`, `EACCES 13`, `EBUSY 16`, `EINVAL 22`, `ENOTSUP 45`, `ETIMEDOUT 60`, `ECANCELED 89`. | OSS-hdr `xnu/bsd/sys/errno.h` lines 90-233. | libc `src/unix/bsd/apple/mod.rs` lines 3659, 3674, 3703 (`ENOTSUP`, `ETIMEDOUT`, `ECANCELED`). | two sources |
| `errAEEventNotPermitted = -1743` (AppleEvents refused, Automation/TCC). | objc2-core-services `src/generated/AE/AppleEvents.rs` line 131. | — | single source |
| `NSAppleScript initWithSource:` / `executeAndReturnError:`; keys `NSAppleScriptErrorMessage`, `NSAppleScriptErrorNumber`; `stringValue` on the descriptor. | objc2-foundation `src/generated/NSAppleScript.rs` (lines 11, 17, 71-102), `NSAppleEventDescriptor.rs` line 282. | — | single source |
| Observer selectors: `addObserverForName:object:queue:usingBlock:`, `addObserver:selector:name:object:`, `removeObserver:`. | objc2-foundation `src/generated/NSNotification.rs` lines 124, 157. | — | single source |
| NSWorkspace notifications: `NSWorkspaceWillSleepNotification`, `NSWorkspaceDidWakeNotification`, `NSWorkspaceScreensDidSleepNotification`, `NSWorkspaceSessionDidResignActiveNotification`. | objc2-app-kit `src/generated/NSWorkspace.rs` lines 694, 699, 704, 719. | — | single source (generated from the SDK) |
| `AppleInterfaceThemeChangedNotification` on `NSDistributedNotificationCenter`. | tao 0.34.0 `src/platform_impl/macos/window_delegate.rs` lines 300-308. | — | single source (a shipping application) |
| `com.apple.screenIsLocked`. | **not verified**: no source in this environment. Kept as `DISTRIBUTED_SCREEN_LOCKED` and flagged in code. | — | not verified |
| Foundation `NSRange`/`NSNotFound`. | objc2-foundation `src/range.rs`. | — | single source |

## 9. Reference implementations consulted

* Stdlib `gfx_macos.c3`: a C3 `NSWindow` delegate and `NSView` class built with
  `add_ivar`/`add_method`/`register_new_subclass`. It is the model for `ClassBuilder`.
* Stdlib `os/darwin/objc.c3`: the `send` macro (stret rule) and the ObjC runtime externs.
* objc2 crates above: the BOOL and msgSend rules were cross-checked against objc4 sources.

## 10. Known gaps

* **CoreWLAN error codes (`kCWErr*`)** are not mapped: no header or binding for them
  was available in this environment, and inventing values would be wrong. The CoreWLAN
  backend must add them, citing its own source.
* **TCC denial** is mapped only where it surfaces as `NSOSStatusErrorDomain -1743` or a
  POSIX/Cocoa permission code. Other TCC refusals arrive as backend-specific results.
* **`com.apple.screenIsLocked`** is unverified (see the table).
* Apple's developer documentation site was reached but returned script-rendered pages
  with no extractable text, so it is not cited.
