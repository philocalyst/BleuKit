# bleu_plist

Apple property lists for Bleu: one owned value tree read from XML (including
UTF-16 XML), binary `bplist00`, and a typed model of an application bundle's
`Info.plist` with its localised names.

Module root `bleu::plist`. Depends on `bleu_core` (the error vocabulary).

## Public API

- `plist`: `read(allocator, bytes)` detects binary, UTF-16 XML and UTF-8 XML → `Value`; `read_limited(allocator, bytes, max_decoded_bytes)` sets the budget for a binary file.
- `value`: `Value` (a tagged struct: `kind`, `text`, `integer`, `real`, `date`, `bytes`, `items`, `members`), `Kind`, `Member`; accessors `get`, `element`, `as_string`, `as_integer`, `as_real`, `as_bool`, `as_date`, `as_data` (all `NOT_FOUND` when absent or of another kind); `parse_date`, `format_date` (ISO 8601 ↔ CFAbsoluteTime); `canonical` (stable one-line form used by the golden tests; returns `PROTOCOL` for a string that is not UTF-8 instead of aborting). `DEFAULT_MAX_DECODED_BYTES` (64 MiB) is the default budget.
- `xml`: `parse(allocator, text)`, `write(allocator, root)`.
- `binary`: `parse(allocator, bytes)` (default budget) and `parse_limited(allocator, bytes, max_decoded_bytes)`. The budget counts the struct of every decoded value and the bytes of every string and data run (a UTF-16 string at its worst-case UTF-8 size), and a shared object is charged at each reference, so a 1 MiB file cannot decode to more than the budget.
- `text`: `decode_at` (one UTF-8 code point, RFC 3629) and `check_utf8`.
- `text`: `append_utf8`, `utf16_to_utf8`, `from_utf16_with_mark`, `has_utf16_mark`.
- `app_bundle`: `read(allocator, bundle_path, languages)` (`Info.plist` and `InfoPlist.strings` are capped at 1 MiB, and a language that holds a separator or `..` is not looked up) → `AppBundle` (identifier, names with `InfoPlist.strings` lookup, executable, icon names, version, category, `LSUIElement`, `LSBackgroundOnly`, `UrlType[]`); `applications_directories(home, allocator)`; `bundle_paths(home, allocator)`.

Ownership: every string, array and byte run of a `Value` is allocated from the
allocator passed to the reader; freeing that allocator frees the tree. Scratch memory
comes from `tmem`, so call the readers inside a `@pool()` in loops.

## Not done

- Binary writer. The XML writer is done.
- Old-style OpenStep text plists (`{ key = value; }`), which `InfoPlist.strings` files
  sometimes use. They are refused as malformed, not parsed.
- XML writer: UIDs are refused (Apple's serializer silently drops them); dates have
  no fractional seconds.
- Sets (0xC0) are read as arrays, in stored order.
- Bundle icons are named, not read or decoded. Flat (iOS-style) bundles are not recognised.

## Verification

- Golden: `fixtures/*.plist`, `*.bplist`, `*.strings` are written by Python's `plistlib`
  (`fixtures/generate.py`). Each `.canon` file is the canonical text of what `plistlib`
  decodes. The XML and binary readers must reproduce it exactly, which covers escapes,
  CDATA, comments, UTF-16 surrogates, 1- and 2-byte references, extended lengths, dates,
  reals and UIDs.
- Run: 48 unit tests for this library (`compile-test libs/bleu_plist.c3l/src/*_test.c3`
  with `--lib bleu_core --lib bleu_plist`), including hand-built binary files for every
  marker, every refusal (trailer length, offsets, self reference, nesting, size bomb),
  shared-blob budget cases (a 1 MiB blob referenced 100 times is refused by default),
  UTF-8 and XML character-reference refusals (surrogate and control references),
  and a fuzz pass: every prefix of every fixture, plus 4000 seeded random corruptions.
- Compile-only: `tools/check.sh bleu_core bleu_xdg bleu_plist` clean on all six targets.
- Sources and citations: `docs/research/bleu_plist.md`.
