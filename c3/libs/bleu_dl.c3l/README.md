# bleu_dl

Run-time resolution of optional and private native symbols. A missing or
renamed symbol makes one capability `UNSUPPORTED`; it never stops the library
from loading or crashes the process. Built on `std::os::dlopen`/`dlsym`
(POSIX) and `LoadLibraryExA`/`GetProcAddress` (Windows). Research and sources:
`docs/research/bleu_dl.md`.

## Public API (module `bleu::dl`)

* `Library` (struct): `handle`, `label`; methods `name()`, `find(name)`,
  `has(name)`, `symbol(name)`, `close()`.
* `open(String[] candidates, DylibOpenOptions options = DEFAULT_OPTIONS) -> Library?`:
  first candidate that loads; `UNAVAILABLE` with the loader's text otherwise.
* `main_program() -> Library?`: the executable's own symbols.
* `bind(&table, &library)` (macro): fills every member of a struct of function-pointer
  aliases, each tagged `@tag("sym", "<C symbol>")`; `@tag("optional", "true")` allows absence.
* `@each_unbound(&table; String member, String symbol) { ... };`: visits the optional members that did not resolve.
* `lazy::Lazy{Table}` (generic module `bleu::dl::lazy`): a table bound once on first `get(candidates)`, shared by every caller, failure cached.

## Not done

* 32-bit stdcall Windows (out of scope; the Windows targets are x64 and ARM64).
* Data symbols (variables): `bind` assigns function pointers only.
* Ordinal imports on Windows: symbols are looked up by name.
* `dlmopen`, `dladdr` and the `RTLD_NOW` option through the default path.
* Closing a library safely: `close()` is documented as unsafe while anything
  from the library is still referenced; nothing enforces it.
* Names longer than 256 bytes are truncated in `Library.name()` (diagnostics only).

## Verified how

* Run on Linux (glibc, x86-64): `dl_test.c3`, 9 of 9 `@test` functions pass
  (`c3c compile-test`). Command:
  `c3c --libdir libs --lib bleu_core --lib bleu_dl compile-test libs/bleu_dl.c3l/src/dl_test.c3 --sources libs/bleu_dl.c3l/src/*.c3`.
* Type-checked (`compile-only`) for all six targets, including an instantiation of `lazy::Lazy`.
* macOS and Windows: type-checked only (test module reached the end of type checking; no linking, no runtime).
