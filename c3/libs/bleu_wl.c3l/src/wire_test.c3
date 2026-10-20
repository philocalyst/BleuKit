module bleu::wl::wire_test;
import bleu::wl::wire, bleu::error, std::core::test;

// Expected bytes were computed independently with Python's struct module, and agree with
// the layouts described in wire.c3 (see docs/research/bleu_wl.md, section "Wire format").
fn void expect_bytes(char[] actual, char[] expected)
{
	test::eq((sz)actual.len, (sz)expected.len);
	foreach (i, b : expected) test::eq(actual[i], b);
}

fn void golden_get_registry() @test
{
	wire::Writer w;
	w.begin(1, 1);
	w.put_uint(2)!!;
	char[12] expected = { 1, 0, 0, 0, 1, 0, 12, 0, 2, 0, 0, 0 };
	expect_bytes(w.finish(), expected[..]);
}

fn void golden_global_with_padded_string() @test
{
	wire::Writer w;
	w.begin(2, 0);
	w.put_uint(1)!!;
	w.put_string("wl_output")!!;
	w.put_uint(4)!!;
	char[32] expected = {
		2, 0, 0, 0, 0, 0, 32, 0, 1, 0, 0, 0, 10, 0, 0, 0,
		'w', 'l', '_', 'o', 'u', 't', 'p', 'u', 't', 0, 0, 0,
		4, 0, 0, 0,
	};
	expect_bytes(w.finish(), expected[..]);
}

fn void golden_scalars() @test
{
	wire::Writer w;
	w.begin(7, 3);
	w.put_fixed(wire::fixed_from_double(1.5))!!;
	w.put_int(-1)!!;
	w.put_array({ 1, 2, 3 })!!;
	w.put_nullable_string("")!!;
	w.put_string("")!!;
	char[36] expected = {
		7, 0, 0, 0, 3, 0, 36, 0,
		0x80, 1, 0, 0,
		0xFF, 0xFF, 0xFF, 0xFF,
		3, 0, 0, 0, 1, 2, 3, 0,
		0, 0, 0, 0,
		1, 0, 0, 0, 0, 0, 0, 0,
	};
	expect_bytes(w.finish(), expected[..]);
}

fn void reader_decodes_golden_global() @test
{
	char[32] bytes = {
		2, 0, 0, 0, 0, 0, 32, 0, 1, 0, 0, 0, 10, 0, 0, 0,
		'w', 'l', '_', 'o', 'u', 't', 'p', 'u', 't', 0, 0, 0,
		4, 0, 0, 0,
	};
	wire::FdQueue fds;
	wire::Frame frame = wire::read_frame(bytes[..])!!;
	test::eq(frame.complete, true);
	test::eq(frame.object, 2u);
	test::eq(frame.opcode, (ushort)0);
	wire::Reader r = { .data = frame.payload(bytes[..]), .pos = 0, .fds = &fds };
	test::eq(r.get_uint()!!, 1u);
	test::eq(r.get_string()!!, "wl_output");
	test::eq(r.get_uint()!!, 4u);
	r.expect_end()!!;
}

fn void reader_rejects_malformed_strings() @test
{
	wire::FdQueue fds;
	// No NUL: length 3 holds "abc".
	char[8] no_nul = { 3, 0, 0, 0, 'a', 'b', 'c', 0 };
	wire::Reader a = { .data = no_nul[..], .pos = 0, .fds = &fds };
	test::@error(a.get_string(), error::PROTOCOL);
	// Interior NUL: "a\0b" with its terminator.
	char[8] interior = { 4, 0, 0, 0, 'a', 0, 'b', 0 };
	wire::Reader b = { .data = interior[..], .pos = 0, .fds = &fds };
	test::@error(b.get_string(), error::PROTOCOL);
	// Length runs past the message.
	char[8] overrun = { 100, 0, 0, 0, 'a', 0, 0, 0 };
	wire::Reader c = { .data = overrun[..], .pos = 0, .fds = &fds };
	test::@error(c.get_string(), error::PROTOCOL);
}

fn void reader_rejects_short_and_trailing_data() @test
{
	wire::FdQueue fds;
	char[2] short_bytes = { 1, 0 };
	wire::Reader a = { .data = short_bytes[..], .pos = 0, .fds = &fds };
	test::@error(a.get_uint(), error::PROTOCOL);
	char[8] trailing = { 1, 0, 0, 0, 9, 9, 9, 9 };
	wire::Reader b = { .data = trailing[..], .pos = 0, .fds = &fds };
	test::eq(b.get_uint()!!, 1u);
	test::@error(b.expect_end(), error::PROTOCOL);
}

