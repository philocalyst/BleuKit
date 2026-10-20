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
