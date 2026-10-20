# bleu_ddc research note

Every constant, byte layout and sequence in `libs/bleu_ddc.c3l` is listed here
with its sources. Retrieved 2026-10-20. "Two sources" means two independent
implementations or documents that agree. Where only one source was reachable,
the entry says so. VESA's DDC/CI 1.1 and MCCS 2.2a are paid documents and were
not available; the open-source code that reproduces them is the primary
reference, as the brief directs.

Local copies of every fetched file are in `/home/user/scratch_ddc/` (outside the
repository). Line numbers below refer to those copies, which are the files at
the URLs given.

## Sources

| Short name | URL (raw) | What was used |
| --- | --- | --- |
| ddcutil `ddc_packets.c` | https://raw.githubusercontent.com/rockowitz/ddcutil/master/src/base/ddc_packets.c | checksum, request builders, reply interpretation, test vectors |
| ddcutil `ddc_packets.h` | …/src/base/ddc_packets.h | `DDC_PACKET_TYPE_*` opcodes |
| ddcutil `ddc_packet_io.c` | …/src/ddc/ddc_packet_io.c | source address check, altmode reply checksum, read size widened for the double-0x6E quirk, null retry |
| ddcutil `ddc_packets.c` (quirk) | …/src/base/ddc_packets.c (`interpret_*` quirk check, ~line 663) | the double-0x6E quirk itself: a second leading 0x6E is skipped |
| ddcutil `tuned_sleep.c` | …/src/base/tuned_sleep.c | timing comments per DDC/CI section, null-response adjustment |
| ddcutil `ddc_try_data.c` | …/src/ddc/ddc_try_data.c | retry type names (values not reachable, see below) |
| ddcutil `vcp_feature_codes.c` | …/src/vcp/vcp_feature_codes.c | MCCS code names, flags, value tables |
| ddcutil `parse_capabilities.c` | …/src/vcp/parse_capabilities.c | capabilities grammar, tolerated irregularities |
| ddc crate 0.2.2 | https://static.crates.io/crates/ddc/ddc-0.2.2.crate | `src/lib.rs` (encode, execute, delays), `src/commands.rs` (opcodes, delays) |
| ddc-i2c 0.2.2 | …/ddc-i2c/ddc-i2c-0.2.2.crate | `src/lib.rs` (Linux `/dev/i2c` path, reply checksum) |
| ddc-macos 0.2.2 | …/ddc-macos/ddc-macos-0.2.2.crate | `src/arm.rs` (IOAVService), `src/intel.rs` (IOI2C) |
| ddc-winapi 0.2.1 | …/ddc-winapi/ddc-winapi-0.2.1.crate | `src/lib.rs` (dxva2 binding, MC type mapping) |
| Lunar `DDC.c` | https://raw.githubusercontent.com/alin23/Lunar/master/Lunar/DDC/DDC.c | Intel framing, reply checksum, serial-number note |
| MonitorControl `Arm64DDC.swift` | https://raw.githubusercontent.com/MonitorControl/MonitorControl/main/MonitorControl/Support/Arm64DDC.swift | Apple Silicon framing and retries |
| Linux `i2c-dev` | https://raw.githubusercontent.com/torvalds/linux/master/Documentation/i2c/dev-interface.rst | `I2C_SLAVE`, `read`/`write` semantics |
| Linux `drm_edid.h` | https://raw.githubusercontent.com/torvalds/linux/master/include/drm/drm_edid.h | `struct edid`, descriptors, extension tags, feature bits |
| edid crate 0.3.0 | …/edid/edid-0.3.0.crate | `src/lib.rs` (parse functions, expected values), `testdata/` (four EDID binaries) |
| fnv crate 1.0.7 | …/fnv/fnv-1.0.7.crate | `lib.rs` (FNV-1a constants and test vector) |
| MS Learn dxva2 | https://learn.microsoft.com/en-us/windows/win32/api/lowlevelmonitorconfigurationapi/ | function signatures, `MC_VCP_CODE_TYPE` enum |

Not reached: m1ddc (`waydabber/m1ddc`: the raw paths tried returned 404, so
MonitorControl stands in for it); ddcutil's timing macros (`DDC_TIMEOUT_MILLIS_*`
and `INITIAL_MAX_*_EXCHANGE_TRIES`, defined in headers whose paths were tried and
returned 404); the edid-rs crate (0.1.0 downloaded and not used for values).

## 1. Framing

### 1.1 Addresses and opcodes

