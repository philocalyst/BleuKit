// Golden vectors for DDC/CI framing. Each expected byte string is derived in
// docs/research/bleu_ddc.md (sections "Framing" and "Checksums") from the
// ddcutil test vectors and the XOR rules, and was recomputed independently in
// Python. The checksum is the one all three open-source implementations use.
module bleu::ddc::packet_test;
import std::core::mem, bleu::error, bleu::ddc::packet, bleu::ddc::vcp;

fn bool same_bytes(char[] a, char[] b) @private
{
	return a.len == b.len && mem::equals(a.ptr, b.ptr, a.len);
}

fn void checksums_match_ddcutil() @test
{
	// ddcutil test vectors: requests seed with 0x6E (the first byte is included).
	test::eq(packet::checksum(packet::WRITE_ADDRESS, { 0x51, 0x82, 0xF5, 0x01 }), (char)0x49);
	test::eq(packet::checksum(packet::WRITE_ADDRESS, { 0x51, 0x81, 0xB1 }), (char)0x0F);
	// Replies: seed 0x50 over {0x6E, ...}; ddcutil `{0x6f,0x6e,0x82,0xa1,0x00} -> 0x1d` and `{0x6f,0x6e,0x80} -> 0xbe`.
	test::eq(packet::checksum(packet::VIRTUAL_HOST, { 0x6E, 0x82, 0xA1, 0x00 }), (char)0x1D);
	test::eq(packet::checksum(packet::VIRTUAL_HOST, { 0x6E, 0x80 }), (char)0xBE);
}

fn void get_vcp_i2c_form() @test
{
	char[8] out;
	usz n = packet::get_vcp(vcp::VcpCode.LUMINANCE).encode_i2c(out[..])!!;
	char[5] expected = { 0x51, 0x82, 0x01, 0x10, 0xAC };
	test::eq(n, (usz)5);
	test::eq(same_bytes(out[0:n], expected[..]), true);
}

fn void set_vcp_i2c_form() @test
{
	char[8] out;
	usz n = packet::set_vcp(vcp::VcpCode.LUMINANCE, 50).encode_i2c(out[..])!!;
	char[7] expected = { 0x51, 0x84, 0x03, 0x10, 0x00, 0x32, 0x9A };
	test::eq(n, (usz)7);
	test::eq(same_bytes(out[0:n], expected[..]), true);
}

fn void set_vcp_value_is_big_endian() @test
{
	char[8] out;
	usz n = packet::set_vcp(vcp::VcpCode.CONTRAST, 0x1234).encode_i2c(out[..])!!;
	// Payload 03 12 12 34: the high byte comes first.
	test::eq(out[4], (char)0x12);
	test::eq(out[5], (char)0x34);
	test::eq(n, (usz)7);
}

fn void capabilities_request_offset() @test
{
	char[8] out;
	usz n = packet::capabilities_request(0x0100).encode_i2c(out[..])!!;
	char[6] expected = { 0x51, 0x83, 0xF3, 0x01, 0x00, 0x4E };
	test::eq(n, (usz)6);
	test::eq(same_bytes(out[0:n], expected[..]), true);
}

fn void save_settings_i2c_form() @test
{
	char[8] out;
	usz n = packet::save_settings().encode_i2c(out[..])!!;
	char[4] expected = { 0x51, 0x81, 0x0C, 0xB2 };
	test::eq(n, (usz)4);
	test::eq(same_bytes(out[0:n], expected[..]), true);
}

fn void frame_form_starts_with_destination() @test
{
	char[8] out;
	usz n = packet::get_vcp(vcp::VcpCode.LUMINANCE).encode_frame(out[..])!!;
	char[6] expected = { 0x6E, 0x51, 0x82, 0x01, 0x10, 0xAC };
	test::eq(n, (usz)6);
	test::eq(same_bytes(out[0:n], expected[..]), true);
	// The frame checksum (XOR over everything, 0x6E included) equals the I2C checksum.
	test::eq(packet::checksum(0, out[0:5]), out[5]);
}

fn void encode_rejects_small_buffer() @test
{
	char[4] out;
	test::@error(packet::get_vcp(vcp::VcpCode.LUMINANCE).encode_i2c(out[..]), error::INVALID_ARGUMENT);
	test::@error(packet::set_vcp(vcp::VcpCode.LUMINANCE, 1).encode_frame(out[..]), error::INVALID_ARGUMENT);
}

fn void parse_get_vcp_reply() @test
{
	// Luminance 50 of 100, set-parameter (DDC/CI 4.3). Checksum 0xF2 derived in the research note.
	char[11] bytes = { 0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2 };
	packet::Reply r = packet::parse_reply(bytes[..])!!;
	test::eq(r.kind, packet::ReplyKind.GET_VCP);
	test::eq(r.code, vcp::VcpCode.LUMINANCE);
	test::eq(r.momentary, false);
	test::eq(r.current, (ushort)50);
	test::eq(r.maximum, (ushort)100);
}

