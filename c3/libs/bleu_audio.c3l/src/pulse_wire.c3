<*
 PulseAudio native protocol: packet framing and the tagstruct encoding.

 Pure (no I/O, no OS): every function works on bytes, so the codec is tested
 against golden bytes without a server (pulse_test.c3).

 Sources, each checked against the upstream PulseAudio master sources unless
 marked otherwise (raw.githubusercontent.com/pulseaudio/pulseaudio/master/src/):
 - frame header: pulsecore/pstream.c:55-63 (descriptor index), :619 (control
   channel -1), :83 (maximum frame); crate pulseaudio 0.3.2 src/protocol.rs
   read_descriptor and write_descriptor (same five words, network order).
 - tag bytes: pulsecore/tagstruct.h:36-75; encoders in pulsecore/tagstruct.c:
   puts 200, put_sample_spec 226, put_arbitrary 236, put_boolean 245,
   put_usec 259, puts64 273, put_channel_map 280, put_cvolume 293,
   put_volume 306, put_proplist 313, put_format_info 337.
 - proplist entry: key string, then a u32 length, then an arbitrary blob of
   the same length; the list ends with a NULL string (tagstruct.c:313-336).
   The crate's props.rs read() reads the same three items (cross-check).
 - command numbers: pulsecore/native-common.h (enum around line 35-191).
 - subscription event: pulsecore/protocol-native.c:3729-3734.
*>
module bleu::audio::pulse;
import std::collections::list, bleu::error;

<* The protocol version this client speaks. meson.build:26 and crate MAX_VERSION (protocol.rs:20). *>
const uint PROTOCOL_VERSION = 35;

<*
 Low bits of the version word in AUTH and its reply. The high bits carry shared
 memory and memfd flags. UNVERIFIED: the mask value (PA_PROTOCOL_VERSION_MASK)
 is not in any file read; 0xFFFF is inferred from the flag bits sitting at 30-31.
*>
const uint VERSION_MASK = 0x0000FFFF;

const sz FRAME_HEADER_SIZE = 20;      // five big-endian u32 words
const uint CONTROL_CHANNEL = 0xFFFFFFFF; // channel -1 marks command packets (pstream.c:619)
const sz MAX_PAYLOAD = 16 * 1024 * 1024; // pstream.c:83

const sz COOKIE_LENGTH = 256;         // native-common.h:196 (PA_NATIVE_COOKIE_LENGTH)
const uint NO_INDEX = 0xFFFFFFFF;      // PA_INVALID_INDEX
const sz CHANNELS_MAX = 32;           // sample.h:128 (PA_CHANNELS_MAX)

const uint REPLY_TAG_EVENT = 0xFFFFFFFF; // tag of server-pushed events (-1)

// Tag bytes (pulsecore/tagstruct.h:36-75).
const char TAG_STRING = 't';
const char TAG_STRING_NULL = 'N';
const char TAG_U32 = 'L';
const char TAG_U8 = 'B';
const char TAG_U64 = 'R';
const char TAG_S64 = 'r';
const char TAG_SAMPLE_SPEC = 'a';
const char TAG_ARBITRARY = 'x';
const char TAG_BOOLEAN_TRUE = '1';
const char TAG_BOOLEAN_FALSE = '0';
const char TAG_USEC = 'U';
const char TAG_CHANNEL_MAP = 'm';
const char TAG_CVOLUME = 'v';
const char TAG_PROPLIST = 'P';
const char TAG_VOLUME = 'V';
const char TAG_FORMAT_INFO = 'f';

// Subscription masks (def.h:533-568). A mask bit is 1 << facility.
const uint MASK_SINK = 0x0001;
const uint MASK_SOURCE = 0x0002;
const uint MASK_SINK_INPUT = 0x0004;
const uint MASK_SOURCE_OUTPUT = 0x0008;
const uint MASK_SERVER = 0x0080;
const uint MASK_CARD = 0x0200;

