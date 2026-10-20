module bleu::ipc::wire_test @feat(POSIX);
import bleu::ipc::wire, std::core::test;

// Frames are heap copies handed to the test; release them after each check.
fn void release(String frame)
{
	alloc::free(mem, frame.ptr);
}

fn void escapes_quotes_backslashes_and_controls() @test
{
	wire::Writer w;
	w.init(mem, 4);
	w.put_escaped("a\"b\\c\n\r\t\x01\x1fz");
	String out = w.finish();
	test::eq(out, "a\\\"b\\\\c\\n\\r\\t\\u0001\\u001fz");
	release(out);
}

fn void utf8_bytes_pass_through_escaping() @test
{
	wire::Writer w;
	w.init(mem, 4);
	w.put_escaped("caf\xc3\xa9 \xe2\x82\xac");
	String out = w.finish();
	test::eq(out, "caf\xc3\xa9 \xe2\x82\xac");
	release(out);
}

fn void longs_print_in_decimal_including_the_extremes() @test
{
	wire::Writer w;
	w.init(mem, 4);
	w.put_long(0);
	w.put_char(' ');
	w.put_long(-7);
	w.put_char(' ');
	// 2^53 is the largest integer a JavaScript client can hold exactly.
	w.put_long(9007199254740992);
	w.put_char(' ');
	w.put_long(long::min);
	String out = w.finish();
	test::eq(out, "0 -7 9007199254740992 -9223372036854775808");
	release(out);
}

fn void result_frame_omits_a_zero_id_and_keeps_others() @test
{
	String zero = wire::result_frame(mem, 0, "{\"pong\":true}");
	test::eq(zero, "{\"result\":{\"pong\":true}}\n");
	release(zero);

	String id = wire::result_frame(mem, 9007199254740992, "null");
	test::eq(id, "{\"id\":9007199254740992,\"result\":null}\n");
	release(id);
}

fn void error_frame_escapes_its_message() @test
{
	String frame = wire::error_frame(mem, 3, "unknown method: a\"b");
	test::eq(frame, "{\"id\":3,\"error\":\"unknown method: a\\\"b\"}\n");
	release(frame);

	String invalid = wire::error_frame(mem, 0, "invalid json: unexpected end of JSON input");
	test::eq(invalid, "{\"error\":\"invalid json: unexpected end of JSON input\"}\n");
	release(invalid);
}

fn void service_frame_carries_the_id_and_the_data_verbatim() @test
{
	String frame = wire::service_frame(mem, 12, "network", "{\"wifiEnabled\":true}");
	test::eq(frame, "{\"id\":12,\"result\":{\"service\":\"network\",\"data\":{\"wifiEnabled\":true}}}\n");
	release(frame);
}

fn void server_info_lists_capabilities_in_order() @test
{
	String[2] caps = { "network", "bluetooth" };
	String info    = wire::server_info(mem, 38, caps[..]);
	test::eq(info, "{\"apiVersion\":38,\"capabilities\":[\"network\",\"bluetooth\"]}");
	release(info);

	String none = wire::server_info(mem, 1, { });
	test::eq(none, "{\"apiVersion\":1,\"capabilities\":[]}");
	release(none);
}

fn void single_line_rule_rejects_empty_and_newlines() @test
{
	test::@check(wire::is_single_line("{}"));
	test::@check(!wire::is_single_line(""));
	test::@check(!wire::is_single_line("{\n}"));
}

fn void utf8_accepts_well_formed_sequences() @test
{
	// ASCII, two-, three- and four-byte sequences, and the edges of each range.
	test::@check(wire::valid_utf8("plain ascii"));
	test::@check(wire::valid_utf8("\xc2\x80")); // U+0080
	test::@check(wire::valid_utf8("\xdf\xbf")); // U+07FF
	test::@check(wire::valid_utf8("\xe0\xa0\x80")); // U+0800
	test::@check(wire::valid_utf8("\xed\x9f\xbf")); // U+D7FF
	test::@check(wire::valid_utf8("\xee\x80\x80")); // U+E000
	test::@check(wire::valid_utf8("\xf0\x90\x80\x80")); // U+10000
	test::@check(wire::valid_utf8("\xf4\x8f\xbf\xbf")); // U+10FFFF
}

fn void utf8_rejects_overlong_surrogate_and_out_of_range_forms() @test
{
	test::@check(!wire::valid_utf8("\x80")); // lone continuation byte
	test::@check(!wire::valid_utf8("\xc0\x80")); // overlong NUL
	test::@check(!wire::valid_utf8("\xe0\x80\x80")); // overlong three-byte
	test::@check(!wire::valid_utf8("\xf0\x80\x80\x80")); // overlong four-byte
	test::@check(!wire::valid_utf8("\xed\xa0\x80")); // U+D800, a surrogate
	test::@check(!wire::valid_utf8("\xf4\x90\x80\x80")); // U+110000
	test::@check(!wire::valid_utf8("\xf5\x80\x80\x80")); // lead byte above F4
	test::@check(!wire::valid_utf8("\xff"));
	test::@check(!wire::valid_utf8("\xe2\x82")); // truncated three-byte
	test::@check(!wire::valid_utf8("\xe2\x41\xac")); // continuation missing
}