# bleu_plist: sources and binding decisions

Sources were fetched on 2026-10-20 from the URLs below. Line numbers refer to those
fetches (Apple open-source CoreFoundation, `main` branch of
`apple-oss-distributions/CF`, files `CFBinaryPList.c` and `CFPropertyList.c`).
"Golden" means a fixture written by Python's `plistlib` (Python 3.13.16,
`/usr/lib/python3.13/plistlib.py`) whose decoded value the library must reproduce
exactly, via the canonical form in `value.c3`. "Test" means a unit test that fails if
the rule is broken.

## 1. Value model and dates (`bleu::plist::value`)

- Eight types, dictionary keys are strings, dictionaries keep file order: Apple, "Property List
  Programming Guide"; the golden fixtures keep the order `plistlib` reports. Test: `canonical_form_is_stable`.
- Date is a CFAbsoluteTime (seconds since 2001-01-01T00:00:00Z, a double). Verified against
  `CFPropertyList.c` 1735-1766, which builds a `CFGregorianDate` and calls
  `CFGregorianDateGetAbsoluteTime`. Golden: `sample.plist` `When`, `Epoch`. Test: `dates_match_independent_calculations`
  (2013-06-22T10:18:00Z = 393589080.0, computed independently with Python).
- The civil-day conversion uses Howard Hinnant's `days_from_civil` / `civil_from_days` algorithm
  (http://howardhinnant.github.io/date_algorithms.html). That page was **not** fetched; the
  algorithm is verified only by the date tests and the golden dates, which compare against
  Python's calendar. Round trip: `dates_round_trip`.

## 2. XML (`bleu::plist::xml`)

- Header written: `<?xml version="1.0" encoding="UTF-8"?>`, the Apple DOCTYPE, `<plist version="1.0">`.
  Verified against `CFPropertyList.c` line 677 (the declaration) and the writer's
  `_CFGenerateXMLPropertyListToData`.
- `<data>` must be base64; a bad value is an error. Verified: `CFPropertyList.c` 1640.
  Test: `malformed_documents_are_refused` (`<data>@@@@</data>`).
- Dates: ISO 8601 `YYYY-MM-DDTHH:MM:SSZ`. Verified: `CFPropertyList.c` 1735-1766 parses the same
  form. Test: `malformed_dates_are_refused`.
- A one-key dictionary `{CF$UID: integer}` reads as a UID. Verified: `CFPropertyList.c` 1532-1545
  (`CFDictionaryGetValue(dict, CFSTR("CF$UID"))`, `_CFKeyedArchiverUIDCreate`). Python's
  `plistlib` does **not** do this, so no golden covers it. Test: `uid_dictionaries_read_as_uids_and_uids_are_not_written`.
- The XML serializer writes dictionaries, arrays, strings, numbers, booleans, dates and data
  (`CFPropertyList.c` 528-672). It has **no UID branch** and writes nothing for a UID.
  This writer refuses UIDs with `INVALID_ARGUMENT` instead. That is a deliberate difference.
- Reals: written with the shortest of 15, 16 or 17 significant digits that reads back exactly.
  Test: `writer_escapes_and_formats` (0.1 → `0.1`).
- Parsing: the standard library's `std::encoding::xml` (a yxml port). Probed on Linux, not from
  its source: a DOCTYPE with an internal subset is accepted; `&amp;`, `&lt;`, `&#x41;` decode;
  CDATA merges into the surrounding text; an undefined entity, mismatched tags and
  `&#0;` are rejected. Golden: `sample.plist`, `handwritten.plist` (comments, CDATA, entities,
  `&#x1F600;`, whitespace-padded `<string>`, `<dict/>`, a date, base64).

## 3. Binary (`bleu::plist::binary`)

Primary: `CFBinaryPList.c`.

| Rule | Where | Golden or test |
| --- | --- | --- |
| Header `bplist0?`; trailer is the last 32 bytes; it is checked as one unit | `__CFBinaryPlistGetTopLevelInfo`, 759-845 | `malformed_trailers_are_refused` |
| Object count ≥ 1 (782); top object < count (785); table after 8 bytes of header (788) and before the trailer (791); the file length equals `table + count*offsetSize + 32` exactly (815) | 782-815 | `malformed_trailers_are_refused` |
| Reference and offset widths must address every object / the table (821, and the reference check that follows) | 794, 821 | `malformed_trailers_are_refused` |
| Every offset must lie before the table and after the header; the top object's offset likewise (842) | 831-842 | `offsets_outside_the_file_are_refused` |
| Integer marker `0x1n` is `2^n` bytes; 16 bytes is the largest (1108) | 1084-1108 | `integers_in_every_width` |
| 1, 2 and 4-byte integers are unsigned; 8-byte signed | 1109 | `integers_in_every_width` (`0xFFFF` = 65535) |
| Real `0x22` (4-byte float) and `0x23` (8-byte double) | 1130, 1148 | `reals_and_dates` |
| Date `0x33`, 8 bytes, CFAbsoluteTime | 1168 | `reals_and_dates`, golden `sample.bplist` `When` |
| Data `0x4n`, ASCII `0x5n`, UTF-16 `0x6n` (code units) | 1190, 1216, 1243 | `ascii_strings`, `utf16_strings_use_surrogate_pairs`, golden |
| Extended length: nibble `0xF`, then an integer object | 382, 390, 469, 483 (`count < 15 ? count : 0xf`) | `ascii_strings` (`0x5F`), golden (40-character string) |
| UID `0x80 | (bytes-1)`, the value is unsigned | 366, 1280 | `data_and_uid`, golden `uid.bplist` |
| Set `0xC0` read as array | 1300 | `arrays_sets_and_dictionaries` |
| Dictionary `0xDn`: keys then values | 941, 1444 | golden `sample.bplist`, `shared.bplist` |

Differences from Apple, all deliberate: integers wider than 64 bits that do not sign-extend are
refused (Apple's comment at 1112 says "only the last 64 bits are significant currently"); the
trailer's five unused bytes are not required to be zero (the Leopard-only rule in the comment at
772); sets become arrays; duplicate dictionary keys are refused.

Limits (not in Apple's reader): at most 2^20 values per document, and nesting of 512, both
against shared-reference blow-ups. Test: `size_bombs_are_bounded`, `nesting_is_limited`.

Golden fixtures come from `plistlib.dumps(..., fmt=FMT_BINARY)`. `plistlib` writes one-byte
references for small files and two-byte references for `shared.bplist` (more than 255 objects),
so both widths are exercised. Test: `golden_binary_fixtures_match_plistlib`.

## 4. Text and encodings (`bleu::plist::text`, `bleu::plist`)

- UTF-16 surrogate arithmetic (Unicode Standard, chapter 3; https://www.unicode.org/versions/latest/).
  Checked by the golden `sample.bplist` `Unicode` value (U+1F600) and by `utf16_strings_use_surrogate_pairs`.
- UTF-16 XML (`InfoPlist-en.strings`, byte-order mark `FF FE`, declared `encoding="UTF-16"`):
  read by `plist::read`. Golden: `InfoPlist-en.strings.canon`.
- Detection: `bplist` prefix → binary; UTF-16 mark → transcode then XML; otherwise XML.
- Not done: old-style OpenStep text plists (`{ key = value; }`), described in the "Old-Style
  Property Lists" chapter of the Property List Programming Guide and implemented in
  `CFOldStylePList.c`. Refused as malformed.

## 5. Application bundles (`bleu::plist::app_bundle`)

- Keys (`CFBundleIdentifier`, `CFBundleName`, `CFBundleDisplayName`, `CFBundleExecutable`,
  `CFBundleIconFile`, `CFBundleIconName`, `CFBundleShortVersionString`,
  `LSApplicationCategoryType`, `LSUIElement`, `LSBackgroundOnly`, `CFBundleURLTypes`,
  `CFBundleURLName`, `CFBundleURLSchemes`) were written from Apple's "Information Property
  List Key Reference". That page was **not** re-fetched; the names are standard and match the
  golden `info.plist`.
- `LSUIElement` / `LSBackgroundOnly` accept the strings `1`, `YES`, `yes`, `true`, `TRUE` as
  well as a boolean. Apple's reference documents the boolean only; this is a leniency that was not
  checked against LaunchServices.
- Localization: `<lang>.lproj/InfoPlist.strings`, trying the language, its base language, then
  `Base.lproj`, as the Bundle Programming Guide describes. Test: `localized_names_follow_the_language_order`.
- Application directories: `/Applications`, `/System/Applications`, `~/Applications`,
  `/System/Applications/Utilities`, as the project brief lists them. Test:
  `application_directories_are_listed_in_search_order`.

## 6. Robustness

- `fuzz_test.c3`: every prefix of seven fixtures (each a distinct truncation), and 4000 seeded
  random corruptions of four fixtures. Every call must return. Deterministic (LCG, fixed seed).
- `VMEM_TEMP` (virtual-memory temporary allocator) was tried to catch use-after-scope; the
  probe in this session did not trap a deliberate violation, so it is not relied on as evidence.