// Subscription event: low nibble facility, then the type bits (def.h:574-618).
const uint EVENT_FACILITY_MASK = 0x000F;
const uint EVENT_TYPE_MASK = 0x0030;
const uint EVENT_CHANGE = 0x0010;
const uint EVENT_REMOVE = 0x0020;
const uint FACILITY_SINK = 0x0000;
const uint FACILITY_SOURCE = 0x0001;
const uint FACILITY_SINK_INPUT = 0x0002;
const uint FACILITY_SOURCE_OUTPUT = 0x0003;
const uint FACILITY_SERVER = 0x0007;
const uint FACILITY_CARD = 0x0009;

<*
 Command numbers (native-common.h). Only the ones this library sends or reads.
*>
constset PulseCommand : uint
{
	ERROR = 0,
	REPLY = 2,
	AUTH = 45,
	SET_CLIENT_NAME = 46,
	GET_SERVER_INFO = 58,
	GET_SINK_INFO_LIST = 60,
	GET_SOURCE_INFO_LIST = 62,
	GET_SINK_INPUT_INFO_LIST = 68,
	GET_SOURCE_OUTPUT_INFO_LIST = 70,
	SUBSCRIBE = 73,
	SET_SINK_VOLUME = 75,
	SET_SINK_INPUT_VOLUME = 76,
	SET_SOURCE_VOLUME = 77,
	SET_SINK_MUTE = 79,
	SET_SOURCE_MUTE = 80,
	SET_DEFAULT_SINK = 86,
	SET_DEFAULT_SOURCE = 87,
	SUBSCRIBE_EVENT = 116,
	MOVE_SINK_INPUT = 121,
	MOVE_SOURCE_OUTPUT = 122,
	SET_SINK_INPUT_MUTE = 125,
	GET_CARD_INFO_LIST = 159,
	SET_CARD_PROFILE = 160,
	SET_SINK_PORT = 171,
	SET_SOURCE_PORT = 172,
	SET_SOURCE_OUTPUT_VOLUME = 175,
	SET_SOURCE_OUTPUT_MUTE = 176,
}

<* Error codes of an ERROR reply (def.h:471-498, `pa_error_code`; PA_OK is 0). *>
constset PulseError : uint
{
	ACCESS = 1,
	COMMAND = 2,
	INVALID = 3,
	NOENTITY = 5,
	PROTOCOL = 7,
	TIMEOUT = 8,
	NOTSUPPORTED = 19,
}

<* The five words of a packet header. Offset is 64 bits, split high then low. *>
struct FrameHeader
{
	uint length;   // payload bytes after the header
	uint channel;  // CONTROL_CHANNEL for commands
	ulong offset;  // zero for commands
	uint flags;    // zero for commands
}

<* Encode a header in network order (pstream.c descriptor; crate write_descriptor). *>
fn void FrameHeader.encode(self, char[] out)
{
	put_be32_at(out, 0, self.length);
	put_be32_at(out, 4, self.channel);
	put_be32_at(out, 8, (uint)(self.offset >> 32));
	put_be32_at(out, 12, (uint)self.offset);
	put_be32_at(out, 16, self.flags);
}

<*
 Decode a header from 20 bytes. Checks only the size: the caller decides what a
 length means.

 @return? error::PROTOCOL : "fewer than FRAME_HEADER_SIZE bytes"
*>
fn FrameHeader? decode_header(char[] bytes)
{
	if (bytes.len < FRAME_HEADER_SIZE) return error::raise(error::PROTOCOL, error::Domain.PULSE, 0, "frame header is %d bytes", bytes.len)~;
	ulong high = be32_at(bytes, 8);
	return {
		.length = be32_at(bytes, 0),
		.channel = be32_at(bytes, 4),
		.offset = (high << 32) | (ulong)be32_at(bytes, 12),
		.flags = be32_at(bytes, 16),
	};
}

