// Golden bytes for the PulseAudio wire codec. Every expected value below is
// worked out by hand from the layouts in pulse_wire.c3 and pulse_requests.c3
// (which cite the upstream sources); none is copied from the encoder's output.
// Spaces in the hex strings are ignored.
module bleu::audio::pulse_test;
import bleu::audio::pulse, bleu::error;

// The value of one hex digit.
fn int nibble(char c) @private
{
	if (c >= '0' && c <= '9') return (int)c - (int)'0';
	if (c >= 'a' && c <= 'f') return (int)c - (int)'a' + 10;
	return (int)c - (int)'A' + 10;
}

// True when `actual` is exactly the bytes written as hex pairs in `hex`.
fn bool matches(char[] actual, String hex) @private
{
	sz count = 0;
	int high = -1;
	for (sz i = 0; i < hex.len; i++)
	{
		char c = hex[i];
		if (c == ' ') continue;
		int value = nibble(c);
		if (high < 0)
		{
			high = value;
			continue;
		}
		if (count >= actual.len || (char)(high * 16 + value) != actual[count]) return false;
		count++;
		high = -1;
	}
	return high < 0 && count == actual.len;
}

// Build the packet for a request and compare it with its golden bytes.
fn bool packet_is(DString* packet, String hex) @private
{
	bool same = matches(pulse::finish_packet(packet), hex);
	packet.free();
	return same;
}

// The header is five big-endian words: length, channel, offset high, offset low, flags.
fn void frame_header_is_five_big_endian_words() @test
{
	char[pulse::FRAME_HEADER_SIZE] out;
	pulse::FrameHeader header = { .length = 10, .channel = pulse::CONTROL_CHANNEL, .offset = 0, .flags = 0 };
	header.encode(out[..]);
	assert(matches(out[..], "0000000a ffffffff 00000000 00000000 00000000"));
	pulse::FrameHeader back = pulse::decode_header(out[..])!!;
	assert(back.length == 10 && back.channel == pulse::CONTROL_CHANNEL && back.offset == 0);
}

// A 64-bit offset is split into its high and low words, high first.
fn void frame_header_offset_is_split_high_then_low() @test
{
	char[pulse::FRAME_HEADER_SIZE] out;
	pulse::FrameHeader header = { .length = 1, .channel = 2, .offset = 0x0102030405060708, .flags = 0x40000000 };
	header.encode(out[..]);
	assert(matches(out[..], "00000001 00000002 01020304 05060708 40000000"));
	assert(@catch(pulse::decode_header(out[0 : 19])) == error::PROTOCOL);
}

// GET_SERVER_INFO with tag 3: command 20 (the position of the name in the enum), tag 3.
fn void get_server_info_request_is_two_words() @test
{
	DString packet = pulse::request_empty(mem, pulse::PulseCommand.GET_SERVER_INFO, 3);
	assert(packet_is(&packet, "0000000a ffffffff 00000000 00000000 00000000 4c00000014 4c00000003"));
}

// AUTH: command 8, tag 1, the version 35 with no flags, then the cookie as an arbitrary blob.
fn void auth_request_carries_version_and_cookie() @test
{
	char[] cookie = { (char)0xAB, (char)0xCD };
	DString packet = pulse::request_auth(mem, 1, cookie);
	assert(packet_is(&packet, "00000016 ffffffff 00000000 00000000 00000000 4c00000008 4c00000001 4c00000023 7800000002 abcd"));
}

// SET_CLIENT_NAME: the proplist is P, the key as a string, a u32 length, the value as an
// arbitrary blob, and an N string as terminator.
fn void set_client_name_encodes_the_proplist() @test
{
	Property[1] props = { { .key = "application.name", .value = "x" } };
	DString packet = pulse::request_set_client_name(mem, 2, props[..]);
	assert(packet_is(&packet, "00000029 ffffffff 00000000 00000000 00000000 4c00000009 4c00000002 50 74 6170706c69636174696f6e2e6e616d6500 4c00000001 7800000001 78 4e"));
}

// SET_SINK_VOLUME by name: index NO_INDEX, the name, then one channel at 100 % (0x10000).
fn void set_device_volume_by_name() @test
{
	uint[1] values = { 0x10000 };
	DString packet = pulse::request_set_device_volume(mem, 4, false, pulse::NO_INDEX, "s", values[..]);
	assert(packet_is(&packet, "00000018 ffffffff 00000000 00000000 00000000 4c00000024 4c00000004 4cffffffff 747300 760100010000"));
}

// MOVE_SINK_INPUT by index: the device name is always on the wire; an empty one is N.
fn void move_stream_sends_a_null_name_for_index_addressing() @test
{
	DString packet = pulse::request_move_stream(mem, 5, false, 7, pulse::NO_INDEX, "");
	assert(packet_is(&packet, "00000015 ffffffff 00000000 00000000 00000000 4c00000043 4c00000005 4c00000007 4cffffffff 4e"));
}

// Decoding: each tagged value reads back, and a NULL string reads as "".
fn void tagged_values_decode() @test
{
	char[] bytes = { 'L', 0x12, 0x34, 0x56, 0x78, 't', 'a', 'b', 0, 'N', '1', '0', 'U', 0, 0, 0, 0, 0, 0, 1, 0 };
	pulse::TagReader r = { .data = bytes };
	assert(r.u32()!! == 0x12345678);
	assert(r.string()!! == "ab");
	assert(r.string()!! == "");
	assert(r.flag()!! == true);
	assert(r.flag()!! == false);
	assert(r.usec()!! == 256);
	assert(r.at_end());
}

// A channel volume: count as u8, then one u32 per channel.
fn void cvolume_decodes_per_channel() @test
{
	char[] bytes = { 'v', 2, 0, 1, 0, 0, 0, 0, 0, 0 };
	pulse::TagReader r = { .data = bytes };
	pulse::CVolume v = r.cvolume()!!;
	assert(v.count == 2 && v.values[0] == 0x10000 && v.values[1] == 0);
}

// A proplist of one entry decodes to its key and value; the length is checked against the blob.
fn void proplist_decodes_entries() @test
{
	char[] bytes = { 'P', 't', 'k', 0, 'L', 0, 0, 0, 2, 'x', 0, 0, 0, 2, 'h', 'i', 'N' };
	pulse::TagReader r = { .data = bytes };
	pulse::Property[] props = r.proplist(mem)!!;
	assert(props.len == 1 && props[0].key == "k" && props[0].value == "hi");
	assert(pulse::find_property(props, "k") == "hi" && pulse::find_property(props, "z") == "");
	alloc::free(mem, props.ptr);
}

// A declared length that does not match the blob is a protocol error, not silently trusted.
fn void proplist_length_mismatch_is_refused() @test
{
	char[] bytes = { 'P', 't', 'k', 0, 'L', 0, 0, 0, 3, 'x', 0, 0, 0, 2, 'h', 'i', 'N' };
	pulse::TagReader r = { .data = bytes };
	assert(@catch(r.proplist(mem)) == error::PROTOCOL);
}

// A tag that does not match is refused with the tag in the message.
fn void wrong_tag_is_refused() @test
{
	char[] bytes = { 'B', 1 };
	pulse::TagReader r = { .data = bytes };
	assert(@catch(r.u32()) == error::PROTOCOL);
}
