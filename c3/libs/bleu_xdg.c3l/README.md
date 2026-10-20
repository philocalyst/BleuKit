# bleu_xdg

freedesktop.org building blocks for Bleu: the Base Directory layout, the
Desktop Entry key-file syntax, desktop files and their `Exec` lines, icon theme
lookup, and MIME application associations. Parsing is portable; the directory
and file lookups use the same XDG rules on every OS (see `bleu::xdg::dirs`).

Module root `bleu::xdg`. Depends on `bleu_core` (the error vocabulary).

## Public API

- `dirs`: `Environment` (interface), `ProcessEnvironment` (process env with overrides), `Variables` (fixed table), `is_absolute`, `data_home`, `config_home`, `cache_home`, `state_home`, `runtime_dir`, `data_dirs`, `config_dirs`.
- `keyfile`: `parse` / `parse_with(KeySyntax)` → `KeyFile` with `get_string`, `get_localized_string` (spec locale order), `get_strings` (`;` lists), `get_boolean`, `get_numeric`, `has_group`, `has_key`, `free`. `parse_locale`. `load_file(path)` reads a file whole, refusing files over `MAX_FILE_BYTES` (1 MiB) with OUT_OF_RANGE before reading and mapping I/O errors to NOT_FOUND, PERMISSION_DENIED or BACKEND_FAILURE. Input that is not UTF-8 is refused (PROTOCOL).
- `desktop_entry`: `parse`, `load` → `DesktopEntry*` (typed fields including `url`, `Action[]`, `show_in(desktops)`, `release`; `Type=Link` without `URL` is refused); `scan(data_dirs, ctx, visitor)` yields one `DesktopFile{id, path}` per desktop-file ID in precedence order; `current_desktops`.
- `exec`: `Context{files, urls, icon, name, location}` and `expand(allocator, exec, ctx)` → one argv per invocation.
- `icon`: `parse_index(allocator, name, text)` → `Theme`; `open(allocator, base_dirs, theme)` → `Finder` with `find(allocator, name, size, scale)` (paths only), `clear`, `release`; `default_base_dirs`.
- `mime`: `sources`, `default_application(env, allocator, mime)`, `associated_applications(...)`, `cached_applications(text, allocator, mime)` (`mimeinfo.cache`).

Ownership: results are copied into the allocator passed in. Scratch memory comes from
`tmem`, so call these from inside a `@pool()` in loops.

## Not done

- `trash` (Trash specification): not written. The brief allowed skipping it.
- Shared-MIME-info glob matching and subclass hierarchies: `default_application` and
  `associated_applications` handle exactly the type given, not its parents.
- `$XDG_RUNTIME_DIR` ownership and mode (0700) are not checked (needs `stat`).
- Desktop entry localized `Keywords`; `Hidden` / `NoDisplay` are fields for the caller.
- Icon files are never decoded; `.icon` data files are not read.
- `URL` is refused when missing from a Link. The specification also says it must be absent on other types ("when and only when"); that half is not enforced.
- `Exec` field codes inside double quotes are refused. The specification defines their expansion (quoting is undone first), so this is stricter than the specification; see `docs/reviews/bleu_data_libs.md`.
- Icon theme lookup visits each theme once per lookup (a visited set), so a cyclic `Inherits` returns NOT_FOUND quickly.

## Verification

- Run: 64 unit tests (`compile-test libs/bleu_xdg.c3l/src/*_test.c3`), including the
  specification's Exec quoting examples, the specification's example desktop file
  (`fixtures/foo-viewer.desktop`), malformed-input refusals with line numbers, and a
  deterministic fuzz pass over the four text parsers. Filesystem tests use a temporary
  tree (`scan`, `icon`, `mime`), inheritance cycles (self, two-way, three-way), invalid
  UTF-8, a Link without `URL`, and a file over the size cap.
- Compile-only: `tools/check.sh bleu_core bleu_xdg bleu_plist` clean on all six targets.
- Sources and citations: `docs/research/bleu_xdg.md`.
