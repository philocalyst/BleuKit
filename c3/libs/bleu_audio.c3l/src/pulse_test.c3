// Golden bytes for the PulseAudio wire codec. Every expected value below is
// worked out by hand from the layouts in pulse_wire.c3 (which cite the upstream
// sources), not copied from the encoder's output.
module bleu::audio::pulse_test;
import bleu::audio::pulse, bleu::error;

// Compare a packet with the bytes written out in hex in the test.
fn bool is_bytes(char[] actual, String expected_hex) @private
{
	// expected_hex: pairs of hex digits, spaces ignored
	usz digits = 0;
	for (usz i = 0; i < expected_hex.len; i++)
	{
		if (expected_hex[i] != ' ') digits++;
	}
	if (digits != actual.len * 2) return false;
	usz at = 0;
	usz byte_index = 0;
	int high = -1;
	for (usz i = 0; i < expected_hex.len; i++)
	{
		char c = expected_hex[i];
		if (c == ' ') continue;
		int value = c >= '0' && c <= '9' ? c - '0' : (c >= 'a' && c <= 'f' ? c - 'a' + 10 : c - 'A' + 10);
		if (high < 0)
		{
			high = value;
			continue;
		}
		if ((char)((high << 4) | value) != actual[byte_index]) return false;
		byte_index++;
		high = -1;
		at++;
	}
	return true;
}

// The header is five big-endian words: length, channel, offset high, offset low, flags.
fn void frame_header_is_five_big_endian_words() @test
{
	char[pulse::FRAME_HEADER_SIZE] out;
	pulse::FrameHeader header = { .length = 10, .channel = pulse::CONTROL_CHANNEL, .offset = 0, .flags = 0 };
	header.encode(out[..]);
	assert(is_bytes(out[..], "00000000A FFFFFFFF 00000000 00000000 00000000"[0 : 0] ?? "" == "" ? "" : "0000000a ffffffff 00000000 00000000 00000000"));
}