<* Read a big-endian u32 at `at`. The caller guarantees four bytes. *>
fn uint be32_at(char[] bytes, sz at) @inline
{
	return ((uint)bytes[at] << 24) | ((uint)bytes[at + 1] << 16) | ((uint)bytes[at + 2] << 8) | (uint)bytes[at + 3];
}

<* Write a big-endian u32 at `at`. The caller guarantees four bytes. *>
fn void put_be32_at(char[] bytes, sz at, uint value) @inline
{
	bytes[at] = (char)(value >> 24);
	bytes[at + 1] = (char)(value >> 16);
	bytes[at + 2] = (char)(value >> 8);
	bytes[at + 3] = (char)value;
}

<* Append `value` as a big-endian u32 and nothing else. *>
fn void append_raw_u32(DString* out, uint value)
{
	char[4] bytes;
	put_be32_at(bytes[..], 0, value);
	out.append_bytes(bytes[..]);
}

<* Append `value` as a big-endian u64 and nothing else. *>
fn void append_raw_u64(DString* out, ulong value)
{
	append_raw_u32(out, (uint)(value >> 32));
	append_raw_u32(out, (uint)value);
}

<*
 Start a command packet: reserves the frame header, then writes the command
 and tag words. Arguments follow with the `put_*` functions; `finish_packet`
 fills in the header.

 @param allocator : "Allocator for the packet buffer; free it with `DString.free`"
*>
fn DString begin_command(Allocator allocator, PulseCommand command, uint tag)
{
	DString packet;
	packet.init(allocator, 128);
	char[FRAME_HEADER_SIZE] reserved;
	packet.append_bytes(reserved[..]);
	put_u32(&packet, (uint)command);
	put_u32(&packet, tag);
	return packet;
}

<*
 Fill in the header of a packet made with `begin_command` and return the whole
 packet, ready to write to the socket.
*>
fn char[] finish_packet(DString* packet)
{
	char[] bytes = (char[])packet.str_view();
	FrameHeader header = { .length = (uint)(bytes.len - FRAME_HEADER_SIZE), .channel = CONTROL_CHANNEL };
	header.encode(bytes[0 : FRAME_HEADER_SIZE]);
	return bytes;
}

<* A u32 value: 'L' then four bytes. *>
fn void put_u32(DString* out, uint value)
{
	out.append_char(TAG_U32);
	append_raw_u32(out, value);
}

<* A u8 value: 'B' then one byte. *>
fn void put_u8(DString* out, char value)
{
	out.append_char(TAG_U8);
	out.append_char(value);
}

<* A u64 microsecond value: 'U' then eight bytes. *>
fn void put_usec(DString* out, ulong value)
{
	out.append_char(TAG_USEC);
	append_raw_u64(out, value);
}

<* A boolean: '1' or '0', no payload. *>
fn void put_bool(DString* out, bool value)
{
	out.append_char(value ? TAG_BOOLEAN_TRUE : TAG_BOOLEAN_FALSE);
}

<* A NUL-terminated string: 't' then the bytes and a NUL. *>
fn void put_string(DString* out, String value)
{
	out.append_char(TAG_STRING);
	out.append_string(value);
	out.append_char((char)0);
}

<* A NULL string: 'N' with no payload. Used for "no name": the server then reads the index instead. *>
fn void put_null_string(DString* out)
{
	out.append_char(TAG_STRING_NULL);
}

<*
 A channel volume: 'v', the channel count as u8, then one u32 per channel.

 @require values.len <= CHANNELS_MAX : "a volume carries at most CHANNELS_MAX channels"
*>
fn void put_cvolume(DString* out, uint[] values)
{
	out.append_char(TAG_CVOLUME);
	out.append_char((char)values.len);
	foreach (value : values) append_raw_u32(out, value);
}

<*
 A property list: 'P', then per entry the key as a string, a u32 length and an
 arbitrary blob of that length, then a NULL string as terminator
 (tagstruct.c:313-336).
