# bleu_json

JSON for Bleu: a streaming writer, the reflective serialiser that turns plain-data
service state into JSON with no per-type code, typed reads over a parsed request,
and the line-JSON envelope the daemons speak. It is built on std's `encoding::json`
(its `Object` DOM and strict parser) and adds what std does not do: valid output for
any input, shortest round-trip floats, Bleu's enum and tag rules, and frames written
without a tree.

Module roots: `bleu::json` (writer, serialiser), `bleu::json::read` (typed reads),
`bleu::json::envelope` (frames and requests). Depends on `bleu_core` only.

## Public API

- `JsonWriter`: `init_dstring(&w, indent)`, `init_buffer(&w, buf, indent)`; `begin_object`, `end_object`,
  `begin_array`, `end_array`, `key(name)`; `put_null`, `put_bool`, `put_int`, `put_uint`, `put_double`,
  `put_float`, `put_string`, `put_time(Time)`, `put_datetime(DateTime)`, `put_tz_datetime(TzDateTime)`,
  `put_bytes(char[])` (base64), `put_raw(fragment)` (validated); `restart`, `finish`, `written`, `is_complete`.
- `write(&w, value, options)` (macro): any plain-data value, into a writer.
- `to_json(allocator, value, options)` → `String?`: the same, as a new string.
- `Options { EnumStyle enum_style; KeyStyle key_style; }`: `LOWER_SNAKE` (default) or `UPPER_SNAKE`;
  `AS_DECLARED` (default) or `CAMEL_CASE`. `DEFAULT_OPTIONS`.
- `read::`: `get_string`, `get_int` (integral floats accepted), `get_bool`, `get_double`, `get_object`,
  `get_array`, `present`; `Params` with `string`, `integer`, `boolean`, `number`,
  `optional_string` (→ `Maybe{String}`), `int_or(key, fallback)`.
- `envelope::`: `Request { id, method, params, root }`, `parse_request(allocator, line)`, `Request.free`;
  `write_result(&w, id, value)`, `write_result_raw`, `write_error(&w, id, message)`,
  `write_event(&w, id, service, value)`, `write_event_raw`; `MAX_FRAME`.

## Rules for plain data

`write` decides the form from the type alone. Anything not in this table is a compile error.

| Type | JSON |
| --- | --- |
| `bool` | `true` / `false` |
| integers up to 64 bits | number, exact |
| `int128` and wider | compile error |
| `float`, `double` | shortest number that reads back to the same value; NaN and infinities are `null` |
| `typedef` | its underlying type: `Level`, `Gain` → float; `Duration` → integer microseconds; `NanoDuration` → integer nanoseconds; `Dbm`, `MegaHertz`, `Bytes` → integers |
| `enum` | its name as a string, spelled per `enum_style` |
| `constset` | its underlying integer |
| `bitstruct` | object of booleans; a non-bool field is a compile error |
| `struct` | object, members in declaration order |
| `Maybe{T}` | the value, or `null` when empty (recognised by its shape: members `value` and `has_value`) |
| `String` | string; invalid UTF-8 replaced by U+FFFD |
| `char[N]` | string up to the first NUL |
| `char[]` slice | base64 string: a byte slice is not text (deviation from "slices are arrays") |
| other slices, fixed arrays | array |
| pointer, union, optional, function, interface, `any`, fault, `void`, `typeid` | compile error naming the member path, e.g. `not plain data at value.inner.ptr` |

Member tags, `@tag("json", value)`:

| Tag | Effect |
| --- | --- |
| `"-"` | the member is left out |
| `"omitempty"` | left out when empty: an empty `Maybe`; an empty string, slice or text; `false`; `0`; an enum's first value |
| any other value | the exact wire name; `CAMEL_CASE` does not restyle it |

Key style: `CAMEL_CASE` drops each `_` between two characters and upper-cases the next,
so `time_to_empty` becomes `timeToEmpty`. Leading and trailing `_` are kept. Names are
limited to `NAME_CAPACITY` (128) bytes in this style.

Writer contract: every misuse (a key outside an object, a value without its key, a
second top-level value, a close of the wrong kind, an unfinished document, nesting past
`MAX_DEPTH` = 64) fails with `error::INVALID_STATE` or `OUT_OF_RANGE` at the call, and the
output is unchanged. A full fixed buffer poisons the writer.

Envelope frames are one line each, terminated by LF, and need a compact writer. A
request line is refused above `MAX_FRAME` (1 MiB) before it is parsed; its id must be an
integer of magnitude at most 2^53.

## Not done

- No reader for state: `to_json` is the only direction for plain data. Parsing into a struct
  is std's `unmarshal`, which this library does not wrap.
- Input is not checked for UTF-8. std's parser passes invalid bytes through in strings;
  only output is repaired.
- Duplicate object keys are not detected; the writer writes what it is given.
- `put_raw` validates a fragment with std's full parser, which is not streaming, and
  inherits its nesting limit of 64.
- Floats use `%g`: `1e+21` and `1e-07` are valid JSON, but not the ECMAScript spelling.
- `put_double` formats into temporary memory, so it needs a `@pool()` around a loop of calls
  (the usual Bleu rule for temporary memory).
- Member-path diagnostics put the path in the message (built with compile-time `+++`) and point
  at the `$error` line in `serialize.c3`; they do not point at the user's file.

## Verification

- Compile: `tools/check.sh bleu_core bleu_json` clean on all six targets. The gate
  `src/gate.c3` instantiates every branch of the writer, because C3 checks generic bodies only
  when instantiated.
- Unit tests (run): 43 `@test` functions over the writer state machine (every misuse), escaping and
  UTF-8 replacement (maximal subpart), integers, shortest floats, timestamps, base64, option
  spelling, reads and error key paths, request parsing, and frames. Run from a private
  directory:
  `c3c --libdir "$(tools/libdir.sh)" --lib bleu_core --lib bleu_json compile-test tools/empty.c3 -o <dir>/t`
- Service states (run): `test/services_main.c3` serialises a sample of `bleu::battery::State`,
  `bleu::brightness::State` and `bleu::network::State`, parses each line back with std's parser,
  and prints it. Its output equals `test/golden/services.txt`; `test/check_services.py` checks the
  member lists against the declarations and the value ranges, with python3's `json`.
  Build with `--lib bleu_battery --lib bleu_brightness --lib bleu_network` and their
  dependencies (`bleu_rt bleu_service bleu_dbus bleu_objc bleu_win bleu_ddc bleu_dl`) on the
  command line, not in the manifest.
- Fuzz (run): `test/fuzz_main.c3` writes 4000 random byte strings, 4000 random doubles and 4000
  random floats; `test/check_fuzz.py` checks each with python3: strings against
  `bytes.decode('utf-8', 'replace')`, numbers against the shortest `%.Ng` that round-trips, NaN and
  infinities against `null`. 12000 cases, 0 failures.
- Refusals (compile): `test/check_refusals.sh` compiles four fixtures in `test/refusals/` that
  must be refused with the member path in the diagnostic.
- Sources: `docs/research/bleu_json.md`.
