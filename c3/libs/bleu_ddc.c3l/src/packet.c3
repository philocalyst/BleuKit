<*
 DDC/CI packet framing: the bytes exchanged with a display, nothing more.

 Two forms of a request exist, and most backends need only the first:

 * **I2C form** (`encode_i2c`): what a `/dev/i2c-N` `write()`, an Intel-Mac
   `IOI2CSendRequest` or an Apple-Silicon `IOAVServiceWriteI2C` transfers. The
   destination byte 0x6E is not stored: it is the device address of the
   transfer (chip 0x37, write). The bytes start with the source address 0x51.

       51  80|n  opcode  args...  checksum

 * **Frame form** (`encode_frame`): the complete message, destination first.
   Only tests and documentation need it.

 Request checksum: XOR of every byte before it, *including* the destination
 0x6E. In the I2C form that is "seed 0x6E, then XOR the stored bytes".
 Sources: ddcutil `src/base/ddc_packets.c` (`ddc_checksum`, altmode false, and
 `create_ddc_base_request_packet`); ddc crate `ddc-0.2.2/src/lib.rs`
 (`encode_command`, seed `I2C_ADDRESS_DDC_CI << 1`); Lunar `Lunar/DDC/DDC.c`
 (`DDCWriteIntel`, `data[6] = 0x6E ^ data[0..5]`).

 Reply: the monitor answers from read address 0x6F, and the bytes read are

       6E  80|n  opcode  payload...  checksum

 Reply checksum: seeded with the virtual host address 0x50 and XORed over the
 bytes from the leading 0x6E onward. The read address 0x6F is replaced by 0x50
 and the source 0x51 is not included. Equivalent: seed 0x6F ^ 0x51 (0x3E) over
 the bytes after 0x6E. This is the off-by-one hazard: seeding with 0x6E and
 including the received 0x6E gives the wrong value.
 Sources: ddcutil `ddc_checksum(..., altmode=true)` (test vectors
 `{0x6f,0x6e,0x82,0xa1,0x00} -> 0x1d`, `{0x6f,0x6e,0x80} -> 0xbe`); ddc-i2c
 `execute_raw` (seed `((0x37 << 1) | 1)` then `SUB_ADDRESS_DDC_CI`, over
 `out[1..]`); Lunar `DDCReadIntel` (`replyAddress ^ replySubAddress ^ ...`).

 A null message (no payload) is the reply `6E 80 BE`.
*>
module bleu::ddc::packet;
import bleu::error, bleu::ddc::vcp;

<* 7-bit DDC/CI slave address of the display (chip 0x37). *>
const char CHIP_ADDRESS = 0x37;
<* Destination byte of every request: `CHIP_ADDRESS << 1`. *>
const char WRITE_ADDRESS = 0x6E;
<* Address the host reads replies from: `(CHIP_ADDRESS << 1) | 1`. *>
const char READ_ADDRESS = 0x6F;
<* Source address of host requests: `(0x28 << 1) | 1`. *>
const char HOST_SOURCE = 0x51;
<* Access.bus virtual host address: `0x28 << 1`, the seed of reply checksums. *>
const char VIRTUAL_HOST = 0x50;

<*
 Largest request payload this module builds: the opcode and arguments of Set
 VCP Feature, the largest request it encodes.
*>
const usz MAX_PAYLOAD = 4;
<*
 Largest reply payload: opcode, two bytes of offset and 32 bytes of fragment
 (the capabilities and table-read layout, DDC/CI 4.6). A payload longer than
 this is malformed (ddcutil `interpret_multi_part_read_response`).
*>
const usz MAX_REPLY_PAYLOAD = 35;
<* Bytes of capabilities or table data carried by one fragment reply. *>
const usz MAX_FRAGMENT = 32;

<*
 Opcodes of the DDC/CI and MCCS messages.

 The request and reply values are the ones in ddcutil `src/base/ddc_packets.h`
 (`DDC_PACKET_TYPE_*`). `GET_VCP_REQUEST`, `SET_VCP`, `SAVE_CURRENT_SETTINGS`,
 `CAPABILITIES_REQUEST`, `TABLE_READ_REQUEST` and `TABLE_WRITE` are also in the
 ddc crate `commands.rs`. `ID_REQUEST`, `ID_REPLY` and `TABLE_READ_REPLY`
 have only the ddcutil source.
*>
constset Opcode : char
{
	GET_VCP_REQUEST = 0x01,
	GET_VCP_REPLY = 0x02,
	SET_VCP = 0x03,
	SAVE_CURRENT_SETTINGS = 0x0C,
	TABLE_READ_REQUEST = 0xE2,
	TABLE_READ_REPLY = 0xE4,
	TABLE_WRITE = 0xE7,
	CAPABILITIES_REPLY = 0xE3,
	CAPABILITIES_REQUEST = 0xF3,
	ID_REPLY = 0xE1,
	ID_REQUEST = 0xF1,
}

