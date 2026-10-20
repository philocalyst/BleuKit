# C3 0.8.5 gotchas (append one line per discovery: symptom → fix)

* `error: Faults from other modules must be prefixed` → write `module::NAME`, also in `@return?` contracts.
* `Did you mean the macro 'std::math::round'` → the std module is not imported; `import std::math;`.
* `'long' cannot implicitly be narrowed to 'usz'` → `.len` is `sz` (signed); use `sz` for lengths/indices or cast.
* `already has a field with the same name` → a method cannot be named like a field of the same struct.
* `Expected a function name here` for `fn fault X.fault()` → `fault` is a keyword, pick another name.
* `'@private' modifiers are ignored for method declarations` → make the helper a free function.
* Bare `NOT_FOUND`/`TIMEOUT` silently bind to the built-in excuses of the standard library.
* `Implicitly casting 'int' to 'Duration'` → `Duration`/`NanoDuration`/`Level` are typedefs; compare with `time::DURATION_ZERO`, cast literals.
* `No optional to rethrow before '!'` → `alloc::new(...)` is not optional (aborts on OOM); remove the `!`.
* `import std::os::objc` does not exist → it is `std::os::darwin::objc`.
* Generic module instantiation: `Observable{State}`, functions: `observe::begin{State}(alloc)`.
* Cross-compilation check: `--target macos-aarch64` etc. with `compile-only --no-obj` needs no SDK.
* Inline fn-type struct member does not parse → `alias F = fn ...; F name @tag(...)`.
* No static methods (first param must be the type) → use free functions (`dl::open`, not `Library.open`).
* `$elif` does not exist → `$switch/$case/$default`.
* A line starting with `@` inside `<* *>` is parsed as a contract tag → put examples in `//` comments.
* Format strings reject `%u` → use `%d`.
* After `if (catch x = f())` on a variable, x is unwrapped; a following `!!` errors "No optional to rethrow".
* Generic module code is type-checked only when instantiated → instantiate it in a check.
* `min(len, CONST)` mixes `sz` and `usz` → keep both `sz`.
* `Mutex` needs `init()` at run time, so a zero-initialised global cannot hold one.
* `constset` values are typed: compare/assign to `char` needs a cast; from another module write `Type.MEMBER`.
* `NOT_FOUND` is bare in `@return?` contracts (built-in); struct doc comments cannot carry `@param`.
* `String` has no `+` (use `string::tformat`); `String == "literal"` does compare contents. `mem::copy` traps on a null/empty source: guard empty copies.
* Slices: `a[s : len]`, `a[x..y]` inclusive, `a[..]` full; `a[:n]` and `a[:]` are rejected. `ubyte` is not a C3 type (use `char`).
* `$if` cannot wrap top-level declarations → split files by `@feat`. All-uppercase struct names are rejected.
* `typedef` makes a distinct type; use `alias` for handle wrappers. `ulong.sizeof` is invalid → `ulong::size`.
* Domain values: `error::Domain.ERRNO`. errno: `libc::Errno.ENOENT`, not `libc::ENOENT`.
* `std::thread` threads also need `@foreign_entry`/`@pool_init` before using tmem/tformat.
* After `if (catch e = v)`, `!`/`!!` on `v` is rejected; just `return v;`. `$else` has no colon.
* String/char[] need explicit casts; ZString needs `.str_view()`; `test::eq` needs identical types.
* `std::io::path::rmdir(String)` does not compile from another module (stdlib defect) → use `Path`.
* A struct global with constant initialisers must be `const`. `a[start:len]` is start+length; `a[..n]` is inclusive.
* Other modules' globals/typedefs need the module prefix (`hresult::Hresult`). `time::ms()` in a global const overflows → literal µs.
* `catch` is only valid in `if`/`while` conditions. Generic module sections need their own imports; nested generic types need an alias.
* `$assert(cond, "msg")` did not parse; `$assert(cond)` does. Methods cannot take their own type as a type parameter → free generic function.
* Optional-like plain data: reuse `std::collections::maybe::Maybe{T}` ({value, has_value}) rather than ad-hoc has_* flags.
* A function that takes an `Allocator` and opens its own `@pool()` returns dangling results when the caller passes `tmem` → open no pool there; use `tmem` for scratch and copy results with `.copy(allocator)`.
* `std::os::env`-style `=> @pool()` functions that copy into a caller allocator share that hazard; prefer `tformat(...).copy(allocator)` over `string::format(allocator, ...)` (which pools internally).
* A struct returned from a function whose slices point at array literals declared in that function is dangling → build the literal arrays in the caller's frame (or inline the struct).
* `foreach (&x : array)` already binds `x` as a pointer; `&x` is then `T**`.
* `@local` on a method is ignored (warning) → drop it.
* Enum members from another module must be qualified: `error::Domain.INTERNAL`, `XmlEventKind.START_ELEMENT` (`error::INTERNAL` is "could not be found").
* `import m as alias` does not exist → write the full path (`std::encoding::xml::XmlNode`) or `alias NodeKind = std::encoding::xml::XmlEventKind;`.
* Adjacent string literals do not concatenate (`"a" CONST "b"`) → use `string::tformat` or a `const`.
* `foreach (x : { "a", "b" })` → "Add an explicit type": declare `String[2] xs = { ... };` first.
* `struct X (Iface) {}` → "Zero sized structs are not permitted" → give it a real field (e.g. an override table).
* Interface method declarations take typed parameters and no `&self` (`fn String? get(Allocator, String);`); an interface value needs a pointer: pass `&vars` for an `Environment` parameter.
* `try x = f()` is only valid as a whole `if`/`while` condition, not inside `&&` or standalone.
* `double.nan` does not exist in `std::math`; build it with `bitcast((ulong)0x7FF8000000000000, double)`. `math::is_nan`/`is_inf` are macros that need `import std::math`.
* `alloc::new_array(allocator, T, n)` needs `sz`: cast `usz` lengths. `mem::copy` with a zero length from a null pointer asserts ("Passed null to a ref parameter") → return an empty slice first.
* `$embed("../fixtures/x")` resolves relative to the source file and yields `char[]`; cast to `String` before `.trim()` or comparing.
* `foreach` over `String.to_temp_utf32()` needs `!!` (it is optional) → bind the array first.
* `c3fmt -i` changes doc-comment indentation as well as code; run it before `--check`.
* `-D VMEM_TEMP` did not trap a deliberate use-after-scope in a probe on this machine (the pool's pages were not released), so it is not evidence that tmem code is safe.
* `DString.delete_range` end is inclusive; `keep ? {a,b} : {}` with slice literals dangles; `if (catch)`/`try` need the optional itself.
* While libraries are being created in parallel, use `--libdir "$(tools/libdir.sh)"` instead of `--libdir libs` (c3c fails on any lib without manifest.json).
* `Parameters may not be optional` → a `void?` cannot be passed to a function; catch it at the call site (`if (catch err = f()) g(err); else h();`).
* `Functions from other modules must be prefixed with the module name` → same rule for sibling modules of one library: `appearance::publish(...)`.
* `if-statements with an 'else' must use '{ }'` → braces around both branches.
* `Reader is not a generic type` when two imports both export `Reader` (`bleu::dbus::marshal`, `bleu::stream`) → qualify the one you mean: `bleu::stream::Reader{Event}`.
* `String.replace` (a `@pool` function) crashed a test with a segfault → write the substitution by hand; avoid `@pool` helpers that return into a caller allocator.
* `process::run` / `run_capture_stdout` without `SpawnOptions.INHERIT_ENV` gives the child an empty environment (no PATH, no HOME) → pass `process::SpawnOptions.INHERIT_ENV` for `gsettings` and similar tools.
* `c3c compile-run` / `compile-test` write their binaries into the current directory → run them from a scratch directory, never inside the repository.
* `c3c` refuses a `--libdir` that holds any half-created lib → use `tools/libdir.sh`, and remember every `--lib` dependency named in the manifest must be passed too (`Required library 'x' could not be found`).