fn void reader_takes_descriptors_in_order() @test
{
	wire::FdQueue fds;
	fds.push(11)!!;
	fds.push(12)!!;
	char[] none;
	wire::Reader r = { .data = none[..], .pos = 0, .fds = &fds };
	test::eq(r.get_fd()!!, 11);
	test::eq(r.get_fd()!!, 12);
	test::@error(r.get_fd(), error::PROTOCOL);
}

fn void frame_header_rules() @test
{
	char[8] header = { 1, 0, 0, 0, 1, 0, 4, 0 };
	// Size 4 is below the header.
	test::@error(wire::read_frame(header[..]), error::PROTOCOL);
	char[8] odd = { 1, 0, 0, 0, 1, 0, 10, 0 };
	test::@error(wire::read_frame(odd[..]), error::PROTOCOL);
	char[8] huge = { 1, 0, 0, 0, 0, 0x20, 0, 0 };
	test::@error(wire::read_frame(huge[..]), error::PROTOCOL);
	char[8] whole = { 1, 0, 0, 0, 1, 0, 8, 0 };
	test::eq(wire::read_frame(whole[..])!!.complete, true);
	char[4] partial_header = { 1, 0, 0, 0 };
	test::eq(wire::read_frame(partial_header[..])!!.complete, false);
	char[8] partial_body = { 1, 0, 0, 0, 0, 0, 16, 0 };
	test::eq(wire::read_frame(partial_body[..])!!.complete, false);
}

fn void writer_refuses_oversized_messages() @test
{
	wire::Writer w;
	w.begin(1, 0);
	char[4000] big;
	w.put_array(big[..])!!;
	test::@error(w.put_array(big[..]), error::INVALID_ARGUMENT);
}

fn void writer_limits_descriptors() @test
{
	wire::Writer w;
	w.begin(1, 0);
	for (usz i = 0; i < wire::MAX_FDS_PER_MESSAGE; i++) w.put_fd(3)!!;
	test::@error(w.put_fd(3), error::INVALID_ARGUMENT);
}

fn void fd_queue_is_bounded() @test
{
	wire::FdQueue fds;
	for (usz i = 0; i < wire::MAX_QUEUED_FDS; i++) fds.push(4)!!;
	test::@error(fds.push(4), error::PROTOCOL);
}

// xorshift64: a fixed-seed generator, so every run tries the same inputs.
fn ulong next_random(ulong* state)
{
	ulong s = *state;
	s ^= s << 13;
	s ^= s >> 7;
	s ^= s << 17;
	*state = s;
	return s;
}

// Decode one buffer as if it held a wl_registry.global event: (uint, string, uint).
// Returns true when every argument decoded and nothing was left over. Errors are the
// expected outcome for random input; the test is that none of them crashes.
fn bool decode_attempt(char[] bytes)
{
	if (try frame = wire::read_frame(bytes))
	{
		if (!frame.complete) return false;
		wire::FdQueue fds;
		wire::Reader r = { .data = frame.payload(bytes), .pos = 0, .fds = &fds };
		return decode_arguments(&r);
	}
	return false;
}

fn bool decode_arguments(wire::Reader* r)
{
	if (catch r.get_uint()) return false;
	if (catch r.get_string()) return false;
	if (catch r.get_uint()) return false;
	if (catch r.expect_end()) return false;
	return true;
}

fn void fuzz_random_buffers() @test
{
	ulong state = 0x9E3779B97F4A7C15;
	char[64] buf;
	usz accepted = 0;
	for (usz round = 0; round < 20000; round++)
	{
		usz length = (usz)(next_random(&state) % 65);
		for (usz i = 0; i < length; i++) buf[i] = (char)next_random(&state);
		if (decode_attempt(buf[0 : length])) accepted++;
	}
	// Random bytes almost never form a valid message; a handful may by chance.
	test::eq(accepted < 200, true);
}

fn void fuzz_mutated_valid_message() @test
{
	char[32] golden = {
		2, 0, 0, 0, 0, 0, 32, 0, 1, 0, 0, 0, 10, 0, 0, 0,
		'w', 'l', '_', 'o', 'u', 't', 'p', 'u', 't', 0, 0, 0,
		4, 0, 0, 0,
	};
	test::eq(decode_attempt(golden[..]), true);
	ulong state = 0xD1B54A32D192ED03;
	for (usz round = 0; round < 20000; round++)
	{
		char[32] buf = golden;
		usz flips = 1 + (usz)(next_random(&state) % 3);
		for (usz k = 0; k < flips; k++)
		{
			usz at = (usz)(next_random(&state) % 32);
			buf[at] = (char)next_random(&state);
		}
		usz length = (usz)(next_random(&state) % 33);
		decode_attempt(buf[0 : length]);
	}
}