<*
 Result codes of Get VCP Feature Reply (DDC/CI 4.3 and MCCS 2.2a 6.2).

 Source: ddcutil `interpret_vcp_feature_response_std` (`result_code`), and
 ddc crate `commands.rs` `VcpValue::decode`.
*>
constset ResultCode : char
{
	NO_ERROR = 0x00,
	UNSUPPORTED_VCP = 0x01,
}

<* Type code of a VCP feature, from Get VCP Feature Reply byte 3. *>
constset VcpType : char
{
	SET_PARAMETER = 0x00,
	MOMENTARY = 0x01,
}

<*
 A request payload: the opcode and its arguments, without framing. Only the
 first `len` bytes of `payload` are valid.
*>
struct Request
{
	char[MAX_PAYLOAD] payload;
	usz len;
}

<* Get VCP Feature (0x01): ask the monitor for the current and maximum value of `code`. *>
fn Request get_vcp(VcpCode code)
{
	Request r;
	r.payload[0] = (char)Opcode.GET_VCP_REQUEST;
	r.payload[1] = (char)code;
	r.len = 2;
	return r;
}

<*
 Set VCP Feature (0x03): set `code` to `value`. Values are big-endian on the wire.

 Source: DDC/CI 4.3; ddcutil `create_ddc_setvcp_request_packet`; ddc crate
 `SetVcpFeature::encode`.
*>
fn Request set_vcp(VcpCode code, ushort value)
{
	Request r;
	r.payload[0] = (char)Opcode.SET_VCP;
	r.payload[1] = (char)code;
	r.payload[2] = (char)(value >> 8);
	r.payload[3] = (char)(value & 0xFF);
	r.len = 4;
	return r;
}

<*
 Capabilities Request (0xF3): ask for the capabilities string starting at byte
 `offset`. The offset is two bytes, big-endian. The reply is a fragment.

 Source: DDC/CI 4.6; ddcutil `create_ddc_base_request_packet` (`{0xF3, hi, lo}`);
 ddc crate `CapabilitiesRequest::encode` (`data[1] = offset >> 8`).
*>
fn Request capabilities_request(ushort offset)
{
	Request r;
	r.payload[0] = (char)Opcode.CAPABILITIES_REQUEST;
	r.payload[1] = (char)(offset >> 8);
	r.payload[2] = (char)(offset & 0xFF);
	r.len = 3;
	return r;
}

<* Save Current Settings (0x0C): store the current settings in the monitor's NVRAM. *>
fn Request save_settings()
{
	Request r;
	r.payload[0] = (char)Opcode.SAVE_CURRENT_SETTINGS;
	r.len = 1;
	return r;
}

<*
 XOR of `bytes`, seeded with `seed`. This is the DDC/CI checksum with the seed
 chosen by the direction of the message (see the module comment).
*>
fn char checksum(char seed, char[] bytes)
{
	char sum = seed;
	foreach (b : bytes) sum ^= b;
	return sum;
}

<*
 Write the I2C form of the request into `out`: source, length, payload, checksum.

 @param out : "Receives the bytes; must hold at least `len + 3` bytes"
 @return "The number of bytes written"
 @return? error::INVALID_ARGUMENT : "`out` is too small for the request"
*>
fn usz? Request.encode_i2c(&self, char[] out)
{
	usz n = self.len;
	if (out.len < n + 3)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0,
			"a %d-byte request does not fit in %d bytes", n + 3, out.len)~;
	}
	out[0] = HOST_SOURCE;
	out[1] = (char)(0x80 | n);
	for (usz i = 0; i < n; i++) out[2 + i] = self.payload[i];
	out[n + 2] = checksum(WRITE_ADDRESS, out[..n + 1]);
	return n + 3;
}

<*
 Write the complete frame of the request into `out`: destination, then the I2C form.

 @param out : "Receives the bytes; must hold at least `len + 4` bytes"
 @return "The number of bytes written"
 @return? error::INVALID_ARGUMENT : "`out` is too small for the request"
*>
fn usz? Request.encode_frame(&self, char[] out)
{
	if (out.len < self.len + 4)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0,
			"a %d-byte frame does not fit in %d bytes", self.len + 4, out.len)~;
	}
	out[0] = WRITE_ADDRESS;
	usz written = self.encode_i2c(out[1..])!;
	return written + 1;
}

<* Which reply a `Reply` holds. *>
enum ReplyKind : char
{
	NULL_MESSAGE,
	GET_VCP,
	CAPABILITIES_FRAGMENT,
}

<*
 A parsed monitor reply. `kind` says which fields apply:

 - GET_VCP uses `code`, `momentary`, `current` and `maximum` (the maximum is
   0 for non-continuous features).
 - CAPABILITIES_FRAGMENT uses `offset` (where `fragment` starts in the string)
   and `fragment_len` valid bytes. A zero length marks the end of the string.
 - NULL_MESSAGE uses no fields.
*>
struct Reply
{
	ReplyKind kind;
	VcpCode code;
	bool momentary;
	ushort current;
	ushort maximum;
	ushort offset;
	char[MAX_FRAGMENT] fragment;
	usz fragment_len;
}

