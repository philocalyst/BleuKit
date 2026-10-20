# bleu_ddc

DDC/CI (VESA Display Data Channel Command Interface) and MCCS (Monitor Control
Command Set) for Bleu's brightness, display and input services. The library is
pure: it does no I/O of its own. A backend implements `transport::Transport` over
`/dev/i2c-N` (Linux), IOI2C or IOAVService (macOS), or the dxva2 calls (Windows),
and the `session::Session` drives it with the timing and retry rules the
open-source implementations use.

Sources, byte layouts and every disagreement found are in
`docs/research/bleu_ddc.md`.

## Public API

- `packet`: `get_vcp`, `set_vcp`, `capabilities_request`, `save_settings` build a
  `Request`. `Request.encode_i2c` (the form a `write()` sends) and
  `Request.encode_frame` (the whole frame) serialise it. `parse_reply` checks and
  decodes a reply: `GET_VCP`, `CAPABILITIES_FRAGMENT` or `NULL_MESSAGE`. Its
  excuses are `PROTOCOL` (framing, checksum, opcode) and `UNSUPPORTED` (result 0x01).
- `vcp`: `constset VcpCode`, `feature(code)` with `VcpFeature` (name, kind,
  access), `input_source_name`, `power_mode_name`, and the `InputSource` and
  `PowerMode` constsets.
- `capabilities`: `parse(text, allocator)` returns `Capabilities` (validity,
  model, MCCS version, commands, features), with `supports(code)` and
  `allowed_values(code)` (`NOT_FOUND` for an unlisted code).
- `transport`: `interface Transport { write, read, min_interval_after_write }`,
  `Sleeper` and `real_sleeper()`.
- `session`: `open(transport, sleeper, options)`, `Session.get_vcp`, `set_vcp`,
  `set_vcp_verified`, `save_settings`, `read_capabilities`; `Options`,
  `default_options()`, `Statistics`, `Reading`. A session with `max_tries` zero refuses
  every operation with INVALID_ARGUMENT before writing anything.
- `edid`: `parse(data, allocator)` returns `Edid` (PNP vendor, product, serial,
  week/year, size, gamma, preferred `Timing`, name and serial descriptors,
  extension tags) and `Edid.fingerprint()`.
- `mock`: `MockMonitor`, a `Transport` with a VCP store, a capabilities string
  and deterministic fault counters (drop, corrupt, null, duplicate, doubled leading
  0x6E, refused write, lagging set).

## Not done

- Table Read (0xE2/0xE4) and Table Write (0xE7) are not implemented. The opcodes
  are defined.
- The Apple M1 HDMI chip address (0xB7) is single-sourced and not coded. A macOS
  backend chooses the address.
- VCP 0x1B "USB-C" is not in the enum: no second source was found.
- `set_vcp_verified` reports a mismatch as `BACKEND_FAILURE`. A monitor that
  clamps a value is reported as a mismatch.
- The verify settle time, reply timeout and capabilities size limit are this
  library's choices. The research note labels each one.
- No backend. No locking: a `Session` is for one thread (the service's worker).

## Verified

- `c3c --libdir libs --lib bleu_core --lib bleu_ddc compile-test libs/bleu_ddc.c3l/src/*_test.c3`:
  78 tests of this library, all passing (packet framing and checksums, capabilities
  grammar, EDID on four real binaries and the features-bit rule, session timing and
  retries against the mock, the doubled leading 0x6E quirk on Get VCP and capabilities,
  the zero-attempt refusal, mock behaviour, VCP tables, real sleeper). The runner also
  runs `bleu_core`'s own tests, so its total line is larger. Golden vectors are derived in the
  research note and recomputed independently in Python.
- `tools/check.sh bleu_core bleu_ddc`: clean on all six targets. Only Linux was
  run. The macOS and Windows backends that will use this are not part of this
  library and were not built.
- `c3fmt --check` clean on every file.