- Destination (write) address `0x6E` = chip `0x37` << 1; read address `0x6F` =
  `0x6E | 1`. ddcutil `ddc_packets.c:305` ("x37<<1 + 0 destination address,
  write"); ddc crate `lib.rs:31` (`I2C_ADDRESS_DDC_CI = 0x37`). Two sources.
- Source (host) address `0x51` = `(0x28 << 1) | 1`. ddcutil `ddc_packets.c:306`
  ("x28<<1 + 1 source address"); ddc crate `lib.rs:34`
  (`SUB_ADDRESS_DDC_CI = 0x51`); Lunar `DDC.c:315-326`. Three sources.
- Access.bus virtual host `0x50` = `0x28 << 1`. ddcutil `ddc_packet_io.c:597`
  (`buffer_set_byte(... 0, 0x6f)` "implicit, would be 0x50 on access bus") and
  `ddc_packets.c:82-87` (altmode seed). Two sources.
- Opcodes (`packet::Opcode`): `0x01` Get VCP request, `0x02` Get VCP reply,
  `0x03` Set VCP, `0x0C` Save Current Settings, `0xE2` Table Read request,
  `0xE3` Capabilities reply, `0xE4` Table Read reply, `0xE7` Table Write,
  `0xF3` Capabilities request. ddcutil `ddc_packets.h:86-97`; ddc crate
  `commands.rs` `data[0] = 0x01 / 0x03 / 0x0c / 0xe2 / 0xe7 / 0xf3` and
  `data[0] != 0x02 / 0xe3 / 0xe4` (lines 97, 311, 284). Each of these has two
  sources. ID request `0xF1` and ID reply `0xE1` are in ddcutil only.

### 1.2 Length byte and layout

- Payload length `n` is in the low 7 bits of the length byte, with `0x80` set:
  `0x80 | n`. ddcutil `ddc_packets.c:309` (`data_bytect | 0x80`); ddc crate
  `lib.rs:110` (`0x80 | data.len()`); Lunar `DDC.c:321` (`data[1] = 0x84`).
- Request I2C form: `51  80|n  payload...  checksum`.
- Reply: `6E  80|n  payload...  checksum` (see 2.2).

### 1.3 Get VCP, Set VCP, Save, Capabilities

- Get VCP request payload `01 code`. ddcutil `ddc_packets.c:474-486`; ddc crate
  `commands.rs:46-47`.
- Set VCP payload `03 code hi lo`, big-endian value. ddcutil
  `ddc_packets.c:499-516`; ddc crate `commands.rs:80-83`; Lunar `DDC.c:322-326`.
- Save payload `0C`. ddcutil `ddc_packets.c:526-533`; ddc crate `commands.rs:133`.
- Capabilities request payload `F3 offset_hi offset_lo`. ddc crate
  `commands.rs:240-241` (`data[1] = offset >> 8`). ddcutil `ddc_packets.c:348`
  builds the high byte with `offset >> 16`, but its own update path
  (`ddc_packets.c:390`) uses `>> 8`. ddcutil's `>> 16` is a quirk that does
  nothing for offsets below 65536; this library uses a `ushort` and `>> 8`.
- Table read request `E2 code offset_hi offset_lo` (ddcutil `ddc_packets.c:355-364`,
  ddc crate `commands.rs:206-207`). Not implemented in this library (see "Not
  done" in the README).

### 1.4 Reply payloads

- Get VCP reply payload (8 bytes): `02 result vcp type MH ML SH SL`. ddcutil
  `Vcp_Response` struct `ddc_packets.c:785-796` ("feature_reply_op_code, result_code,
  vcp_opcode, vcp_typecode, mh, ml, sh, sl"); ddc crate `commands.rs:95-112`
  (`data[4]` is MH, `data[5]` ML, `data[6]` SH, `data[7]` SL). Two sources.
- Current value is `SH<<8 | SL`, maximum `MH<<8 | ML`. ddcutil `ddc_packet_io`
  macros `RESPONSE_CUR_VALUE` / `RESPONSE_MAX_VALUE` (`base/ddc_packets.h`,
  Parsed_Nontable_Vcp_Response); MonitorControl `Arm64DDC.swift:77-78`
  (`max = reply[6]*256 + reply[7]`, `current = reply[8]*256 + reply[9]`);
  Lunar `DDC.c:415-416` (`max_value = reply_data[7]`, `current_value = reply_data[9]`).
  Three sources.
- Result code `0x00` no error, `0x01` unsupported VCP code (ddcutil
  `ddc_packets.c:858`; ddc crate `commands.rs:96-103`). Other values are errors.
- Type code `0x00` set parameter, `0x01` momentary. ddcutil
  `ddc_packets.c:790` comment; ddc crate `commands.rs` `ty: data[2]` plus the
  dxva2 mapping in section 6. Two sources.
- Capabilities / table fragment: `E3 offset_hi offset_lo data...` (ddc crate
  `commands.rs:303-322`, `data.len()` from 3 to 35; ddcutil
  `interpret_multi_part_read_response`, `ddc_packets.c:721-752`, "bytect < 3 ||
  bytect > 35"). Two sources. A fragment with no data is the end of the string
  (ddc crate `ddc-0.2.2/src/lib.rs:195-205`, `caps.data.is_empty() → break`).
- Table reply `E4 offset_hi offset_lo data...`. ddc crate `commands.rs:284-296`;
  ddcutil `DDC_PACKET_TYPE_TABLE_READ_RESPONSE 0xe4` (`base/ddc_packets.h:96`).

### 1.5 Null message

- A null message is the reply `6E 80 BE`: a valid frame with no payload.
  ddcutil `ddc_packet_io.c:91-99` (`is_ddc_null_message` tests `6f 6e 80 be`,
  compiled out with `UNUSED`); ddcutil test vector `{0x6f,0x6e,0x80} → 0xbe`
  (`ddc_packets.c:113`). Two sources (the vector and the arithmetic in 2.2).
- ddcutil treats repeated null replies as a retryable condition and, after
  `ddcrc_null_response_max = 3` (`ddc_packet_io.c:348`), as "maybe unsupported"
  (`ddc_packet_io.c:406-424`, "Acer monitor uses NULL response instead of
  setting the unsupported result").

## 2. Checksums

### 2.1 Requests

- Request checksum = XOR of every byte before it in the frame, **including the
  destination byte 0x6E**. In the I2C form (the bytes after the 0x6E address),
  seed with 0x6E.
  - ddcutil `ddc_checksum(bytes, len, altmode=false)` (`ddc_packets.c:80-90`),
    applied to a frame that starts `0x6e` (`ddc_packets.c:305-311`).
  - ddc crate `encode_command` (`lib.rs:108-118`): `checksum(iter::once((0x37)<<1)
    .chain(packet[..2+len]))`. The seed is `0x37 << 1 = 0x6E`.
  - Lunar `DDCWriteIntel` `DDC.c:326`: `data[6] = 0x6E ^ data[0..5]`.
  - Lunar `DDCReadIntel` `DDC.c:376`: `data[4] = 0x6E ^ data[0..3]` (Get VCP).
  - Three sources.
- Test vectors (ddcutil `ddc_packets.c:109-111`, full frames):
  `{6E,51,82,F5,01} → 0x49`; `{6E,51,81,B1} → 0x0F`. Both reproduced by
  `packet::checksum(0x6E, ...)` in `checksums_match_ddcutil`.

### 2.2 Replies

- Reply checksum seed is **0x50** (virtual host) in place of the read address
  0x6F, and the XOR runs over every received byte from the leading `0x6E`
  onward. The leading `0x6E` is therefore *included*.
  - ddcutil `ddc_checksum(..., altmode=true)` (`ddc_packets.c:80-90`, seeds
    `0x50` and XORs `bytes[1..]`), applied to `{0x6f, 0x6e, ...}` in
    `ddc_packet_io.c:603`, with the test vectors `{0x6f,0x6e,0x82,0xa1,0x00} → 0x1d`
    (`ddc_packets.c:112`) and `{0x6f,0x6e,0x80} → 0xbe` (`:113`).
  - MonitorControl `Arm64DDC.swift:108`: `checksum(chk: 0x50, data: reply[0..9])`,
    `reply[0]` being the received `0x6E`.
  - ddc-i2c `lib.rs:188-194`: seed `((0x37 << 1) | 1) = 0x6F` then `0x51`, then
    `out[1..2+len]` (the length byte onward). `0x6F ^ 0x51 = 0x3E = 0x50 ^ 0x6E`.
  - Lunar `DDCReadIntel` `DDC.c:391`: `replyAddress ^ replySubAddress ^ reply_data[1..9]`
    (`0x6F ^ 0x51`), the received `reply_data[0]` (`0x6E`) excluded.
  - Four sources. All four are the same value, `0x3E` over the bytes after `0x6E`.
- **Off-by-one hazard.** Seeding with `0x6E` and XORing the received `0x6E`
  gives the wrong checksum. Seeding with `0x6F ^ 0x51` and then XORing the
  received `0x6E` also gives the wrong value. The correct pairs are
  `0x50` with `0x6E` included, or `0x3E` with `0x6E` excluded.
- Duplicate leading `0x6E`: ddcutil `ddc_packets.c:664` ("Quirk: response packet
  starts with double 0x6e") and `ddc_packet_io.c:662-664`. Accepted here.
- Source check: the first byte must be `0x6E` (ddcutil `ddc_packet_io.c:574-575`,
  "Unexpected source address ... should be 0x6e"; ddc-i2c `lib.rs:162-194`
  requires the `0x80` bit in `out[1]`).

### 2.3 Golden frames (derivation)

Computed by hand from the rules above and recomputed independently in Python.

| Frame | Bytes | Derivation |
| --- | --- | --- |
| Get VCP 0x10, I2C | `51 82 01 10 AC` | `6E^51^82^01^10 = AC` |
| Set VCP 0x10 = 0x0032, I2C | `51 84 03 10 00 32 9A` | `6E^51^84^03^10^00^32 = 9A` |
| Capabilities 0x0100, I2C | `51 83 F3 01 00 4E` | `6E^51^83^F3^01^00 = 4E` |
| Save, I2C | `51 81 0C B2` | `6E^51^81^0C = B2` |
| Get VCP 0x10, frame | `6E 51 82 01 10 AC` | the I2C form with `6E` prepended |
| Reply: Luminance 50 of 100, set-param | `6E 88 02 00 10 00 00 64 00 32 F2` | `50^6E^88^02^10^00^00^64^00^32 = F2` |
| Reply: unsupported code 0x77 | `6E 88 02 01 77 00 00 00 00 00 C2` | `50^6E^88^02^01^77 = C2` |
| Null | `6E 80 BE` | `50^6E^80 = BE` |

### 2.4 The MonitorControl Get VCP checksum

MonitorControl `Arm64DDC.swift:99` seeds with `0x6E` alone when `send.count == 1`
(the Get VCP case) and with `0x6E ^ 0x51` otherwise. For Get VCP 0x10 that gives
`0xFD` where the spec gives `0xAC`. MonitorControl's Set VCP is correct
(`0x9A`). The discrepancy is real and was computed, not inferred. It is not
followed here. A display that validates request checksums would reject
MonitorControl's Get; those that do not validate them answer both. Our Get
sends the spec value.

## 3. Apple Silicon: IOAVService (`IOAVServiceWriteI2C`, `IOAVServiceReadI2C`)

This is the exact byte contract the brief asks for.

- Chip address `0x37`, data (sub-)address `0x51`, reads at offset `0`.
  - ddc-macos `arm.rs:33-47`: `IOAVServiceWriteI2C(service, 0x37, 0x51, request_data[1..], len-1)`
    and `IOAVServiceReadI2C(service, 0x37, 0, out, out.len)`.
  - MonitorControl `Arm64DDC.swift:6-7, 103, 107`: `ARM64_DDC_7BIT_ADDRESS = 0x37`,
    `ARM64_DDC_DATA_ADDRESS = 0x51`, `IOAVServiceWriteI2C(service, 0x37, 0x51, &packet, packet.count)`,
    `IOAVServiceReadI2C(service, 0x37, 0, &reply, reply.count)`.
  - Two sources agree.
- **The write buffer is the I2C form with the leading `0x51` removed.** That
  is `[length byte, payload..., checksum]`: no `0x6E` (the chip address is the
  `0x37` argument) and no `0x51` (it is the `offset` argument).
  - ddc-macos: `request_data` is the crate's `[0x51, 0x80|n, payload, chk]`, and
    `request_data[1..]` is passed.
  - MonitorControl: `packet = [0x80|(n+1), n, send..., chk]`. Its second byte is
    `send.count`, which equals the opcode for every message MonitorControl sends
    (`1` for Get VCP, `3` for Set VCP, which is the opcode value), and its first
    byte is `0x80 | (payload length)`. So the buffer is the same bytes.
  - Two sources agree.
  - Our `packet::Request.encode_i2c` produces the full I2C form, so an Apple
    backend passes `out[1..]` and the offset `0x51`.
- The checksum covers `0x6E ^ 0x51` (the implicit address and offset) followed
  by the buffer bytes. ddc-macos gets this from the `ddc` crate's seed.
  MonitorControl uses `0x6E ^ 0x51` for every message except the Get VCP
  request (section 2.4).
- The read is an 11-byte buffer for Get VCP, starting with the received `0x6E`
  (MonitorControl reads `reply[0]` into the checksum; ddc-macos passes the buffer
  to the `ddc` crate, whose decode starts at `out[0]`). Two sources.
- Timing: MonitorControl writes twice per attempt (`numOfWriteCycles`, 2 by
  default), sleeps 10 ms before each write, 50 ms before the read, and 20 ms
  between attempts (`Arm64DDC.swift:100-115`, default values from lines 102, 106,
  114). ddc-macos sleeps for the `ddc` crate's response delay (40 ms for Get VCP,
  50 ms between commands).
- Chip address `0xB7` for M1 built-in HDMI behind an `AppleDCPMCDP29XX` bridge:
  ddc-macos `arm.rs:103` and `arm.rs` `i2c_address()`. **Single source**, and not
  in MonitorControl. Not implemented here: the address belongs in the backend.

## 4. Intel Mac: IOI2CRequest

- `sendAddress = 0x6E`, `sendBytes` covers `[0x51, 0x80|n, payload, chk]` with
  the checksum seeded from `0x6E`: Lunar `DDC.c:315-326`, ddc-macos
  `intel.rs:31-34` (`request_data.len()`). Two sources.
- Reply: `replyAddress = 0x6F`, `replySubAddress = 0x51`, reply buffer starts
  with the received `0x6E`: Lunar `DDC.c:384-391`, ddc-macos `intel.rs:43-44`.
  Two sources.
- Lunar `DDC.c:335-337`: `DDCDelayBase = 1 ns`, and `+30000000 ns` (30 ms) on AMD
  (`/AMD` in the registry path). This is the origin of `min_interval_after_write`
  in `transport.c3`.

## 5. Linux: `/dev/i2c-N`

- Open `/dev/i2c-N`, then `ioctl(fd, I2C_SLAVE, 0x37)`. Kernel
  `Documentation/i2c/dev-interface.rst:53` and `:107-109`, "The address is passed in
  the 7 lower bits". Plain `write()`/`read()` then transfer the bytes with the
  address on the bus (`:81`, `:86`, `:93`, `:147`). The first byte of a write is
  *not* the address on the bus: it is data. ddc-i2c `lib.rs:164` writes
  `[0x51, 0x80|n, payload, chk]` as-is with `set_slave_address(0x37)`.
  Two sources.
- The chip's `0x6E` is therefore implicit in the write, as in section 1.

## 6. Windows: dxva2 low-level monitor API

- Signatures: `GetVCPFeatureAndVCPFeatureReply(hMonitor, bVCPCode, pvct, pdwCurrentValue,
  pdwMaximumValue)`, `SetVCPFeature(hMonitor, bVCPCode, dwNewValue)`,
  `GetCapabilitiesStringLength(hMonitor, pdwLength)`,
  `CapabilitiesRequestAndCapabilitiesReply(hMonitor, pszASCIICapabilitiesString, dwLength)`.
  MS Learn (the four function pages); ddc-winapi `lib.rs:93-150`. Two sources.
- **`MC_VCP_CODE_TYPE` is inverted relative to MCCS.** The Windows enum is
  `typedef enum _MC_VCP_CODE_TYPE { MC_MOMENTARY, MC_SET_PARAMETER }`
  (MS Learn `mc_vcp_code_type` page, the declaration block), so `MC_MOMENTARY = 0`
  and `MC_SET_PARAMETER = 1`. MCCS has set-parameter `0x00` and momentary `0x01`
  (ddcutil `ddc_packets.c:790`). ddc-winapi `lib.rs:179-180` maps
  `MC_SET_PARAMETER => 0`, `MC_MOMENTARY => 1`. A Windows backend must do the
  same mapping. Two sources, and the mapping is the trap.
- Capabilities strings are ASCII with a terminating NUL, and the length comes
  from `GetCapabilitiesStringLength` (MS Learn, the capabilities page).

## 7. Timing and retries

| Quantity | Value | Sources |
| --- | --- | --- |
| Write to read (Get VCP and fragments) | 40 ms | DDC/CI 4.3 "at least 40 ms" (ddcutil `tuned_sleep.c:89-92`, `SE_WRITE_TO_READ`); ddc crate `commands.rs:39` `DELAY_RESPONSE_MS = 40` (Get), `:198` (Table), `:232` (Capabilities). Two sources. |
| Read wait in MonitorControl | 50 ms | MonitorControl `Arm64DDC.swift:106` (`readSleepTime ?? 50000`). Stricter; `Options.write_to_read` can be raised. |
| Between commands | 50 ms | ddcutil `tuned_sleep.c:104` "at least 50ms to ensure next message is received"; ddc crate `commands.rs:40` ("the spec omits this, but 50 corresponds with what all other commands suggest"), `:73`, `:161`. Two sources. |
| Before retry (error recovery) | 40 ms | ddc crate `lib.rs:37` `DELAY_COMMAND_FAILED_MS = 40`; Lunar `DDC.c:412` `usleep(40000)` "DDC/CI Vesa Standard - 4.4.1 Communication Error Recovery". Two sources. |
| After Save Current Settings | 200 ms | ddc crate `commands.rs:127` `DELAY_COMMAND_MS = 200`; ddcutil `tuned_sleep.c:118` "at least 200 ms before sending the next message". Two sources. |
| Attempts per operation | 5 | MonitorControl `Arm64DDC.swift:100` (`1 ... numOfRetryAttemps + 1`, default 4). Lunar `DDC.c:13` `kMaxRequests 10` is the other end. |
| Null replies tolerated | 3 | ddcutil `ddc_packet_io.c:348` `ddcrc_null_response_max = 3`. One source. |
| Verify settle, reply timeout, capabilities limit | 50 ms, 100 ms, 8192 bytes | **Our choices, no source.** Labelled in `session.c3`. |

**Where the brief and the sources disagree.** The brief asks for "≥ 50 ms between
write and read, ≥ 40 ms between commands". Every source reviewed says the
reverse: 40 ms from write to read (DDC/CI 4.3) and 50 ms between commands
(ddc crate, ddcutil). The implementation uses the sourced values. The brief's
numbers would be safe as a stricter policy (`write_to_read = 50`), and that is
what MonitorControl does for the read.

**Null-response back-off in ddcutil.** `tuned_sleep.c:213-228` adds 25, 100 or
200 ms per null reply, but `null_msg_adjustment_enabled` is `false` at
`tuned_sleep.c:41`. It is off by default in ddcutil, so this library does not
implement it. The brief's "exponential-ish back-off" is not what ddcutil does.
Fixed delays are used.

**ddcutil's retry counts are not reachable.** `INITIAL_MAX_WRITE_READ_EXCHANGE_TRIES`
and the others are used in `ddc_try_data.c:61-65` but defined in a header not
found. The value 5 comes from MonitorControl (section 7 table).

## 8. MCCS feature codes and values

### 8.1 Names and kinds

From ddcutil `vcp_feature_codes.c` (`v20_name`, `v20_flags`, `v22_flags`, `desc`):

| Code | Name used | Kind | Access | ddcutil entry |
| --- | --- | --- | --- | --- |
| 0x10 | Luminance (2.x "Brightness", 3.0 "Luminosity") | continuous | RW | `:2804` |
| 0x12 | Contrast | continuous | RW | `:2823` |
| 0x14 | Select color preset | non-continuous | RW | `:2846` (2.0 SIMPLE_NC; 2.2 COMPLEX_NC) |
| 0x16/0x18/0x1A | Video gain: Red/Green/Blue | continuous | RW | `:2860`, `:2875`, `:2882` |
| 0x60 | Input source | non-continuous (table in 3.0) | RW | `:3301`, comment "In V3, x60 is type table" at `:3303` |
| 0x62 | Audio speaker volume | non-continuous for 2.2 (see note) | RW | `:3311`; ddcutil 2.2 comment at `:1719-1730` |
| 0x8D | Audio mute | non-continuous | RW | `:3602` |
| 0xAC | Horizontal frequency | continuous | RO | `:3861` (2.0 comment at `:3865`: the display may not supply it) |
| 0xAE | Vertical frequency | continuous | RO | `:3869` |
| 0xB6 | Display technology type | non-continuous | RO | `:3910` |
| 0xC9 | Display firmware level | non-continuous | RO | ddcutil "2 byte firmware level" |
| 0xCA | OSD/Button control | non-continuous | RW | `:2153` area, v2.2 COMPLEX_NC |
| 0xCC | OSD language | non-continuous | RW | `:2563` area |
| 0xD6 | Power mode | non-continuous | RW | `:2638` table (`xd6_power_mode_values`) |
| 0xDF | VCP version | non-continuous | RO | ddcutil "VCP Version" |

Note on 0x62: MCCS 2.2a's summary table lists it as continuous, while its
section 8.6 documents it as non-continuous with reserved values. ddcutil's
comment at `vcp_feature_codes.c:1729` says "treat as NC" for 2.2, and this
library follows that for 2.2 (`NON_CONTINUOUS`). The 2.0 flags (`:3311`,
`DDCA_STD_CONT`) say continuous.

### 8.2 Input source (0x60), MCCS 2.2

`x60_v2_input_source_values`, `vcp_feature_codes.c:2275-2298`:
`0x01` VGA-1, `0x02` VGA-2, `0x03` DVI-1, `0x04` DVI-2, `0x05`/`0x06` Composite,
`0x07`/`0x08` S-Video, `0x09`-`0x0B` Tuner, `0x0C`-`0x0E` Component,
`0x0F` DisplayPort-1, `0x10` DisplayPort-2, `0x11` HDMI-1, `0x12` HDMI-2.
ddcutil's comment at `:2291`: "remaining values in v2.2 spec, assume also valid for
v2.1". The `0x0F`-`0x12` values are the ones the brief asked for. They
are checked against ddcutil's table, and the same values appear in its `xd0`/`0xd0`
table at `:2630-2634`, which ddcutil marks "need to check V3".

**0x1B "USB-C" is not verified and is not in the enum.** The brief asked for it.
ddcutil's table stops at `0x12`, the only `0x1b` in that file is a
manufacturer and a locale. Lunar and MonitorControl were checked for it and
did not supply a value. No second source was found, so the value is left out.
A shell that needs it must pass the raw value, which the `char` API allows.

### 8.3 Power mode (0xD6)

`xd6_power_mode_values` at `vcp_feature_codes.c:2638-2644`: `0x01` "DPM: On, DPMS: Off",
`0x02` "DPM: Off, DPMS: Standby", `0x03` "DPM: Off, DPMS: Suspend",
`0x04` "DPM: Off, DPMS: Off", `0x05` "Write only value to turn off display".
Names are ddcutil's own.

### 8.4 Quirks noted

- 0x60 is a table in MCCS 3.0, so the same code means a different encoding there
  (ddcutil `:2273`, `:3303`).
- 0x8D gained an SH byte for screen blank in 2.2 (ddcutil `:2343` and `:3605`).
  This library reads it as the audio mute value.
- 0x14 is SIMPLE_NC in 2.0 and COMPLEX_NC in 2.2 (ddcutil `:2846-2852`).

## 9. Capabilities string

Grammar and tolerated irregularities, from ddcutil `vcp/parse_capabilities.c`:

- Outer parentheses are optional and an unbalanced outer parenthesis is
  "Capabilities string lacks closing parenthesis" (`parse_capabilities`,
  `:662-700`). Apple Cinema Display "does not surround capabilities string with
  parens" (`:697`). Both are handled.
- Segment name ends at `(` or blank; a missing value is "Missing parenthesized
  value" (`next_capabilities_segment`, `:569-630`). Here a bare value is
  tolerated, for `model LCDPB287` (ddcutil's own test string at `:43-44` contains
  it), and the result is USABLE.
- `find_closing_paren` counts depth (`:197-215`); a missing closer is fatal for
  the segment (`:329-400`, "Value parse terminated without closing parenthesis").
  Here the value runs to the end of its span and the result is INVALID, so codes
  read so far are kept (ddcutil discards the segment's codes).
- Codes are two hex digits; a longer token is split (`parse_vcp_segment`
  `:329-400`, "if (len > 2) pos = st + 2"); `cmds` tokens may run together
  ("per the Access Bus spec, Section 7, values need not be separated by spaces",
  `parse_cmds_segment` `:263-266`). ddcutil drops all of `cmds` when one token
  fails; here only the bad token is dropped.
- Vendor segments (`vcpname`, `asset_eep`, `mpu`, `mswhql`) are ignored
  (`parse_capabilities` `:781`). Nested parentheses are balanced.
- Segments: `prot`, `type`, `model`, `cmds`, `vcp`/`VCP` (Apple's hack, `:743`),
  `mccs_ver`. A bad `mccs_ver` is flagged, not fatal (`:767`).

## 10. EDID

### 10.1 Layout

Kernel `drm_edid.h` `struct edid` (`:291-334`) and `struct detailed_pixel_timing`
(`:75-93`); edid crate 0.3.0 `lib.rs`:

| Offset | Field | Kernel | edid crate |
| --- | --- | --- | --- |
| 0-7 | header `00 FF FF FF FF FF FF 00` | `header[8]` | `parse_header` tag (`:30`) |
| 8-9 | manufacturer, big-endian, 3 letters of 5 bits, `'@' + v` | `mfg_id[2]`, `drm_edid_decode_mfg_id` (`:380-392`) | `parse_vendor` (`:21-27`, `'A'-1 + v`) |
| 10-11 | product code, LE | `prod_code[2]` | `le_u16` (`:32`) |
| 12-15 | serial, LE | `u32 serial` (FIXME on byte order) | `le_u32` (`:33`) |
| 16-17 | week; year minus 1990 | `mfg_week`, `mfg_year` | `le_u8` ×2, "Starting at year 1990" (`:14`) |
| 18-19 | version, revision | `version`, `revision` | `le_u8` ×2 |
| 20 | input; bit 7 digital | `DRM_EDID_INPUT_DIGITAL = 1 << 7` (`:204`) | `video_input` |
| 21-22 | width, height cm | `width_cm`, `height_cm` | `le_u8` (`:52-53`) |
| 23 | gamma: `gamma*100 - 100` | `gamma` | "datavalue = (gamma*100)-100" (`:46`) |
| 24 | features; bit 1 preferred timing | `DRM_EDID_FEATURE_PREFERRED_TIMING = 1 << 1` (`:225`) | `features` |
| 54,72,90,108 | descriptors | `detailed_timings[4]` | `Descriptor` parse (`:153-200`) |
| 126 | extension count | `extensions` | `take!(1)` (`:253`) |
| 127 | checksum: block sums to 0 | `checksum` | — |

Descriptors (`drm_edid.h:165-188`, `edid crate :171-186`): a timing has a
non-zero pixel clock (bytes 0-1, in 10 kHz units); a non-timing descriptor has
bytes 0-1 zero and tag in byte 3: `0xFC` name (`EDID_DETAIL_MONITOR_NAME`),
`0xFF` serial (`EDID_DETAIL_MONITOR_SERIAL`), `0xFE` text, `0xFD` range limits.
Only `0xFC` and `0xFF` are read.

Timing nibbles (edid crate `parse_detailed_timing` `:104-146`, kernel field names):
`h_active = b2 | (b4 >> 4) << 8`, `h_blank = b3 | (b4 & 0xF) << 8`,
`v_active = b5 | (b7 >> 4) << 8`, `v_blank = b6 | (b7 & 0xF) << 8`.

Extension tags (kernel `drm_edid.h:42` `CEA_EXT 0x02`, `:47` `DISPLAYID_EXT 0x70`).
CEA `0x02` is confirmed by the DP-3 fixture (its extension byte 0 is `0x02`),
which makes it two sources. DisplayID `0x70` is kernel only.

Descriptor text: 13 bytes, a line feed (`0x0A`) ends it, and spaces pad it.
The edid crate's descriptor parse and the fixture text agree.

### 10.2 Golden fixtures

The four binaries in `edid-0.3.0/testdata/` (`card0-VGA-1`, `card0-eDP-1`,
`card0-LVDS-1`, `card0-DP-3`) are embedded byte for byte in `edid_test.c3`. Their
expected values were decoded independently in Python (a script, not committed)
and agree with the crate's own expectations:

| Fixture | Vendor | Product | Serial | Week/year | Size cm | Preferred timing | Name / serial text | Extensions |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| VGA-1 | SAM (0x4C2D) | 596 | 1146106418 | 27 / 2007 | 47×30 | 146250 kHz, 1680+560 × 1050+39 | "SyncMaster" / "HS3P701105" | 0 |
| eDP-1 | SHP (0x4D10) | 5193 | **0** | 32 / 2015 | 29×17 | 138500 kHz, 1920+160 × 1080+31 | none | 0 |
| LVDS-1 | CMN (0x0DAE) | 5252 | **0** | 38 / 2012 | 31×17 | 112600 kHz, 1600+366 × 900+54 | none | 0 |
| DP-3 | ACR (0x0472) | 747 | 875572011 | 43 / 2013 | 51×29 | 148500 kHz, 1920+280 × 1080+45 | "G236HL" / "LVNEE0052482" | 1 (tag 0x02) |

Gamma is 2.2 in all four (gamma byte 120, which is 0x78).

### 10.3 Zero serial

Lunar `DDC.c:233`: "SN is zero in lots of cases, so duplicate-monitors can
confuse us". The eDP-1 and LVDS-1 fixtures have serial 0. So the fingerprint
omits the serial when it is zero, and documents the collision risk in
`edid.c3` (`Edid.fingerprint`).

### 10.4 Fingerprint

FNV-1a 64: offset basis `0xcbf29ce484222325`, prime `0x100000001b3`
(fnv crate `lib.rs:95`, `:120`, and the empty-string test vector at `:163`).
Hashed bytes: vendor (3 letters), product (2 bytes LE), serial (4 bytes LE,
only if non-zero), name. A platform-side fingerprint needs the same vendor, product,
serial and name, which CoreGraphics and Windows both report.

## 11. Linux, macOS and Windows transports: what this library assumes

- `Transport.write` takes the I2C form (section 1). Every backend in section 3-6
  accepts that form, because the first byte `0x51` is the source and the
  destination is the device address.
- `Transport.read` returns the bytes received, which may be fewer than the
  buffer. Zero means nothing arrived. Native fixed-length reads (IOAVService) are
  still expected to return a full buffer; the parser accepts a longer buffer.
- Write-to-read wait comes from the policy, or the transport's
  `min_interval_after_write` when that is longer (AMD: 30 ms more, Lunar).

## 12. Open items

1. The brief's timing numbers are reversed relative to every source (section 7).
   The library uses the sources' values. The lead should decide.
2. `0x1B` USB-C is unverified (section 8.2).
3. ddcutil's timing macros and try counts are unreachable. The values used are
   those of the `ddc` crate, MonitorControl and Lunar, each cited.
4. The MonitorControl Get checksum (section 2.4) is a discrepancy in a widely
   used project, recorded for reference.
5. m1ddc was not reached. Its Apple Silicon behaviour is not represented.
6. The M1 HDMI chip address `0xB7` (section 3) is single-sourced and not coded.
7. Table Read (`E2`/`E4`) is not implemented. The opcodes are there.