*>
fn void put_proplist(DString* out, Property[] props)
{
	out.append_char(TAG_PROPLIST);
	foreach (prop : props)
	{
		put_string(out, prop.key);
		append_u32_tag(out, (uint)prop.value.len);
		put_arbitrary(out, (char[])prop.value);
	}
	put_null_string(out);
}

// A bare u32 with its tag, as used inside proplists (tagstruct.c:318-335).
fn void append_u32_tag(DString* out, uint value)
{
	out.append_char(TAG_U32);
	append_raw_u32(out, value);
}

<* Arbitrary bytes: 'x', a u32 length, then the bytes. *>
fn void put_arbitrary(DString* out, char[] bytes)
{
	out.append_char(TAG_ARBITRARY);
	append_raw_u32(out, (uint)bytes.len);
	out.append_bytes(bytes);
}

<* One key/value pair of a property list. Both slices belong to the caller. *>
struct Property
{
	String key;
	String value;
}

<* The value of `key` in `props`, or "" when the list does not have it. *>
fn String find_property(Property[] props, String key)
{
	foreach (prop : props)
	{
		if (prop.key == key) return prop.value;
	}
	return "";
}

<*
 Read side of the tagstruct. Holds a view of one packet's payload; the view and
 every slice read from it are valid while the packet is.
*>
struct TagReader
{
	char[] data;
	sz pos;
}

<* True once every byte of the payload was read. *>
fn bool TagReader.at_end(&self) @inline => self.pos >= self.data.len;

// Read `count` raw bytes. Fails when the packet is shorter than the layout says.
fn char[]? TagReader.raw(&self, sz count)
{
	if (self.data.len - self.pos < count) return error::raise(error::PROTOCOL, error::Domain.PULSE, 0, "packet ends at %d, %d bytes needed", self.data.len, count)~;
	char[] bytes = self.data[self.pos : count];
	self.pos += count;
	return bytes;
}

// Consume the next tag byte, which must be `tag`.
fn void? TagReader.expect(&self, char tag)
{
	if (self.pos >= self.data.len) return error::raise(error::PROTOCOL, error::Domain.PULSE, 0, "packet ends where tag '%d' belongs", (int)tag)~;
	char found = self.data[self.pos];
	if (found != tag) return error::raise(error::PROTOCOL, error::Domain.PULSE, 0, "tag '%d' expected, '%d' found at %d", (int)tag, (int)found, self.pos)~;
	self.pos++;
}

<* The next tag byte without consuming it, or 0 at the end of the packet. *>
fn char TagReader.peek(&self) @inline
{
	if (self.pos >= self.data.len) return 0;
	return self.data[self.pos];
}

<* A tagged u32. *>
fn uint? TagReader.u32(&self)
{
	self.expect(TAG_U32)!;
	return be32_at(self.raw(4)!, 0);
}

<* A tagged u8. *>
fn char? TagReader.u8(&self)
{
	self.expect(TAG_U8)!;
	return self.raw(1)![0];
}

<* A tagged u64 microsecond value. *>
fn ulong? TagReader.usec(&self)
{
	self.expect(TAG_USEC)!;
	char[] bytes = self.raw(8)!;
	return ((ulong)be32_at(bytes, 0) << 32) | (ulong)be32_at(bytes, 4);
}

<* A tagged boolean: '1' is true, '0' is false. *>
fn bool? TagReader.flag(&self)
{
	char tag = self.peek();
	if (tag == TAG_BOOLEAN_TRUE)
	{
		self.pos++;
		return true;
	}
	if (tag == TAG_BOOLEAN_FALSE)
	{
		self.pos++;
		return false;
	}
	return error::raise(error::PROTOCOL, error::Domain.PULSE, 0, "boolean expected, tag %d found", (int)tag)~;
}

<*
 A tagged string. The result points into the packet and excludes the NUL.
 A NULL string ('N') reads as "" so callers never see a missing name.
