# Bleu C3 style guide (compiler: C3 0.8.5_1)

Read `ARCHITECTURE.md` first. This file is the law for code in `libs/` and
`apps/`. It records what was **verified against the real 0.8.5 compiler**;
older C3 tutorials and your own memory of C3 are frequently wrong for this
version. When in doubt, look in `/opt/c3/c3/lib/std` (the shipped standard
library) — it is the authority — then try it with `c3c`.

## Toolchain

```
c3c                      # /usr/local/bin/c3c, standard library in /opt/c3/c3/lib/std
c3fmt                    # formatter (run on your files before finishing)
tools/check.sh <libs>    # type-check named libs for ALL six targets (no linking)
```

* C3 type-checks **every** function of a library, used or not. A clean
  `tools/check.sh` on a lib means the whole lib compiles on that target.
* Always check **all six targets** before you say you are done:
  `linux-x64 linux-aarch64 macos-aarch64 macos-x64 windows-x64 windows-aarch64`.
  Pass the library and every Bleu library it depends on:
  `tools/check.sh bleu_core bleu_rt bleu_mylib`.
* Quick single-library iteration on Linux:
  `c3c --libdir libs --lib bleu_core --lib bleu_mylib compile-run scratch.c3`
  (put scratch files in your own scratch directory, never inside `libs/`).
* Unit tests live in `src/*_test.c3` as `fn void name() @test { ... }` and run
  with `c3c --libdir libs --lib bleu_core --lib X compile-test src/*_test.c3 --sources …`;
  keep them to pure logic (parsers, encoders, state machines). They are a
  bonus, not a requirement.
* Libraries are directories `libs/<provides>.c3l/` containing `manifest.json`
  and `src/`. **The directory name must equal `provides`.** The manifest lists
  all six targets (copy `libs/bleu_core.c3l/manifest.json`) and any
  `"dependencies"`. Module names are lowercase, `[a-z0-9_]`, at most 31 chars
  per component.

## Language facts that differ from what you expect (0.8.5)

| Topic | Do this | Not this |
| --- | --- | --- |
| Error values | `excuse NAME;` to define, `return NAME~;` to raise, `x()!` rethrow, `x()!!` assert, `if (catch e = x())`, `if (try v = x())`, `x() ?? fallback` | `fault`/`faultdef`, `NAME?` |
| Distinct numeric types | `typedef Level = float;` (create with `(Level)1.0f`, strip with `(float)x`) | `distinct` (removed) |
| C-like enums with gaps / OS constants | `constset Name : uint { A = 1, B = 4 }` (values are loose integers of the base type) | `enum` with explicit values, `cenum` |
| Plain enums | `enum Kind : char { A, B, C }` (ordinals 0..n, no gaps) | |
| Platform gating | `module a::b @feat(LINUX);` and `fn ... @feat(WIN32)`; in bodies `$if env::WIN32:` / `$feat(MACOS)`. Flags: `LINUX DARWIN MACOS WIN32 POSIX BSD X86_64 AARCH64` | `@if(env::LINUX)` (deprecated) |
| Size types | `sz` (signed, what `.len` returns) and `usz`; mixing needs a cast | assuming `usz` is what `len` gives |
| Allocators | `Allocator` is an interface. `alloc::new(allocator, Type)`, `alloc::new_array(allocator, Type, n)`, `alloc::free(allocator, ptr)`, `"s".copy(allocator)`, `mem` = heap, `tmem` = temp. Allocation failure aborts; there is no `!` to add | `malloc`/`free` directly |
| Temp memory | `@pool() { ... };` scopes `tmem`/`tformat`/`tcopy`. Never let a temp pointer escape the pool | |
| Generics | `module bleu::observe <State>;` then `Observable{State}`, `observe::begin{State}(a)` | `<>` at use site |
| Methods | `fn T Type.name(&self, ...)` (pointer self) or `(self, ...)` (value self). A method can't share a name with a field. `@private`/`@local` are ignored on methods — make helpers free functions | |
| Interfaces | `interface Backend { fn String name(); ... }`; implement: `struct Impl (Backend) {...}` and `fn String Impl.name(&self) @dynamic`. Use as `Backend b = &impl;` | |
| Strings | `String` is `char[]` (UTF-8, not NUL-terminated); `ZString` is a C string. `string::tformat`, `string::format(alloc, ...)`, `DString` for building (`DString s; s.init(alloc); s.appendf(...); s.str_view()`) | `char*` for text |
| Extern C | `extern fn int poll(Pollfd*, uint, int) @cname("poll");` `extern` globals too. Link with `module m @link("libname");` (macOS: `@link("Foo.framework")`) | |
| Casting | explicit `(Type)x`. No implicit narrowing, no implicit signed/unsigned mixing | |
| Loops | `foreach (i, &item : slice)`, `for`, `while`, `do..while`; `defer` for cleanup; `nextcase` instead of fallthrough | |
| Contracts | `<* ... @param x : "..." @require cond : "..." @return? error::NOT_FOUND : "..." *>` doc comments are checked; `@require` is enforced in safe builds | |
| Names | types `PascalCase`; functions/variables/members `snake_case`; constants and enum/constset/excuse values `UPPER_SNAKE`; modules `lower_snake` | |

### Gotchas found the hard way