fn void parse_momentary_reply_and_high_low_bytes() @test
{
	// Type 0x01 (momentary); maximum 0x0102 (MH=01, ML=02); present 0x0304 (SH=03, SL=04).
	char[11] bytes = { 0x6E, 0x88, 0x02, 0x00, 0xD6, 0x01, 0x01, 0x02, 0x03, 0x04, 0x00 };
	bytes[10] = packet::checksum(packet::VIRTUAL_HOST, bytes[:10]);
	packet::Reply r = packet::parse_reply(bytes[..])!!;
	test::eq(r.momentary, true);
	test::eq(r.maximum, (ushort)0x0102);
	test::eq(r.current, (ushort)0x0304);
}

fn void unsupported_vcp_is_an_excuse() @test
{
	char[11] bytes = { 0x6E, 0x88, 0x02, 0x01, 0xAB, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1E };
	test::@error(packet::parse_reply(bytes[..]), error::UNSUPPORTED);
}

fn void bad_checksum_is_protocol() @test
{
	char[11] bytes = { 0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF3 };
	test::@error(packet::parse_reply(bytes[..]), error::PROTOCOL);
}

fn void short_and_truncated_replies_are_protocol() @test
{
	char[3] short_bytes = { 0x6E, 0x88, 0x02 };
	test::@error(packet::parse_reply(short_bytes[..]), error::PROTOCOL);
	// Declares 8 payload bytes but carries 5 after the length.
	char[6] truncated = { 0x6E, 0x88, 0x02, 0x00, 0x10, 0x00 };
	test::@error(packet::parse_reply(truncated[..]), error::PROTOCOL);
}

fn void wrong_source_is_protocol() @test
{
	// 0x6F is the read address, not the source the monitor replies from (0x6E).
	char[11] bytes = { 0x6F, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2 };
	test::@error(packet::parse_reply(bytes[..]), error::PROTOCOL);
}

fn void get_vcp_reply_needs_eight_bytes() @test
{
	// Length 7 with a valid checksum: the Get VCP layout requires exactly 8 payload bytes.
	char[10] bytes = { 0x6E, 0x87, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0xCF };
	test::@error(packet::parse_reply(bytes[..]), error::PROTOCOL);
}

fn void null_message() @test
{
	char[3] null_bytes = { 0x6E, 0x80, 0xBE };
	packet::Reply r = packet::parse_reply(null_bytes[..])!!;
	test::eq(r.kind, packet::ReplyKind.NULL_MESSAGE);
	char[3] bad = { 0x6E, 0x80, 0xBF };
	test::@error(packet::parse_reply(bad[..]), error::PROTOCOL);
}

fn void duplicate_leading_destination_is_skipped() @test
{
	char[12] bytes = { 0x6E, 0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2 };
	packet::Reply r = packet::parse_reply(bytes[..])!!;
	test::eq(r.current, (ushort)50);
}

fn void capabilities_fragment_reply() @test
{
	char[12] bytes = { 0x6E, 0x89, 0xE3, 0x00, 0x00, 0x28, 0x70, 0x72, 0x6F, 0x74, 0x28, 0x4D };
	packet::Reply r = packet::parse_reply(bytes[..])!!;
	test::eq(r.kind, packet::ReplyKind.CAPABILITIES_FRAGMENT);
	test::eq(r.offset, (ushort)0);
	test::eq(r.fragment_len, (usz)6);
	char[6] expected = { 0x28, 0x70, 0x72, 0x6F, 0x74, 0x28 };
	test::eq(same_bytes(r.fragment[0:6], expected[..]), true);
}

fn void capabilities_end_of_string() @test
{
	char[6] bytes = { 0x6E, 0x83, 0xE3, 0x00, 0x06, 0x58 };
	packet::Reply r = packet::parse_reply(bytes[..])!!;
	test::eq(r.kind, packet::ReplyKind.CAPABILITIES_FRAGMENT);
	test::eq(r.offset, (ushort)6);
	test::eq(r.fragment_len, (usz)0);
}

fn void unexpected_opcode_is_protocol() @test
{
	// Table read reply (0xE4) is not implemented by this module: it must not be mistaken for another reply.
	char[8] bytes = { 0x6E, 0x85, 0xE4, 0x00, 0x00, 0x01, 0x02, 0x5C };
	test::@error(packet::parse_reply(bytes[..]), error::PROTOCOL);
}

fn void encode_reply_roundtrip() @test
{
	char[11] out;
	char[8] payload = { 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32 };
	usz n = packet::encode_reply(payload[..], out[..])!!;
	test::eq(n, (usz)11);
	char[11] expected = { 0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2 };
	test::eq(same_bytes(out[0:n], expected[..]), true);
	packet::Reply r = packet::parse_reply(out[0:n])!!;
	test::eq(r.current, (ushort)50);
}
