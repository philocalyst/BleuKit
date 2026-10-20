# bleu_json: sources, cross-checks and decisions

This note backs `libs/bleu_json.c3l/`. Each claim the code relies on names its source
and how it was checked. Where a claim rests on one source only, it says so.

## 1. What the consumers need

- The daemons speak line-JSON: one request or reply per line, `{"id":N,...}`
  (`libs/bleu_json.c3l/src/envelope.c3`).
- A shell (DankMaterialShell port) reads state as JSON, with Go-style field tags
  (`@tag("json", ...)`) for renames, omission and hiding.
- Requests are loosely typed: a JavaScript peer may send `3.0` for an integer.

## 2. Standards the output must satisfy

| Claim used | Source (checked copy) | Cross-check |
| --- | --- | --- |
| Strings must escape `"`, `\` and U+0000..U+001F | RFC 8259 section 7, lines 428-431 | Python `json.loads` accepts only what the grammar allows (strict mode), and the fuzz oracle reads every output line back |
| `\uXXXX` escapes use four hex digits; `\b \f \n \r \t` are the short forms | RFC 8259 section 7, lines 442-464 | the fuzz oracle; unit test `control_characters_and_quotes_are_escaped` |
| NaN and infinities are not JSON numbers | RFC 8259 section 6, line 378 | fuzz oracle (`null` for non-finite) |
| Number grammar: no leading zeros, optional fraction and exponent | RFC 8259 section 6, lines 362-376 | fuzz oracle with `json.loads` on every number |
| UTF-8 well-formedness table (C2-DF; E0 A0-BF; E1-EC; ED 80-9F; EE-EF; F0 90-BF; F1-F3; F4 80-8F) | RFC 3629 section 4, lines 265-290 | `utf8_unit` implements it table for table; Python's UTF-8 codec (the Unicode table) is the fuzz oracle |
| Replacement of each maximal invalid subpart by U+FFFD | Unicode Standard section 3.9 (U+FFFD substitution) | Python `bytes.decode('utf-8', 'replace')`: identical on 4000 random byte strings, and on the named cases in unit tests (for example `E2 82` followed by `z`) |
| RFC 3339 form: `YYYY-MM-DDTHH:MM:SS[.frac]Z`; fraction digits optional | RFC 3339 section 5.6 ABNF, lines 413-422 (`time-secfrac = "." 1*DIGIT`, `time-offset = "Z"`) | unit tests: epoch, 1969-12-31, 2000-02-29 and sub-second fractions by epoch arithmetic; the 2026 instant was computed with Python `datetime`; year 10000 refused |
| Base64: standard alphabet, padding with `=` | RFC 4648 section 4, Table 1 (line 302) | unit test vectors `""`, `f`, `fo`, `foo`; the services golden contains `Home` as `SG9tZQ==` |
| Shortest round-trip double: the fewest significant digits whose parse is the same double | ECMAScript Number::toString and IEEE 754 binary64 (one source only, not fetched) | the fuzz oracle recomputes the shortest `%.Ng` in Python and compares the text exactly; 4000 doubles, 4000 floats |

Two-source rule: the UTF-8 table and the escaping rules each have an RFC plus an
executed reference (Python). The shortest-float rule is verified by an executed oracle
only (single-source in the text sense: the rule is definitional).

## 3. Standard library findings (why we build on top of it)

Checked by reading `/opt/c3/c3/lib/std/encoding/json_marshal.c3` and by running
`json::marshal` on the same values:

- `serialize_float` writes `%.17g` (json_marshal.c3 line 344). `0.7f` marshals as
  `0.69999998807910...`, and `0.1` as `0.10000000000000001`: correct but not shortest.
- `serialize_string` escapes only `"`, `\` and bytes below 0x20 (lines 536-...) and copies
  every other byte. A string holding `FF 80` marshals as those raw bytes, which is not
  valid JSON text (verified on output).
- `serialize_float` rejects NaN and infinities with `INVALID_NUMBER` (line 343), so `marshal`
  fails on any snapshot with an unknown measurement. Bleu writes `null` instead.
- The DOM `Object.get` checks only for the empty type before reading the map union
  (`collections/object.c3`, `get` at line 323). Calling it on an array reads garbage, so
  `read::present` checks `is_map()` first.
- `json::max_depth` is a global (`encoding/json.c3` line 7), so the parser's nesting bound
  is 64 for every caller.

Decision: `bleu::json` keeps std's `Object` DOM and strict parser for requests, and writes
output itself. It does not use `marshal`.

## 4. C3 0.8.5 facts verified while building this

Each was run against `c3c 0.8.5_1`:

- Compile-time string concatenation exists: `$error "not plain data at " +++ $path +++ "." +++ $member.name;`
  produces the message `not plain data at value.inner.ptr`. This is how member paths are
  reported (the manual, section "Concatenation").
- `$error $member.name;` alone prints the member's name; two `$error`s in one branch stop at the first.
- `$warning` does not exist. `$else` takes no colon. `$elif` does not exist.
- `@expect_fault`-style macros with expression parameters need the `@` prefix
  (`macro @name(#expr, ...)`).
- A type declared inside a function is a parse error; a struct literal needs a cast:
  `(Caps){ .charge = true }`.
- `$Type::members` gives `.name`, `.type` and `has_tag` / `get_tag` for `@tag`; `&&&` and `|||`
  are compile-time short-circuit operators; `$Type::kind`, `$Type::size`, `$Type::inner` work.
- `$Type.nameof` does not exist, and types have no runtime name: `Maybe` is recognised by shape.
- `enum.description` is the member's name; `enum.ordinal` is the index.
- `constset` inside a generic body compiles through `TypeElement::inner` (checked by the gate, not run).
- A returned struct whose slices point into an array literal of the callee dangles
  (services sample, found by a `Out of bounds` crash in the serialiser; not a library bug).

## 5. Decisions

- Enum values default to lower snake case (`not_charging`), matching the snake-case keys.
  `UPPER_SNAKE` is the C3 spelling, selectable in `Options`.
- Member names default to their declared (snake) spelling; `CAMEL_CASE` is opt-in. Tag
  renames are exact and never restyled.
- `char[]` (a byte slice, for example `Ssid.bytes`) is base64. An array of up to 32 numbers is
  unreadable and not text, so this one slice rule departs from "slices are arrays". `char[N]` is text.
- `Duration` and `NanoDuration` are integers with no unit suffix: the unit is part of the
  type's documentation (`time::Duration` is microseconds). A tag can rename a key to carry a unit.
- `omitempty` omits zero values in the Go sense, with one Bleu addition: an absent `Maybe`.
- `DateTime` and `TzDateTime` are converted to UTC; `Time` is UTC microseconds since 1970.
- Requests: `id` must be an integer of magnitude at most 2^53, the largest integer a JavaScript
  number holds exactly.

## 6. Risks and cut lines

- Output floats use `%g`, so `1e+21` and `1e-07` appear. Valid JSON; a JavaScript reader parses
  them identically. A prettier spelling would need hand-written number formatting; not worth it now.
- `put_double` formats through temporary memory. A tight loop must sit in a `@pool()`.
- Member-path diagnostics depend on the `+++` operator; verified on 0.8.5_1 only, re-verify on upgrade.
- The services check needs seven other libraries on the command line; it is a `compile-run`
  program, not a unit test, because `compile-test` also runs those libraries' own tests, some of
  which need a live D-Bus.