* A bare `NOT_FOUND`, `TIMEOUT`, `NOT_IMPLEMENTED`, `CAPACITY_EXCEEDED`,
  `NO_MORE_ELEMENT`, `TYPE_MISMATCH` is the **standard library's built-in
  excuse**, global and silently preferred. Bleu reuses `NOT_FOUND` and
  `TIMEOUT` on purpose and never redefines them. Excuses defined in another
  module must be written `module::NAME` (also inside `@return?` contracts).
* Sibling modules are **not** implicitly imported. Write
  `import bleu::error, bleu::unit;` explicitly in every file that uses them.
* `std::math`, `std::time`, `std::thread`, `std::atomic`, `std::io`,
  `std::collections::list` etc. must be imported explicitly.
* `Atomic{int}.add/sub` return the previous value (fetch-and-op).
* `Mutex.lock()` returns `void?`; write `m.lock()!!;` (a failing lock is a bug).
* `Duration` is microseconds, `NanoDuration` nanoseconds (both `typedef`s: compare
  with `time::DURATION_ZERO`, not `0`). `time::now()` is **wall-clock** `Time`;
  `std::time::clock::now()` is the **monotonic** `Clock`. Never time out against
  wall-clock: use `bleu::deadline` (`deadline::after(d)`, `Deadline.wait(cond, mutex)`).
* To discard an optional deliberately: `if (catch f()) {}` (with a comment saying why).
* Optional-returning functions are `T? name()`. Optionals cannot be stored in
  structs or globals — store a `bool` + the value, or the excuse in a `fault`.
* Faults are keywords-adjacent: you cannot name a method `fault`.
* If you find a new gotcha, **append it to `docs/C3_GOTCHAS.md`** (one line:
  symptom → fix) so later agents do not repeat it.

## Code quality bar

Write the code you would be proud to ship and to have read by the author of
the language.

* **Types carry meaning.** A level is a `Level`, a power a `MilliWatt`, an
  endpoint id a `String` id owned by the snapshot — not `int`/`char*`.
  `enum`s for every closed set, `constset` for OS-defined numbers, `bitstruct`
  for register/flag layouts, never magic numbers (name every constant, cite
  its source).
* **Errors:** every fallible function returns `T?`. Raise with
  `error::raise(KIND, DOMAIN, native_code, "what failed: %s", arg)~`. Never
  swallow an error; if you must ignore one, say why in a comment. Never use
  `!!` on I/O, only on invariants and allocation-free infallible calls.
  Translate foreign failures into the Bleu excuse vocabulary at the backend
  boundary.
* **Resources:** pair every acquire with `defer` release on the next line.
  Handles are wrapped in a small struct with a `close()`; no raw fd/HANDLE/
  CFTypeRef/COM pointer floats around unowned.
* **Control flow:** early returns for errors, `switch` over enums without
  `default` (so new values force a decision), `foreach` over slices, no deep
  nesting (> 3 levels means split the function), functions short enough to read
  in one screen. Use `if (try …)`/`if (catch …)`, `??`, `!` — not manual
  status codes.
* **Comments:** `<* *>` doc comments on every public type and function
  (what, units, ownership, threading, errors). Inline `//` only for *why*.
  Where code mirrors an external source, cite it: `// Source: <project> <path>:<lines> (<url>)`.
* **Layout:** one concept per file, ~100–400 lines; `model` / `service` /
  `backend` / platform files as in `ARCHITECTURE.md`.
* **No dead code, no TODO placeholders that pretend to work.** If something
  is not implemented, the `Cap` says `UNSUPPORTED_*` and the function raises
  `UNSUPPORTED` honestly; list it in the lib's `README.md` under "Not done".
* Run `c3fmt` over your files (`c3fmt --help`), keep tabs for indentation as
  the standard library does.

## Citing and validating sources

Native APIs are easy to get subtly wrong (struct layout, calling convention,
error semantics). For every external API you bind:

1. Fetch the primary source (vendor header, Microsoft Learn page, Apple
   documentation/header, freedesktop spec, kernel `Documentation/`, protocol
   XML). Reachable hosts: `raw.githubusercontent.com`, `static.crates.io`
   (crate tarballs: `https://static.crates.io/crates/<name>/<name>-<ver>.crate`),
   `docs.rs`, `learn.microsoft.com`, `developer.apple.com`, `dbus.freedesktop.org`,
   `wayland.app`, `gitlab.freedesktop.org` (raw files), `kernel.org`,
   `docs.kernel.org`. `github.com` HTML/tarballs and `api.github.com` are
   blocked.
2. **Double-validate:** confirm each fact (a struct layout, constant value,
   function signature, protocol sequence) against **two independent
   sources** — e.g. the vendor header *and* a working open-source
   implementation (a Rust crate, Lunar/MonitorControl/m1ddc, NetworkManager,
   Chromium, etc.). Where only one source exists, say so.
3. Record every binding decision in `docs/research/<lib>.md`: the claim, the
   URL(s) and line numbers, and what you cross-checked. Put a short
   `// Source:` comment next to the code too.
4. Reference implementations to mine are in
   `<scratchpad>/rust_prev/desktop-systems/` (a previous Rust attempt:
   `forks/` and `research/`) — read it for leads, but verify before trusting;
   it was never run on real hardware.