<*
 Parse one reply from the bytes read from the monitor, starting at its leading 0x6E.

 A single leading duplicate 0x6E is skipped, because some monitors send it twice
 (ddcutil `ddc_packet_io.c`, "Quirk: response packet starts with double 0x6e").

 @param bytes : "Bytes read from the monitor; may be longer than the reply"
 @return "The reply; a null message is `NULL_MESSAGE`"
 @return? error::PROTOCOL : "Bad length, source, checksum, opcode or payload size"
 @return? error::UNSUPPORTED : "The monitor reports the VCP code as unsupported (result 0x01)"
*>
fn Reply? parse_reply(char[] bytes)
{
	char[] frame = bytes;
	if (frame.len >= 2 && frame[0] == WRITE_ADDRESS && frame[1] == WRITE_ADDRESS) frame = frame[1..];
	if (frame.len < 3)
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0,
			"reply of %d bytes is shorter than the 3-byte minimum", frame.len)~;
	}
	if (frame[0] != WRITE_ADDRESS)
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0,
			"reply starts with 0x%02x, expected the source 0x6e", frame[0])~;
	}
	char length_byte = frame[1];
	if ((length_byte & 0x80) == 0)
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0,
			"reply length byte 0x%02x lacks the 0x80 flag", length_byte)~;
	}
	usz n = (usz)(length_byte & 0x7F);
	if (n > MAX_REPLY_PAYLOAD)
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0,
			"reply payload of %d bytes exceeds %d", n, MAX_REPLY_PAYLOAD)~;
	}
	if (frame.len < n + 3)
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0,
			"reply of %d bytes is truncated, %d expected", frame.len, n + 3)~;
	}
	char expected = checksum(VIRTUAL_HOST, frame[..n + 1]);
	if (frame[n + 2] != expected)
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0,
			"reply checksum 0x%02x, expected 0x%02x", frame[n + 2], expected)~;
	}
	if (n == 0) return { .kind = NULL_MESSAGE };
	return parse_payload(frame[2 .. n + 1]);
}

// Interpret the checked payload of a reply (opcode first).
fn Reply? parse_payload(char[] payload) @private
{
	switch ((Opcode)payload[0])
	{
		case GET_VCP_REPLY:
			return parse_vcp_reply(payload);
		case CAPABILITIES_REPLY:
			return parse_fragment_reply(payload);
		default:
			return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0,
				"unexpected reply opcode 0x%02x", payload[0])~;
	}
}

fn Reply? parse_vcp_reply(char[] payload) @private
{
	if (payload.len != 8)
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0,
			"Get VCP reply has %d payload bytes, expected 8", payload.len)~;
	}
	switch ((ResultCode)payload[1])
	{
		case NO_ERROR:
			break;
		case UNSUPPORTED_VCP:
			return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0,
				"monitor reports VCP 0x%02x as unsupported", payload[2])~;
		default:
			return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0,
				"Get VCP result code 0x%02x", payload[1])~;
	}
	VcpType type = (VcpType)payload[3];
	if (type != SET_PARAMETER && type != MOMENTARY)
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0,
			"VCP type code 0x%02x is neither set-parameter nor momentary", payload[3])~;
	}
	// Byte order is high then low for both maximum (MH, ML) and present (SH, SL).
	return {
		.kind = GET_VCP,
		.code = (VcpCode)payload[2],
		.momentary = type == MOMENTARY,
		.maximum = (ushort)(((ushort)payload[4] << 8) | payload[5]),
		.current = (ushort)(((ushort)payload[6] << 8) | payload[7]),
	};
}

fn Reply? parse_fragment_reply(char[] payload) @private
{
	if (payload.len < 3)
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0,
			"capabilities fragment of %d payload bytes has no offset", payload.len)~;
	}
	Reply r = {
		.kind = CAPABILITIES_FRAGMENT,
		.offset = (ushort)(((ushort)payload[1] << 8) | payload[2]),
		.fragment_len = payload.len - 3,
	};
	for (usz i = 0; i < r.fragment_len; i++) r.fragment[i] = payload[3 + i];
	return r;
}

<*
 Encode a reply as a monitor sends it: 0x6E, length, payload, checksum. Used by
 the mock monitor. An empty payload encodes the null message `6E 80 BE`.

 @param out : "Receives the bytes; must hold at least `payload.len + 3` bytes"
 @return "The number of bytes written"
 @return? error::INVALID_ARGUMENT : "`out` is too small, or the payload is longer than `MAX_REPLY_PAYLOAD`"
*>
fn usz? encode_reply(char[] payload, char[] out)
{
	usz n = payload.len;
	if (n > MAX_REPLY_PAYLOAD || out.len < n + 3)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0,
			"a %d-byte reply payload does not fit in %d bytes", n, out.len)~;
	}
	out[0] = WRITE_ADDRESS;
	out[1] = (char)(0x80 | n);
	for (usz i = 0; i < n; i++) out[2 + i] = payload[i];
	out[n + 2] = checksum(VIRTUAL_HOST, out[..n + 1]);
	return n + 3;
}
