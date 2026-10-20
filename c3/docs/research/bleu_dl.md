# bleu_dl research notes

Scope: run-time resolution of optional and private native symbols
(`libs/bleu_dl.c3l`). This file records each binding decision, its sources,
and what was cross-checked. "Fetched" means read during this work;
"local" means a file on this machine; "not verified" means stated from
background knowledge and still to be checked against a primary source.

## 1. Why run-time binding

Link-time references to a private symbol make the whole binary fail to load
when the symbol is missing or renamed. Bleu therefore resolves such symbols
with the platform loader when a service needs them.

* POSIX: `dlopen`, `dlsym`, `dlerror`, `dlclose`. Source: glibc
  `/usr/include/dlfcn.h` (local, glibc 2.39, `libc6-dev 2.39-0ubuntu8.9`):
  `dlopen` returns a handle or NULL; `dlsym(handle, name)` returns the
  address; "When any of the above functions fails, call this function to
  return a string describing the error. Each call resets the error string so
  that a following call returns null." `RTLD_DEFAULT` is `((void *) 0)`.
* Apple: `dlopen(3)` (fetched, Apple archived iPhoneOS man page): "If dlopen()
  fails, it returns a null pointer, and sets an error condition which may be
  interrogated with dlerror()." "If a null pointer is passed as path,
  dlopen() returns a handle equivalent to RTLD_DEFAULT." Defaults: "If neither
  RTLD_LAZY nor RTLD_NOW is given, the default is RTLD_LAZY. If neither
  RTLD_GLOBAL nor RTLD_LOCAL is given, the default is RTLD_GLOBAL."
  The same page gives the leaf-name search order
  (`$LD_LIBRARY_PATH`/`$DYLD_LIBRARY_PATH`, cwd, `$DYLD_FALLBACK_LIBRARY_PATH`).
  It does not mention frameworks, the dyld shared cache or `dlerror` detail.
* Windows: `LoadLibraryExW` (fetched, Microsoft Learn): "If the function fails,
  the return value is NULL. To get extended error information, call
  GetLastError." The `LOAD_LIBRARY_SEARCH_DEFAULT_DIRS` flag "is a combination
  of LOAD_LIBRARY_SEARCH_APPLICATION_DIR, LOAD_LIBRARY_SEARCH_SYSTEM32, and
  LOAD_LIBRARY_SEARCH_USER_DIRS. Directories in the standard search path are
  not searched." `GetProcAddress` (fetched): the name is "the function or
  variable name, or the function's ordinal value"; on failure it returns NULL
  and "To get extended error information, call GetLastError".
* Standard library precedent: `/opt/c3/c3/lib/std/os/os.c3` (local) already
  wraps the platform loader: `dlopen`, `dlsym`, `DylibHandle.close`,
  `DylibOpenOptions` (`resolve_now`, `global_symbols`, `safe_search`,
  `system_only`), mapping to `LoadLibraryExA`/`GetProcAddress` on WIN32 and
  `libc::dlopen`/`dlsym` on POSIX. `bleu_dl` builds on it and adds only
  what it lacks: the loader's failure text (`dlerror`/`FormatMessageA`), the
  candidate list, the main-program handle, the reflective binding and the
  shared lazy table.

## 2. Decisions

| Decision | Reason | Source |
| --- | --- | --- |
| Use `std::os::dlopen`/`dlsym` | The std wrapper already selects the platform API; no duplicate `#if` logic | local `os.c3` |
| `DylibOpenOptions` default `{ .safe_search = true }` on Windows | `LOAD_LIBRARY_SEARCH_DEFAULT_DIRS` excludes the current directory, so a planted DLL is not loaded | fetched LoadLibraryExW |
| POSIX default `RTLD_LAZY`, local symbols | Lazy binding keeps a library with one unrelated missing dependency symbol loadable; `RTLD_NOW` would fail the whole library | fetched Apple dlopen(3) for the modes; decision is ours |
| `dlerror()` text read right after a failed call | `dlerror` describes only the last call | local dlfcn.h |
| `errno` captured with the `dlerror` text (POSIX), `GetLastError` plus `FormatMessageA` (Windows) | Both are needed for the `Detail.code` and a readable message | local dlfcn.h; `libc::errno` in local std |
| `dlopen(NULL)` for the main program on POSIX, `GetModuleHandleA(NULL)` on Windows | `LoadLibrary(NULL)` is not the process handle on Windows | local dlfcn.h (RTLD_DEFAULT/NULL); fetched LoadLibraryExW (NULL not a module name) |
| Library name stored inline (`char[256]`) | A lazily bound global must not leak; the test runner reported a 10-byte leak when the name was heap-copied | own test run |
| Symbol absent for optional member: null, no error recorded | Absence is an ordinary answer; recording it would overwrite the detail of a real failure | design |
| Required member absent: `UNSUPPORTED` with symbol and member in the message | The OS build lacks the API, which is "can never do this here" | `bleu::error` vocabulary (`docs/ARCHITECTURE.md`) |
| Lazy: atomic phase (UNBOUND/BINDING/BOUND/FAILED), spin-yield while binding, cached failure | Lock-free read path; the binding is one `dlopen` so yielding is cheap; a `Mutex` must be initialised with `init()` at run time, so a zero-initialised global cannot hold one | design; `Atomic.compare_exchange` in local std `atomic.c3` |
| `Library.close()` only for unused libraries | After `dlclose`, every pointer obtained from the library dangles. Rust `libloading` says the same: `Library::get` is `unsafe` and `Drop` unloads | fetched docs.rs libloading Library |

