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
* `Parameters may not be optional` for `f(Applied? result)` → pass the unwrapped value: branch with `if (catch err = r) {...} else { use(r) }` at the call site.
* `Functions from other modules must be prefixed` for `serve(...)`, `applied_at(...)`, `error::UNAVAILABLE` → qualify with the module (`brightness::serve`); module faults and enum members also need `error::X` / `Cap.X` when there is no expected type to infer them from.
* `A function name must start with lower case` for an `extern fn` named `EnumDisplayMonitors` → lower-case the C3 name and add `@cname("EnumDisplayMonitors")`.
* `An optional 'bool?' cannot be implicitly converted` for `assert(f() == 7)` with `f` returning `int?` → write `assert((f() ?? -1) == 7)`.
* `PathList` is `List{Path}`: use `names.len()`, not `names.len`.
* `'Invalid escape in string'` for `"\\.\LCD"` inside a `@return?` contract → keep backslash text out of contract strings (plain prose).
* `No method or inner struct ... 'T.sizeof'` → use a named `const` for the byte size of a native struct.
* A helper that takes an `Allocator` and opens its own `@pool()` returns dangling memory into a `tmem` caller (`LEAKS` or a crash later) → open the pool in the caller only, and let helpers allocate into the caller's allocator.
* `dbus::Connection.init` records the calling thread as owner → call `init` on the worker thread (in the backend's `run`), not in `create`.
* `std::os::env::get_var(mem, ...)` in a test leaks (`LEAKS DETECTED`) → use `env::tget_var(name)`.
* Two concurrent `c3c` runs in one checkout overwrite each other's `out/testrun` (random segfaults, `Failed to link executable`) → run `compile-test` from a private working directory (`cd "$work" && c3c ...`) with an absolute `--libdir`.
* `Source` is ambiguous when a module imports `bleu::rt::poller` as well as `bleu::battery` → qualify it as `battery::Source`.
* Poller in window-message mode does not dispatch messages: call `message_loop::dispatch_pending()` after each wait.
* `c3c compile-test` runs `@test`s of every linked library, not only the named file.
* `c3c` writes `out/` and `build/` into the current directory: run it from a scratch directory when the lib tree must stay clean.
* `Type.sizeof` is not the idiom here: use `Type::size` (as `Guid::size` in bleu_win).
* Functions and enum members from another module of the same library need the prefix (`apps::copy_strings(...)`, `Cap.WATCH`), even inside a sibling module that imports it → qualify them.
* `@local` hides a helper from the other files of its module; a helper called from two files must not be `@local`.
* `String[4] X = {...}` as a global needs `const` ("looks like a constant variable").
* `std::os::process::spawn` defaults every stdio to CAPTURE (a pipe nobody reads, so the child blocks) → pass `process::INHERIT` (or bind a fd).
* Generic aliases need their arguments at use site: `Packet{Event}*`, `WorkerHost` → define `alias AppsHost = Host{Command};` in the module.
* `Duration` globals need a cast from integer literals: `(Duration)200_000`.
* `libc::Pid_t` needs `import libc`; `std::os::posix` does not re-export it.
* Platform externs: names must start lower-case (`shell_execute_w` with `@cname("ShellExecuteW")`), and a `WIN32`-only module with `@link` still parses on every target, so keep its syntax clean.
* A zero-initialised `unix::Fd` holds fd 0, not nothing: use `unix::no_fd()`.
* `Time` (from `std::time`, wall clock) and `Duration` are distinct: cast both ways, `(Duration)now_unix_us`, never bare arithmetic across them.
* A type named `Reader` clashes between `bleu::stream` and `bleu::dbus::marshal`: qualify (`stream::Reader{Event}*`).
* A `typedef` numeric (`typedef PlaybackRate = double`) forces a cast on every literal; use `alias` when the type is only a documented name for a plain number.
* `if (catch e = f()) {...} else {...}` needs braces around both branches.
* `Anchor{ .x = ... }` is not a struct literal in 0.8.5: declare the variable and assign it.
* No `+` on `String` and no adjacent literal concatenation: a multi-line script is one literal with `\n` escapes.
* Cross-module enum members need qualifying even in `case` labels (`case CommandKind.PLAY:`); a local struct named like an imported enum (`Backend`) needs the module path (`media::Backend.SMTC`).
* `c3c --sources "dir/*.c3"` does not expand the glob: pass the files through the shell (`compile-test libs/x/src/*.c3`).
* `c3c compile-test` linking can fail with missing `build/obj` files when several engineers share the repo's `build/`: run it from a private working directory.
* A Unix socket path is limited to 108 bytes: a dbus-daemon in a deep scratch directory fails with "Socket name too long"; use `mktemp -d /tmp/...`.
* `c3fmt -i` and `c3fmt --check` can disagree on a declaration whose `=` is aligned with its neighbours; a blank line between them makes both agree.
* `foreach (line : text.tokenize("\n"))` → "It's not possible to enumerate an expression of type 'Splitter'" → `Splitter s = text.tokenize("\n"); while (try line = s.next())`.
* `alias` and `interface` are keywords: a struct field `alias` or a variable `interface` is a parse error → rename (`alias_name`, `link`).
* `Type.sizeof` and `@sizeof(Type)` are rejected for types → `@sizeof(variable)`; `ulong.sizeof` → `ulong::size`.
* `typedef Bytes = ulong;` is distinct: `Bytes + ulong` and `ulong` returns need casts everywhere → use `alias` for pure quantities that are summed.
* `test::eq(a, b)` fails with "values must be equatable" for a typedef against its base type, and for `ulong` against an `int` expression → compare with the same type (`1UL`, `(ulong)x`).
* `c3c --libdir libs` refuses to compile while any `libs/*.c3l` has no manifest.json (another agent's half-made library) → `c3c --libdir "$(tools/libdir.sh)" ...`.
* `else if (...) x;` with a single statement after a chain that started with `if (...) x;` → "if-statements with an 'else' must use '{ }'" → brace every branch.
* A `foreach` loop variable declared `&x` is a pointer; `(T)*x` is needed to read it as a value (`maybe::value(*average)`).
* Function names from another module in the same library must be prefixed (`sysinfo::fill_cpu`), even inside a sub-module of that module.
* A C symbol with `$` in its name (`getmntinfo$INODE64`) is bound with @cname like any other; to choose one of two bindings by arch, use `$if` inside the function body (top-level `$if` is not allowed).
* `c3c --libdir libs` fails when any `libs/*.c3l` lacks a manifest → use `--libdir "$(tools/libdir.sh)"`.
* `$elif` does not exist → use `$switch` / `$case` / `$default` (`$endswitch`).
* Extern callback structs (`kCFTypeDictionaryKeyCallBacks`) must be `extern const` with a struct type, and their address passed.
* Generic service aliases (`EventPacket`, `StateSnapshot`) need `Packet{Event}` / `Snapshot{State}` from `bleu::stream` / `bleu::observe` in files outside the service module.
* Module functions from another module need the prefix even inside the same library (`secrets::emit_local`), and C library functions too (`win32::getLastError`).
* `String.copy` works on `String` values; `alloc::clone_slice` on `char[]`. Slicing a fixed array into a fixed array (`char[16] k = arr[:16]`) is not valid; copy element by element.
* `char[]` has no `.copy`; cast to `String` first, or use `alloc::clone_slice`.
* `c3fmt -i` can oscillate on long aligned struct literals (`Entry key = {...}` split and joined); bind the parts to named variables first.
* `Connection.init` (bleu_dbus) called twice on the same struct leaks its lists; guard the init with the "initialised" flag, and set it in struct literals that skip the guard.
* dbus-next marshals a D-Bus STRUCT from a Python list; a tuple raises `SignatureBodyMismatchError`.
* `Parameters may not be optional` for `void? r` as a parameter → pass the value, or test the result with a macro such as `testing::@expect_fault(expr, NOT_FOUND)`.
* `The format string cannot be a vaarg parameter` when a helper `fn fault f(String fmt, args...)` forwards `fmt` to `error::raise` → call `error::raise(...)` directly at each site.
* `Fallthrough cases with empty rows or comments have unclear meaning` in a `switch` → give each case a statement, or `return` in it; a comment-only case body is an error.
* `Did you mean the struct 'List' in module std::collections::list?` → every file that uses `List{T}` needs its own `import std::collections::list` (imports are per file, not per module).
* `Implicitly casting 'int' to 'ReplyToken'` for a `typedef ReplyToken = uint;` → cast literals and `ReplyToken` results explicitly, e.g. `(ReplyToken)0`.
* `Expected '('` for a global declared `fn Service service;` → a global variable is declared without `fn`: `Service service;`.
* `c3c compile-only` and `compile-test` write `./obj` and `./out` into the working directory → run them from a scratch directory when a checkout must stay clean.
* `@private` on a method declaration (`fn T Type.name(&self) @private`) is an error in this compiler → drop it, or make the helper a free function with `@private`.
* A protocol type or constant of another module written bare (`WlSeat`, `ZWLR_OUTPUT_MANAGER_V1`) → `Globals/types from other modules must be prefixed`; write `module::NAME` everywhere, including test code.
* `(void)unix::Fd{ .value = fd }.close()` → methods cannot be called on a struct literal; use a helper that takes the raw descriptor (`display::native_close(fd)`).
* No labelled blocks in C3 0.8.5 (`label: { ... break label; }` does not parse) → split the body into a helper that returns early.
* `char[N]` struct fields have no `.ptr`; take `&arr[0]` for `mem::copy`/`mem::move`, and cast `usz` lengths to `sz`.
* A local named `error` shadows the `bleu::error` module and fails with "An expression was expected" → name it `failure`.
* `List`/`HashMap` need an explicit `import std::collections::list;` even when `List{T}` is only used in a struct field.
* Generated protocol code: a constset conversion from `int` needs `(T)(uint)value`; a method name equal to a struct field (`Display.fd` vs `fd`) is rejected → rename the field.
* `c3c compile-test` writes `./out/testrun` by default, which another engineer's build may also use → pass `-o <scratch path>` and run the binary under `timeout`, since a deadlocked scenario thread hangs the run without a message.
* `alias` is a keyword: a local named `alias` is rejected → name it `nickname`.
* `if (try x = f()) ... else` needs braces around the `else` body; `if (catch e = v) {} else { ... }` is accepted.
* Struct `.sizeof` and `$sizeof(T)` do not exist in 0.8.5 here → use named constants with the layout cited.
* `foreach (&x : array)` binds `x` as a pointer already: `return &x;` is `T**` → `return x;`.
* A local named `value` shadows `bleu::dbus::value` (and `list` shadows `std::collections::list`) → pick other names.
* Inside `@pool()`, a value copied into a variable declared outside the pool is dangling after the pool closes → copy into a slot or heap allocator first.
* `Enum.MEMBER` in a `case` label of another module must be qualified, and two enums sharing a member name (Cap, Command) need the right one.
* `c3c --libdir libs` fails while any half-created lib lacks manifest.json → use `tools/libdir.sh`.
* `Type?` cannot be tested with `.has_value`; use `if (try ...)` or `@catch(...)` comparisons.
* `extern fn AudioObjectGetPropertyData` → "A function name must start with lower case" → name it `audio_object_get_property_data` with `@cname("AudioObjectGetPropertyData")`.
* `if (catch err = status_fn())` on a C function returning `int` → "not optional": compare with `!= 0` instead.
* A constset member flowing into a `uint` (or compared with one) → "Implicitly casting ... not permitted": write `(uint)Enum.MEMBER`, or type the parameter as the constset.
* `defer catch list.free();` on a non-fallible call is rejected → guard the defer with a flag: `bool handed_over = false; defer if (!handed_over) list.free();`.
* `alias` is a keyword: a local named `alias` → "cannot use a keyword as variable name".
* `@private` on a method is ignored with a warning → drop it (free functions take `@private`).
* A struct field `balance` of a `Maybe{float}` type from another module → "Functions from other modules must be prefixed": qualify as `pulse::balance_of`, `pulse::TagReader` and so on.
* `Gain` (a `bleu::unit` typedef) compared with a float literal → cast: `(float)gain`; literal arrays of it need `(Gain)0.5f`.
* Fixed-size array in a struct literal with fewer elements than the array (`uint[32] values = {a, b}`) → "Too few elements": assign the elements one by one.
* `c3c --sources "dir/*.c3"` does not expand the glob → pass the files through shell expansion (`$(ls dir/*.c3)`).
* A PulseAudio proplist value includes its terminating NUL inside the blob → strip a trailing `\0` before comparing (`pulse_wire.c3`).
* A `Duration` constant from an int literal (`const Duration T = 5_000_000;`) → cast: `(Duration)5_000_000`.
* `Object*? x = f()!;` keeps x optional (passing x on fails): declare `Object* x = f()!;`. `Object.get` on the wrong JSON type reads the wrong union member: check `is_map`/`is_array` first.
* `if (catch e = x)` scopes e to the if: bind the optional first, then unwrap. `foreach (k : {"a","b"})` needs a `const String[N]` global.
* A constset value passed where `uint` is expected needs `(uint)`; switch on `(EventType)x`. An interface-impl struct field named `kind` clashes with a `kind()` method.
* `$embed` paths are relative to the source file; cast with `(String)$embed(...)`. `test::eq` needs identical types.
* `uchar` and `ubyte` are not types → use `char` (unsigned byte) and cast the other side.
* `uint.max` does not exist → write the literal (`0xFFFF_FFFF`), or use a helper.
* `var x = f();` is only allowed in macros or with `@safeinfer` → give the type (`Snapshot{Event}* p = ...`).
* `switch` on a `String` with literal `case` labels compiles and runs in 0.8.5 (bleu_battery `sysfs_convert.c3`, unit-tested on Linux). Verified; the earlier "not supported" note was wrong.
* `Writer.begin_array` takes the full array type (`"a{sv}"`, `"as"`), not the element type.
* `alloc::clone_slice` rejects a `String` argument ("only arrays and slices") → copy into `char[]` with `alloc::new_array` and a loop.
* `alloc::new_array(allocator, T, n)` needs `sz`: cast a `usz` count.
* A local variable named `bus` hides the module `bleu::dbus::bus`, so `bus::NAME_...` fails → name the connection `conn`.
* `Mutex.init()` returns `void?`, so a bare call fails with "must be handled" → write `init()!!` (or handle the error).
* `objc::id_block` and `objc::bool_error_block` need the `objc::` prefix; an `ObjId` is compared by truthiness (`if (id)`), not with `null`.
* A bleu_dbus `OwnedName` on a queued request reports success with `held == false` → always pass `NAME_DO_NOT_QUEUE`.
* A helper a `$switch` in an ungated file calls must live in the same module (`bleu::notify::sender`) in a gated file that imports the backend, as `battery`'s `linux.c3` does.
* `DETAIL_TEXT_CAPACITY` (240 bytes) truncates the message of `error::raise` silently → keep user-facing reasons under 240 bytes.
* A child process's stdout is block-buffered when piped → call `io::stdout().flush()!!` after each answer, or the parent reads nothing.
* A `std::thread` created by a C3 program needs `foreign::@foreign_entry()` for temporary memory and must return `int` (`ThreadFn`).
* `Store.post`-style helpers that copy into an arena per notification avoid copying on the wire path: give each entry its own `DynamicArenaAllocator` and free the arena with the entry.
* `foreach (x : arr)` copies; mutate through `foreach (&x : arr)` (x is then a pointer). A `@return?` contract on a void function is accepted but meaningless.
* `case A, B:` (several labels in one case) → "Missing ':' after case" → one `case` per value, or `if` chains.
* `case X:` with an empty body followed by another case → "Fallthrough cases with empty rows" → give each case its own `return`.
* `if (T* r = f())` (a declaration in an `if` condition) is rejected → declare first, then test `r != null`.
* `void?` passed as a parameter (`complete(op, call(...))`) → "Parameters may not be optional" → return `bool?` and test it with `catch` at the caller.
* `x ?? y` after `if (catch err = x)` on a variable → "No optional to use '??' with" → after the catch the variable is already unwrapped.
* `value::i32(...)` / `value::boolean(...)` return `Value`, not `Value?`: a `!` after them is "No optional to rethrow".
* A `!` inside a `void` helper's catch/expression (e.g. `{ value::str(tmem, s)! }` inside an `if (catch ...)`) rethrows into a void function → build the value with `if (try v = ...)` first.
* `Duration` in a module that imports `bleu::tray` only → "Did you mean the distinct type 'Duration'" → `import std::time` in that file.
* `List.pop_first()` is optional → iterate with `while (try p = list.pop_first())`; `list.array_view()` is the slice for a `List{T}`.
* Indexing and loops over `.len()` (signed `sz`) with `usz` counters, and `mem::copy` lengths, give narrowing errors → keep one signed type for indexes and cast the byte counts.
* `libc::getpid` is absent → `import std::os::posix` and call `posix::getpid()` (`@feat(POSIX)`).
* `Shell_NotifyIconW`, `CreatePopupMenu`, `AppendMenuW`, `TrackPopupMenu`, `LoadImageW`, `RegisterWindowMessageW` are not bound by `std::os::win32` → declare them as `extern fn` in a module with `@link("shell32")` / `@link("user32")`.
* A module named `bleu::x::win32` that also calls `win32::` from `std::os::win32` resolves the prefix to itself → name the module differently (`windows_tray`).
* `tmem` inside a `@test` leaks unless it is pooled; `mem` with `LEAKS DETECTED` in a test → allocate test strings with `tmem`.
* `macro expect_fault(#result, ...)` → "Expression parameters are not allowed in function-like macros" → name it `macro @expect_fault(...)`.
* `Obj item = { .ptr = sender };` borrows a foreign object without retaining it (the struct literal of `objc::Obj`); `borrow` retains.
* A string `case` value in `switch` was avoided; the tray code uses `if (text == "...")` chains for string enums (not verified that `switch` on `String` is rejected).
* `any` is a keyword: a method named `any` is "Expected a function name" → use a name such as `differs`.
* `catch`/`try` apply to optionals (`T?`), not to a `Maybe{T}` struct: test `.has_value`.
* `List.len()` and slice `.len` are `sz`: index with `sz` (or cast); `usz` loop counters fail "cannot be narrowed". `Mailbox.take_all` returns `usz`: keep that count `usz`.
* `std::io::path` entries (`PathList`) are string-backed: `(String)entry` gives the name; there is no `str_view()`.
* A bare `TIMEOUT` is a fault value; pass it to `Operation.fail` / `error::raise`-style parameters without `~` (`~` raises).
* A function returning `void` cannot return the value of another `void` call: `return reject(...)` → call, then `return;`.
* A module-level `alias` (e.g. `alias Mode = display::Mode`) in one file of a module leaks into the module's tests and collides with the imported type: qualify instead.
* `compile-test` runs every linked library's `@test`s and exits non-zero when any aborts, so a clean build can still report `exit=1`: read the summary line.
* A mock-compositor scenario that expects requests hangs forever when the code under test sends none (an unchanged config completes locally); also `Operation.wait()` without a timeout blocks until the op completes. Kill test processes by PID: `pkill -f <pattern>` matches the shell that runs it.
* `string::tformat` results live in temporary memory: copy before the `@pool()` ends, and never return them from a function (dangling).
* `Maybe{T}` cannot take an array literal: copy the value through `.set(...)`.
* `Names of consts must be all uppercase` for `extern const kTISPropertyInputSourceID` → name it `TIS_PROPERTY_INPUT_SOURCE_ID` and keep the native name in `@cname("kTISPropertyInputSourceID")`; a `@feat(DARWIN)` file is parsed on every target, so the error breaks Linux too.
* A `@feat(LINUX)`/`(DARWIN)` module's `@feat` only gates type-checking: its syntax and naming rules are checked on every target.
* `Duration` (and `Maybe`) used in a file that names them only through another module → add `import std::time` (`import std::collections::maybe`) to that file; imports are per file.
* A backend file that imports `bleu::input` and `bleu::compositor::backend` gets "The interface 'Backend' is defined in both" → qualify the enum: `input::Backend.COMPOSITOR`.
* `Functions from other modules must be prefixed` also applies to helpers of a sibling module of the same library in backend files: `input::publish_state(...)`, `input::index_of(...)`.
* `std::os::win32` binds `GetKeyboardLayout`, `PostMessageW` and the HKL/HWND/LPARAM types but not `GetKeyboardLayoutList`, `GetForegroundWindow` or `LCIDToLocaleName` → declare those with `extern fn ... @link("user32")` and a `@cname`.
* Testing an optional-returning function: `x.has_value` and `f() ?? false == x` do not compile → `if (try v = f()) {...} else { test::@check(false, "...") }` and `test::@error(f(), NOT_FOUND)`.
* `c3c compile-test tools/empty.c3` with `--lib <lib>` runs the `@test`s of that library's `src/` too; no need to name the test files.
* A zeroed enum is its FIRST value (e.g. a zeroed State reads as CONNECTED): put the safe/"unknown" value first, and set status fields explicitly on every snapshot.
* `std::os::win32::dwmGetWindowAttribute` takes `HWND*` (wrong for the C API): declare your own extern. Declare missing user32 calls locally until they move into `bleu_win`.
* A panic on a non-test thread under the std test runner longjmps across threads and HANGS the suite (a failure looks like a hang in the next test): in thread helpers, report and `os::exit(1)` instead of asserting.
* `c3fmt` is not idempotent on some aligned declaration groups (oscillates): format until stable, separate groups with blank lines.
* `catch` is rejected inside `&&`; importing a module with a generic-looking `EventKind` can make it ambiguous with another lib's `EventKind`: qualify it.
* A compile-time error that must name a member: `$error "not plain data at " +++ $path +++ "." +++ $member.name;` (`+++` concatenates compile-time strings; the manual's "Concatenation" section). `$error $member.name;` alone prints only the name, and a second `$error` in the same branch is never reached.
* `$warning` does not exist in 0.8.5; `$Type.nameof` and `value.nameof` do not exist either (use `enum.description` for an enum's name, and recognise a generic like `Maybe{T}` by its member shape).
* A type declared inside a function body (`struct`, `constset`, `enum`) is a parse error; declare it at file scope, and a struct literal needs a cast: `(Caps){ .charge = true }`.
* Cross-module names inside the same library need the prefix even from a sub-module (`json::MAX_DEPTH`); a test file that is `bleu::json::x_test` cannot reach its module's constants unqualified, so test files that need them declare `module bleu::json;`.
* `std::encoding::json` and a library module named `bleu::json` both answer to `json::`: inside `bleu::json` the bare `json::` is the library's own module; write `std::encoding::json::...` (or import it and call `json::` only where no library module is in scope).
* A struct returned by value whose `Slice` members point at an array literal declared in the callee is dangling: the serialiser then crashed with `Out of bounds memory access` deep inside the writer. Return fixed arrays by value and build the slices in the caller.
* A `defer` that frees a tree on error and not on success needs a guard flag (`bool handed_over = false; defer if (!handed_over) root.free();`), set just before the successful return.
* DMS/dankgo wire: a zero request id is OMITTED from frames (omitempty), contrary to an earlier note in dms_surface.md; `defer` is a keyword (use `defer_reply`).
* Child-module visibility: a module only sees siblings it imports; no `offsetof` in 0.8.5 (use `$assert` on struct sizes or `Type.member.offset` via reflection if available); guard Darwin-only code with `$feat(DARWIN)` inside shared files.
* `import libc` next to `bleu::rt::unix` → "The struct 'Fd' is defined in both" → write `unix::Fd` in the file that imports libc.
* `service::DEFAULT_QUEUE` from a generic module is a generic constant → "did you forget the parameters" → define the number in your own module (`COMMAND_QUEUE`).
* `std::thread::sleep(d)` returns `void?` → write `thread::sleep(d)!!;` in a function that can fail, or handle it.
* `git archive HEAD <path>` takes the path from the repository root (`/home/user/BleuKit`), not the project dir; a failing archive in a `|` pipeline is silent → check the archive's exit status before trusting the tree.
* While other engineers edit the dependencies, `compile-test` of your lib fails in their code → build a verification tree: `git archive <commit>` for the dependencies and your own lib directories copied over it.
* `c3c compile-test` runs the `@test`s of every linked library, so a hanging test in another library (bleu_rt `unix_test`) hangs yours → pass `--test-filter bleu::<your module>`, or use `compile` for live drivers that have no tests.
* `Observable.unwatch` returns `void?` (INVALID_STATE from inside its own listener): a service that forwards it as `void` fails with "must be handled" → declare `void? Svc.unwatch` and document the error.
* `Hub.stop` no longer frees the observable and stream lists → every service `close()` and every test must call `hub.free()` after `stop`, or `LEAKS DETECTED` is reported.
* A generic module's alias needs its parameters at the use site: `service::RunFn{input::State, input::Command, input::Event}`, not `RunFn`.
* An aligned struct literal in a `Command command = {...}` line can oscillate under `c3fmt`; bind the copied field to a named local first.
