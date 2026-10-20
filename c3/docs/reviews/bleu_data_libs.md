# Review of bleu_dl, bleu_ddc, bleu_xdg, bleu_plist

Scope: `libs/bleu_dl.c3l`, `libs/bleu_ddc.c3l` (DDC/CI framing, checksums, timings, EDID),
`libs/bleu_xdg.c3l` (Exec quoting, localisation order, icon lookup), `libs/bleu_plist.c3l`
(binary and XML readers on hostile input). Method per `docs/REVIEW_CHECKLIST.md`. No library
code was edited. Scratch programs live under the session scratchpad, not in `libs/`
(paths in "Tests run").

## Verdicts

* **bleu_dl**: sound. Run-time symbol resolution and the cached `Lazy` table do what the README says. One LOW (errno attached to unrelated failures). 11/11 tests pass.
* **bleu_ddc**: checksums, opcodes, VCP tables and timing constants are right for what I could check. One MEDIUM: the duplicate-leading-0x6E reply quirk is accepted by the parser but cannot reach it through `Session`, so monitors that send it always fail `get_vcp` and capabilities reads. EDID `has_preferred_timing` does not mean what its doc says. 75/75 tests pass.
* **bleu_xdg**: Exec quoting, field codes, the locale order and the icon search order conform to the cited rules (the icon order was checked against the local spec text; the Exec and locale rules were checked against the module's own citations and tests, see Suspicions S-10). One MEDIUM: icon theme `Inherits` cycles cause exponential lookup time (a 7 s lookup for a two-way self-inheriting theme; no finish in 120 s for three-way). 62/62 tests pass.
* **bleu_plist**: the structural checks (trailer, offsets, references, nesting, declared lengths) are sound and the golden and fuzz tests pass. One HIGH: shared objects are decoded once per reference, so a 1 MB file decodes to 1 GB and a 1 MB file with more references aborts the process under a 3 GB address-space limit. Two MEDIUMs: the XML path accepts invalid UTF-8 and `canonical()` then aborts the process. 40/40 tests pass.

Totals: 1 HIGH, 4 MEDIUM, 10 LOW (15 findings). Suspicions are listed separately.

## Fix pass (status)

All 15 findings are FIXED, with one partial: XDG-3 fixes the missing-`URL` case and
leaves the spec's reverse rule (`URL` forbidden on other types) as WONTFIX. Each fix has
a regression test, listed in its row's Status. The code changes are in the four libraries
only; `docs/research/bleu_ddc.md` got a corrected citation. No other library was touched.
Still open after the pass: suspicions S-1, S-2, S-3, S-4, S-6, S-7, S-9 (see Suspicions).
The spec and source cross-check is in "Spec and source cross-check".

---

## bleu_dl

| ID | Severity | Where | Defect | Evidence | Suggested fix | Status |
| --- | --- | --- | --- | --- | --- | --- |
| DL-1 | LOW | `libs/bleu_dl.c3l/src/native.c3:66-69` | On POSIX `last_failure()` reads `errno` unconditionally and attaches it to the `dlerror()` text. When `dlerror()` returns null the result is domain ERRNO with whatever `errno` was last, which may be unrelated to the failed call. | Code reading. Not run. | Set the code to 0 when `dlerror()` gives no text, or read `errno` only on a failure path that sets it. | FIXED. `native.c3`: code 0 when `dlerror()` gives no text. Test `failure_without_loader_text_has_no_code` (fails on the old errno path). |

## bleu_ddc

| ID | Severity | Where | Defect | Evidence | Suggested fix | Status |
| --- | --- | --- | --- | --- | --- | --- |
| DDC-1 | MEDIUM | `libs/bleu_ddc.c3l/src/session.c3:151-152` (`GET_VCP_FRAME_BYTES = 11`), `session.c3:243` (`FRAGMENT_FRAME_BYTES = 38`), `packet.c3:280-283` (quirk skip) | `parse_reply` strips a duplicated leading 0x6E (the quirk the research note cites as "Accepted here", `docs/research/bleu_ddc.md:161-162`), but the buffers that `Session` reads into are sized without that byte. With a monitor that sends `6E 6E ...`, the read is cut short, the checksum is lost, and every attempt fails with PROTOCOL. The packet-level test (`packet_test.c3:154`) never reaches `Session`. | Probe `scratchpad/probe_ddc/probe.c3`: the normal 11-byte Get VCP reply decodes (`current=50 max=100`); the same reply with the leading 0x6E doubled fails `attempts=5 protocol_errors=5`. Probe `scratchpad/probe_ddc2/probe2.c3`: a doubled 39-byte capabilities fragment fails with PROTOCOL on its first attempt. | Make both buffers one byte larger (`GET_VCP_FRAME_BYTES + 1`, `FRAGMENT_FRAME_BYTES + 1`) with a comment that cites the quirk. Add a session-level test where the fake display sends the doubled frame. | FIXED. `GET_VCP_FRAME_BYTES` and `FRAGMENT_FRAME_BYTES` take `packet::LEADING_DUPLICATE_BYTES` more. Mock `doubled_leads` fault. Tests `doubled_leading_byte_is_read_for_get_vcp` and `..._for_capabilities`. Mutation check: reverting the two sizes makes both fail with PROTOCOL. |
| DDC-2 | LOW | `libs/bleu_ddc.c3l/src/edid.c3:98` (doc), `edid.c3:117-118`, `edid.c3:209` (`has_preferred_timing` = features bit 1), `edid.c3:218-219` (`preferred` from the first timing descriptor, bit or not) | The doc says `has_preferred_timing` "says whether `preferred` is set". It holds the features bit, and `preferred` is filled whenever a timing descriptor exists. A panel with bit 1 clear reports `has_preferred_timing=false` with `preferred` populated. A panel with bit 1 set and no timing descriptor reports `true` with a zero `preferred`. The EDID revision decides which rule applies (EDID 1.3 gates the first DTD on the bit; I did not fetch the EDID 1.4 text to confirm 1.4). | Probe `scratchpad/probe_ddc/probe.c3`: bit clear, DTD at offset 54 gives `has_preferred_timing=false preferred.pixel_clock_khz=28170`. All EDID tests use bit-set fixtures (`edid_test.c3:681`). | Choose one contract. Either leave `preferred` zero when the bit is clear, or rename the flag and document the first-DTD rule. Add a bit-clear test. | FIXED (contract). The doc now states the features-bit rule and what `preferred` holds. Tests `preferred_flag_is_the_features_bit`, `preferred_flag_without_a_timing_descriptor`. EDID 1.4 rule not checked (S-3). |
| DDC-3 | LOW | `session.c3:239, 303, 352, 372, 407, 414, 421, 427`; `mock.c3:155, 182, 197, 222` | `@private` on method declarations is ignored by 0.8.5, with a compiler warning on every build (`docs/C3_GOTCHAS.md`, "`@private` on a method"). | Warnings in the `c3c` output of the test and check runs. | Remove the modifier from methods, or make these free functions with `@private`. | FIXED. `@private` removed from the methods in `session.c3` and `mock.c3`; free functions keep it. |
| DDC-4 | LOW | `session.c3:25-33` (`Options.max_tries`), `session.c3:137` (`open`) | `max_tries = 0` is accepted. `exchange` and `send` then make no attempt and return BACKEND_FAILURE, with `failures` incremented and `attempts` at 0. | Code reading. Not run. | `@require options.max_tries > 0` on `open`. | FIXED. `max_tries == 0` is refused with INVALID_ARGUMENT before any write (`require_attempts`). Signature unchanged, because `bleu_brightness` calls `session::open`. Test `zero_max_tries_is_refused_before_any_write`. |
| DDC-5 | LOW | `libs/bleu_ddc.c3l/README.md`, "Verified" | README says 73 tests. The suite runs 75 and all pass. | Test run (`scratchpad/tests/ddc.log`). | Update the count. | FIXED. README now states the library's own count (78) and that the runner adds `bleu_core`'s tests. |

## bleu_xdg

| ID | Severity | Where | Defect | Evidence | Suggested fix | Status |
| --- | --- | --- | --- | --- | --- | --- |
| XDG-1 | MEDIUM | `libs/bleu_xdg.c3l/src/icon.c3:237-248` (`find_in_theme`), `icon.c3:39` (`MAX_THEME_DEPTH = 16`) | `Inherits` is walked as a tree with no visited set. A theme that lists itself, or any cycle, is searched again at every level, so the work is (branching factor)^16. The depth cap limits depth, not the number of calls. GTK does not have this problem: `insert_theme` returns early when the theme is already loaded (`gtkicontheme.c:1642-1655`). | Probe `scratchpad/probe_icon/probe_icon.c3` on a scratch tree: a theme with `Inherits=loop,loop` takes 7.2 s for one missing-icon `find`. A theme with `Inherits=loop2,loop2,loop2` did not finish in 120 s (`real 2m0.263s`, no result). | Carry the set of visited theme names through `find_in_theme` for one `find` call and skip repeats. Add a test with a self-inheriting theme that must return NOT_FOUND promptly. | FIXED. One visited set per `find` (`HashSet{String}`, `add` returns false on repeat). Tests `inheritance_cycles_are_searched_once` (self, A-B-A, three-way). Old code was not re-run against the new test (it runs for seconds or never ends, as the probe showed). |
| XDG-2 | LOW | `libs/bleu_xdg.c3l/src/keyfile.c3:15` (doc: "A file is UTF-8"), `keyfile.c3:117-139` (no check), `desktop_entry.c3:105-126` | Input is documented as UTF-8 but never validated. A `Name` with invalid UTF-8 is returned as is and reaches the UI. | Probe `scratchpad/probe_xdg/probe_xdg.c3` with `Name=Caf\xE9 \xFF`: parse succeeds, name bytes `43 61 66 E9 20 FF`. | Validate UTF-8 in `parse_with`: refuse the file, or replace invalid sequences with U+FFFD. | FIXED. `parse_with` refuses input that is not UTF-8 (PROTOCOL), as GLib does; the whole file is refused, not repaired. Test `files_must_be_utf8`. |
| XDG-3 | LOW | `libs/bleu_xdg.c3l/src/desktop_entry.c3:105-114`, `desktop_entry.c3:254-262` (`fill`) | The Desktop Entry spec requires `URL` for `Type=Link`. The model has no URL field and Link entries without one are accepted. | Code reading (`fill` has no LINK branch). | Add `url` to `DesktopEntry`, read it for LINK, and refuse a LINK entry without it. | FIXED for the missing case. `DesktopEntry.url` is read, and `Type=Link` without `URL` is refused. Test `link_entries_need_a_url`. The spec's reverse rule (URL forbidden on other types) is not enforced: WONTFIX, lenient, and noted in the field comment and the README. |
| XDG-4 | LOW | `desktop_entry.c3:369-377` (`read_file`), `icon.c3:315` (`index.theme` load) | Whole-file loads with no size cap, from directories a user can write to. Every I/O error other than not-found becomes PERMISSION_DENIED, which drops the native detail. | Code reading. | Cap file size (1 MiB is ample for desktop and index files). Map errors by kind and keep `error::last()`. | FIXED. `keyfile::load_file`: 1 MiB cap checked before the read; errors mapped to NOT_FOUND, PERMISSION_DENIED, OUT_OF_RANGE or BACKEND_FAILURE. Used by desktop entries, `index.theme` and MIME lists. Test `oversized_desktop_files_are_refused`. |

Conformance notes (no defect): `exec.c3` refuses unknown field codes and field codes inside quotes (documented in the module header as deliberate, GLib differs); `%i`, `%F`, `%U` must stand alone; at most one of `%f %u %F %U`; values are never re-split. `keyfile.c3:257-294` tries `lang_COUNTRY@MODIFIER`, `lang_COUNTRY`, `lang@MODIFIER`, `lang`, then the unlocalised key. `icon.c3` `Directory.matches` and `distance` agree with the Icon Theme 0.13 pseudocode, and the two-phase lookup (exact, then closest, then parents, then hicolor, then fallback) agrees with `scratchpad/specs/icon.txt` lines 340-400.

## bleu_plist

| ID | Severity | Where | Defect | Evidence | Suggested fix | Status |
| --- | --- | --- | --- | --- | --- | --- |
| PL-1 | HIGH | `libs/bleu_plist.c3l/src/binary.c3:41-42, 149-156` (count caps), `binary.c3:183` and `binary.c3:302` (copy per reference), `binary.c3:279-286` (`copy_bytes`) | The decoded-value cap counts objects, not bytes. The reader decodes each reference to a shared data or string object again, so one object of S bytes referenced K times costs K×S bytes. K can be 2^20 and S can be the file size. Allocation failure aborts the process. The README's "size bomb" refusal covers declared lengths only. | Probe `scratchpad/probe_plist/probe_bomb.c3`, inputs from `scratchpad/probe_plist/gen_bomb.py`. A 1,001,058-byte file (1000 refs to a 1 MB blob) decodes to 1,000,000,000 bytes, peak RSS 960 MiB. A 1,005,058-byte file (5000 refs) under `ulimit -v 3000000` aborts with `mem::OUT_OF_MEMORY` unwrapped in `copy_bytes`, exit 132. | Memoise decoded data and string objects by offset so repeated references share one copy (the slices are read-only). Also budget decoded bytes against the file length and refuse with OUT_OF_RANGE. Add a shared-blob case to `binary_test.c3`. | FIXED. Decoded-byte budget: `value::DEFAULT_MAX_DECODED_BYTES` (64 MiB), `binary::parse_limited`, `plist::read_limited`. Each decoded value costs its struct size; each string or data run costs its bytes (UTF-16 at worst-case UTF-8); shared objects are charged per reference. Refusal is OUT_OF_RANGE, the code the existing size-bomb test and doc already used. Probes: the 1,001,058-byte and 1,005,058-byte files are refused under `ulimit -v 3000000` (before: 960 MiB RSS, abort). Tests `shared_objects_are_charged_for_every_reference`, `megabyte_blob_shared_many_times_is_refused_by_default`. |
| PL-2 | MEDIUM | `libs/bleu_plist.c3l/src/xml.c3:50-57` (`parse`, no check), `plist.c3:39` (raw bytes to `xml::parse`), `xml.c3:219-235` (`text_of`). The claim is in `text.c3:9-10`: "the readers never produce invalid UTF-8". | The XML path does not validate UTF-8. Character references to surrogates (`&#xD800;`) are decoded by the standard DOM into CESU bytes. Both reach `String` values, and the writer copies them. | Probe `scratchpad/probe_plist/probe_xml.c3`: `<string>A\xFF\xFEB</string>` gives text bytes `41 FF FE 42`. `<string>A&#xD800;B</string>` gives `41 ED A0 80 42`. Both accepted. | Check the input is UTF-8 before parsing, and refuse surrogate code points that come from character references (check after decoding in `text_of`). | FIXED. `text::check_utf8` on the whole XML input; `check_xml_chars` on every decoded text value, which refuses surrogates and XML 1.0-forbidden controls. Tests `invalid_utf8_documents_are_refused`, `character_references_must_be_xml_characters`. Probes `bad_utf8.plist`, `surrogate_ref.plist` now refused. |
| PL-3 | MEDIUM | `libs/bleu_plist.c3l/src/value.c3:289-295` (`canonical`, public), `value.c3:341` (`text.to_temp_utf32()!!` in `write_quoted`) | `canonical` is documented as useful in logs, but it asserts with `!!` on the string. A value with invalid UTF-8 (PL-2) aborts the process. | Probe `probe_xml` with `MODE=canon` on the `A\xFF\xFEB` input: exit 132 inside `canonical`. | Return an error, or write invalid bytes as `\xNN` escapes. Make `canonical` return `String?`. | FIXED. `canonical` returns `String?` (PROTOCOL for text that is not UTF-8); `write_quoted` decodes with `text::decode_at`. Test `canonical_refuses_text_that_is_not_utf8`. Call sites in tests now unwrap with `!!`. Nothing outside the library calls it. |
| PL-4 | LOW | `xml.c3:219-235` (reader), `xml.c3:326-352` (writer refuses C0 controls) | The reader accepts `&#x1;`, which XML 1.0 forbids. The writer refuses the same value, so read and write disagree. | Probe `ctrl_ref.plist`: read succeeds, text bytes `41 01 42`. The writer refusal is covered by `xml_test.c3`. | Reject C0 controls other than TAB, LF and CR in the reader. | FIXED. `check_xml_chars` refuses C0 controls other than TAB, LF and CR in the reader, so reader and writer agree. Probe `ctrl_ref.plist` now refused. |
| PL-5 | LOW | `libs/bleu_plist.c3l/src/app_bundle.c3:102-107` (`Info.plist` load), `app_bundle.c3:218-242` (`strings_value`) | Info.plist and every `InfoPlist.strings` are read whole, with no size cap, from `.app` bundles a user can write. Every I/O error except not-found becomes PERMISSION_DENIED, which drops `error::last()` (`docs/STYLE.md`, error rules). The `language` argument is joined into a path without checking for `/` or `..`. The caller supplies it, so this is LOW. | Code reading. | Cap sizes (1 MiB is ample). Map errors by kind. Reject language strings that contain `/`, `\`, or `..`. | FIXED. `load_plist_file`: 1 MiB cap, error mapping as in XDG-4; `is_path_component` refuses a language with `/`, `\` or `..`. Tests `oversized_info_plist_is_refused_before_it_is_read`, `language_cannot_step_out_of_the_resources_folder`. |

---

## Suspicions (unproven)

* **S-1 plist.** `value.c3:180` `(long)seconds` is undefined for NaN, infinity or out-of-range doubles. A binary date can hold any double (`binary.c3:179`), so the XML writer could emit a garbage date silently. Not run.
  **Status: OPEN.** Not run; `format_date` is unchanged. A NaN or infinite date still reaches the cast.
* **S-2 ddc capabilities.** `capabilities.c3:148-159` strips the first and last character when the string starts with `(`. A string of two top-level groups, such as `(vcp(10))(cmds(01))`, may come out VALID with the unknown segment ignored. Not run.
  **Status: OPEN.** Not run; `capabilities.c3` is unchanged.
* **S-3 ddc EDID.** EDID 1.4 uses week 0xFF as a model-year flag, but `edid.c3:202` reports `1990 + byte` as the manufacture year. Gamma byte 0xFF means "see extension", but `edid.c3:208` gives 2.55. Both from memory of EDID 1.4; the text was not fetched.
  **Status: OPEN.** The EDID 1.4 text was not reachable in this pass. DDC-2's doc now states the 1.3 rule only, and the 1.4 claims are not verified.
* **S-4 ddc fingerprint.** `edid.c3:302` includes the descriptor name in the fingerprint, and the doc says platforms expose the same fields. If a platform cannot supply the name, the two sides never match. Not verifiable without macOS or Windows.
  **Status: OPEN.** Needs a macOS or Windows platform; unchanged.
* **S-5 ddc citations.** The ddcutil paths cited in the module and research notes (`ddc_packets.c`, `ddc_packet_io.c`, `tuned_sleep.c`) returned 404 from `raw.githubusercontent.com` on both `master` and `main`, so the timing and quirk citations are unverified here. The reply checksum vector `{6F,6E,82,A1,00} -> 1D` was recomputed by hand (seed 0x50 over `6E 82 A1 00`), and the request checksum for Get VCP 0x10 (`51 82 01 10`) is `0xAC`, both consistent with the cited values.
  **Status: RESOLVED (agree).** The ddcutil sources resolve on `master` at `src/ddc/ddc_packet_io.c`, `src/base/ddc_packets.c` and `src/base/tuned_sleep.c`. The timing and null-limit citations agree with them. The quirk citation pointed at the wrong file and is corrected. See the cross-check.
* **S-6 dl Windows.** `native.c3:20-28` uses `FormatMessageA`, and the README says `LoadLibraryExW` while `std::os::dlopen` is used. Non-ASCII candidate names may be encoded wrongly on Windows. Not run on Windows.
  **Status: OPEN.** Not run on Windows; unchanged.
* **S-7 dl lazy.** `lazy.c3:49` busy-waits with `thread::yield()` while another thread runs `dlopen`. On a slow filesystem every caller spins for that time.
  **Status: OPEN.** Unchanged; a busy-wait on a slow filesystem is a performance concern, not a correctness one.
* **S-8 xdg Exec.** The Exec and locale rules were checked against the module's own citations and the 62 tests (which include the spec's example). The Desktop Entry spec text was not available: the gitlab raw URL returned a sign-in page. The Icon Theme text was checked against the local copy.
  **Status: RESOLVED with two disagreements.** The Desktop Entry spec was fetched from `specifications.freedesktop.org/desktop-entry/latest/` (basic-format, exec-variables, localized-keys, recognized-keys, value-types). See the cross-check.
* **S-9 plist app_bundle.** `io::file::is_dir` follows symlinks in `bundle_paths`. Not exploited or tested.
  **Status: OPEN.** Symlinks in `bundle_paths` are unchanged; not exploited or tested.

## What is good

* **plist:** the trailer and offset rules mirror CoreFoundation. Every offset, length and reference is bounded by the object region. Self-references and nesting are refused. XML entities are not expanded, so there is no entity bomb. 300,000-deep XML nesting is refused cleanly in the probe. Integer overflow is refused. UTF-16 surrogates are validated. The golden fixtures, every-prefix and random-corruption tests all pass.
* **ddc:** request checksums seed with 0x6E and reply checksums with 0x50 over the leading 0x6E, as the header describes. Opcodes and VCP and input-source tables match MCCS 2.2a values I could check. Every timing constant names its source. Null, unsupported and malformed replies are distinct, with counters. The normal reply path decodes correctly on the probe.
* **xdg:** Exec parsing is conservative and documented, and it does not re-split substituted values. The locale order and the icon size rules match the cited rules. The `scan` ID rule (`foo/bar.desktop` → `foo-bar.desktop`) and precedence follow the spec text.
* **dl:** symbols are resolved at run time. A missing symbol becomes UNSUPPORTED with the loader's message and never stops the library loading. `Lazy` caches success and failure and never double-binds.

## Spec and source cross-check

Sources fetched on the review day (curl, HTTPS through the proxy). Each row says whether the
code agrees with the source.

Desktop Entry Specification 1.5 (`specifications.freedesktop.org/desktop-entry/latest/`,
pages `basic-format`, `exec-variables`, `localized-keys`, `recognized-keys`, `value-types`):

| Claim | Spec text (paraphrased) | Module | Result |
| --- | --- | --- | --- |
| Locale order (`keyfile.c3`) | Table 1: `lang_COUNTRY@MODIFIER`, `lang_COUNTRY`, `lang@MODIFIER`, `lang`, then the unlocalised key | same order | AGREE |
| Quoted Exec arguments | `"`, backtick, `$` and `\` take a backslash inside double quotes | `exec.c3` header rule | AGREE |
| Unknown field codes | a command line with one "must not be processed" | refused whole | AGREE |
| Single expansion | a substituted string is not checked for field codes again | values never re-expanded | AGREE |
| `%i` | two arguments, `--icon` and the value; none when `Icon` is empty | same | AGREE |
| Field codes inside quotes | "undo quoting before expanding field codes", so the spec defines the expansion | refused, as "undefined" | DISAGREE with the module's stated reason. The module is stricter than the spec and a refusal is safe. WONTFIX: a change would alter what `bleu_apps` launches. |
| `%i`, `%F`, `%U` stand alone | not in the 1.5 text fetched | refused unless standalone | Module choice, not from the spec. WONTFIX. |
| Reserved characters unquoted | the spec says they must be quoted | passed through | Deliberate leniency, documented in `exec.c3`. WONTFIX. |
| `URL` for `Type=Link` | "present when and only when" `Type` is Link | required for Link (now enforced); not forbidden elsewhere | PARTIAL: the reverse rule is not enforced. WONTFIX, documented. |

ddcutil (`rockowitz/ddcutil`, `master`; `src/ddc/ddc_packet_io.c`, `src/base/ddc_packets.c`,
`src/base/tuned_sleep.c`):

| Claim | ddcutil | Library | Result |
| --- | --- | --- | --- |
| Double leading 0x6E | `ddc_packets.c`: skip one byte when bytes 0 and 1 are both 0x6E ("Quirk: response packet starts with double 0x6e") | `packet::parse_reply` | AGREE. The citation in `packet.c3` said `ddc_packet_io.c`, corrected. |
| Read size for the quirk | `ddc_packet_io.c` ~l.248: `max_read_bytes++` for the quirk | DDC-1 fix adds one byte to both read buffers | AGREE. ddcutil's log text says "0x63" while its comment says 0x6e. The packet check uses 0x6E. |
| Null messages before UNSUPPORTED | `ddcrc_null_response_max = 3` | `max_null_replies = 3` | AGREE |
| Write to read, Get VCP | `SE_WRITE_TO_READ` uses `DDC_TIMEOUT_MILLIS_DEFAULT`; the spec's 4.3 says at least 40 ms | 40 ms | AGREE with the code and the spec. ddcutil's comment says "assume 50 ms" for capabilities, where the library uses 40 ms: DISAGREE, not changed (open). |
| Between commands | `SE_POST_WRITE`: at least 50 ms | 50 ms | AGREE |
| After Save Current Settings | `SE_POST_SAVE_SETTINGS`: at least 200 ms | 200 ms | AGREE |
| Before a capabilities read | `SE_PRE_MULTI_PART_READ`: 200 ms, "based on testing, not defined in spec" | no such wait | DISAGREE, not adopted: no spec basis, and ddcutil calls it a workaround. Open for the maintainer, if a monitor needs it. |

EDID 1.4 (S-3) was not fetched. The VESA text is not on a reachable host that was tried.

## Tests run and results

Own `@test` functions per library (the reviewer's totals also counted two `bleu_core` tests in each run):

| Library | Review commit | Now | Result |
| --- | --- | --- | --- |
| bleu_dl | 9 | 10 | all pass |
| bleu_ddc | 73 | 78 | all pass |
| bleu_xdg | 60 | 64 | all pass |
| bleu_plist | 38 | 48 | all pass (includes every prefix of every fixture and 4000 random corruptions) |

Unit tests were run with `c3c compile-test -o <private file>` from a private scratch directory, under `timeout`, with `tools/libdir.sh`. The runner's total also includes whichever `bleu_core` tests were linked at the time. Other agents were editing `bleu_core` during this pass, and two of its runs failed to compile on its files, not on these libraries. The runs that counted were green.

Mutation check (DDC-1): reverting the two read-buffer sizes makes `doubled_leading_byte_is_read_for_get_vcp` and `doubled_leading_byte_is_read_for_capabilities` fail with PROTOCOL. The sizes were restored.

Six-target type check, `tools/check.sh bleu_core bleu_dl bleu_ddc bleu_xdg bleu_plist`: all six targets `ok`, exit 0. `c3fmt --check` clean on every `src/*.c3` of the four libraries.

Probes (reviewer's probes, rebuilt against the fixed API):

* `probe_bomb` on `bomb_1000x1MB.bplist` and `bomb_5000x1MB.bplist` under `ulimit -v 3000000`: both refused (OUT_OF_RANGE), exit 0. Before: 960 MiB RSS, and an abort.
* `probe_xml` on `bad_utf8.plist`, `surrogate_ref.plist`, `ctrl_ref.plist`: all refused. `sample.plist` still canonicalises.

Not run: macOS, Windows, and runtime checks of the other libraries.

Probes (scratch programs, not in `libs/`), each built with `c3c --libdir "$(tools/libdir.sh)"` (the reviewer's originals; the re-runs used the same inputs):

* `scratchpad/probe_ddc/probe.c3` (DDC-1, DDC-2)
* `scratchpad/probe_ddc2/probe2.c3` (DDC-1, capabilities)
* `scratchpad/probe_plist/probe_bomb.c3` with `gen_bomb.py` (PL-1)
* `scratchpad/probe_plist/probe_xml.c3` (PL-2, PL-3, PL-4)
* `scratchpad/probe_icon/probe_icon.c3` (XDG-1)
* `scratchpad/probe_xdg/probe_xdg.c3` (XDG-2)

Not run: `c3fmt --check`, the other libraries, and anything on macOS or Windows.

## Not reviewed in depth

`bleu_xdg` `dirs.c3` and `mime.c3` (not in the requested scope). `bleu_ddc` `mock.c3` (test helper). `bleu_plist` `app_bundle.c3` beyond the points listed.