## 3. Reflection (`@tag`) binding

* `@tag(name, value)` on struct members is a supported 0.8.5 attribute:
  "Used for: function, macro, function parameters, user-defined type,
  struct/union/bitstruct member, global, local variables" (local
  `/opt/c3/c3/MANUAL.md` section 7_4 Reflection and 11_2_16 Attributes).
  Read with `$member.has_tag(...)` and `$member.get_tag(...)` inside
  `$foreach $member : Type::members` (MANUAL 7_4, `members` and `get_tag`).
* Probed locally: the inline form `fn int(uint) name @tag(...)` does not
  parse in 0.8.5 (error "A type name was expected"). The accepted form is
  `alias F = fn ...; F name @tag(...)`.
* `$error "..."` is available to reject an untagged member at compile time.

## 4. Calling convention

* x86-64 Windows and AArch64 Windows use one calling convention for ordinary
  exported functions; C3's default `fn` matches it. 32-bit stdcall is out of
  scope (no 32-bit Windows target in `tools/check.sh`).
  Status: **not verified** against a primary page in this session; the
  statement is from the Microsoft x64 and ARM64 calling-convention pages,
  not fetched.

## 5. Library names

* `libloading` (Rust) `Library::new`: "A plain filename is searched for in
  platform-specific locations... The `.dll` extension is implicitly added on
  Windows." (fetched docs.rs/libloading `struct.Library.html`).
* Bleu candidates follow the same rule: a bare soname or DLL name lets the
  loader search; a path names one file. The macOS framework path
  `/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices`
  is the binary inside the framework bundle.
* Dyld shared cache: a framework that is absent on disk can still be opened by
  its path on macOS 11 and later, because the loader resolves paths through the
  shared cache. **Not verified** here: the Apple `dlopen(3)` page fetched does
  not say so. Keep it as a stated expectation to confirm on a Mac.

## 6. Library safety

* `libloading`'s safety notes (fetched): loading "initialisation routines
  contained within it are executed"; unloading "routines may be executed when
  the library is unloaded"; `get` requires "the correct type T". Bleu follows
  the same rules and states them in the doc comments of `open`, `close`, `find`.
* `Library.close()` is explicit and documented as unsafe while pointers or
  callbacks from the library remain. The main program is never unloaded.

## 7. Verification log

Run on Linux (glibc, x86-64), `c3c 0.8.5_1`:

* `compile-test` of `libs/bleu_dl.c3l/src/dl_test.c3` with the library:
  9 of 9 `@test` functions pass, including binding `strlen` from `libc.so.6`,
  `cos` from `libm.so.6`, an optional missing symbol (null, reported by
  `@each_unbound`), a required missing symbol (UNSUPPORTED naming both),
  an open failure listing the last candidate, a symbol miss (NOT_FOUND),
  `main_program`, and the shared `Lazy` binding once and caching a failure.
* Scratch program (`compile-run`) printed the real messages, for example:
  `no library loadable from 2 candidate(s), last '/nonexistent/libthing.so':
  /nonexistent/libthing.so: cannot open shared object file: No such file or directory`.
* `c3c compile-only` for `bleu_core` and `bleu_dl` on all six targets:
  clean (linux-x64, linux-aarch64, macos-aarch64, macos-x64, windows-x64,
  windows-aarch64). An instantiation of `lazy::Lazy{T}` was also checked on
  all six targets, because generic code is only type-checked when used.
* `dl_test.c3` type-checked (no errors before the link step) for
  macos-aarch64 and windows-x64. Linking was not possible here (no macOS SDK,
  no MSVC SDK), so these runs are compiled-only.
* `c3fmt --check --default` passes on all of `libs/bleu_dl.c3l/src/*.c3`.

Not run on macOS or Windows: no runtime evidence for the Apple or Windows
branches (`main_program` via `GetModuleHandleA`, `FormatMessageA` text,
`DylibOpenOptions.safe_search` on a real DLL search). They are type-checked only.

## 8. Sources

Fetched in this session:

* Microsoft Learn, LoadLibraryExW:
  https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-loadlibraryexw
* Microsoft Learn, GetProcAddress:
  https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-getprocaddress
* Apple, dlopen(3) (archived iPhoneOS manual):
  https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/dlopen.3.html
* Rust `libloading`, `Library` (docs.rs):
  https://docs.rs/libloading/latest/libloading/struct.Library.html

Local:

* glibc `/usr/include/dlfcn.h` (libc6-dev 2.39-0ubuntu8.9)
* `/opt/c3/c3/lib/std/os/os.c3`, `/opt/c3/c3/lib/std/os/win32/libloaderapi.c3`
* `/opt/c3/c3/MANUAL.md` sections 7_4 Reflection, 11_2_15 Reflection, 11_2_16 Attributes

Man pages `dlopen(3)`, `dlsym(3)`, `dlerror(3)`, `dyld(3)` are not installed
on this machine (minimised image) and were not fetched from man7.org; the
glibc header and Apple's page above stand in for them. Apple's `dyld(3)` page
was not fetched.