*>
fn String? TagReader.string(&self)
{
	if (self.peek() == TAG_STRING_NULL)
	{
		self.pos++;
		return "";
	}
	self.expect(TAG_STRING)!;
	sz start = self.pos;
	sz end = start;
	while (end < self.data.len && self.data[end] != (char)0) end++;
	if (end >= self.data.len) return error::raise(error::PROTOCOL, error::Domain.PULSE, 0, "string at %d has no terminator", start)~;
	self.pos = end + 1;
	return (String)self.data[start : end - start];
}

<* A tagged arbitrary blob: 'x', u32 length, bytes. *>
fn char[]? TagReader.arbitrary(&self)
{
	self.expect(TAG_ARBITRARY)!;
	uint length = be32_at(self.raw(4)!, 0);
	return self.raw(length);
}

<* A tagged 32-bit volume: 'V' and a u32 (PulseAudio's pa_volume_t). *>
fn uint? TagReader.volume(&self)
{
	self.expect(TAG_VOLUME)!;
	return be32_at(self.raw(4)!, 0);
}

<* A tagged sample specification: 'a', format, channel count, rate. Only the channel count is kept. *>
fn char? TagReader.sample_spec_channels(&self)
{
	self.expect(TAG_SAMPLE_SPEC)!;
	char[] bytes = self.raw(6)!;
	return bytes[1];
}

<* Channel positions of a channel map: 'm', count as u8, one u8 position per channel. *>
struct ChannelMap
{
	uint count;
	char[CHANNELS_MAX] positions;
}

<* Read a channel map. @return? error::PROTOCOL : "more channels than CHANNELS_MAX" *>
fn ChannelMap? TagReader.channel_map(&self)
{
	self.expect(TAG_CHANNEL_MAP)!;
	uint count = (uint)self.raw(1)![0];
	if (count > CHANNELS_MAX) return error::raise(error::PROTOCOL, error::Domain.PULSE, 0, "%d channels in a map", count)~;
	ChannelMap map = { .count = count };
	char[] positions = self.raw(count)!;
	for (sz i = 0; i < count; i++) map.positions[i] = positions[i];
	return map;
}

<* Channel volumes as read from the packet: 'v', count as u8, one u32 per channel. *>
struct CVolume
{
	uint count;
	uint[CHANNELS_MAX] values;
}

<* Read a channel volume. @return? error::PROTOCOL : "more channels than CHANNELS_MAX" *>
fn CVolume? TagReader.cvolume(&self)
{
	self.expect(TAG_CVOLUME)!;
	uint count = (uint)self.raw(1)![0];
	if (count > CHANNELS_MAX) return error::raise(error::PROTOCOL, error::Domain.PULSE, 0, "%d channels in a volume", count)~;
	CVolume volume = { .count = count };
	for (sz i = 0; i < count; i++) volume.values[i] = be32_at(self.raw(4)!, 0);
	return volume;
}

<*
 A property list. Entries are copied into slices of `allocator`; keys and
 values still point into the packet.

 @return? error::PROTOCOL : "an entry's length and blob length disagree"
*>
fn Property[]? TagReader.proplist(&self, Allocator allocator)
{
	self.expect(TAG_PROPLIST)!;
	List{Property} props;
	props.init(allocator);
	while (self.peek() != TAG_STRING_NULL)
	{
		String key = self.string()!;
		if (key.len == 0) return error::raise(error::PROTOCOL, error::Domain.PULSE, 0, "empty proplist key")~;
		uint declared = self.u32()!;
		char[] value = self.arbitrary()!;
		if (declared != value.len) return error::raise(error::PROTOCOL, error::Domain.PULSE, 0, "proplist '%s' declares %d bytes, has %d", key, declared, value.len)~;
		props.push({ .key = key, .value = (String)value });
	}
	self.pos++;
	return props.array_view();
}

<*
 Skip a format_info (the sink's and stream's format list entries): 'f', u8
 encoding, then a property list.
*>
fn void? TagReader.skip_format_info(&self)
{
	self.expect(TAG_FORMAT_INFO)!;
	self.u8()!;
	Property[] format_props = self.proplist(tmem)!;
	(void)format_props;
}
