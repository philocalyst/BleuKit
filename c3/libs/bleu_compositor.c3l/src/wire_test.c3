module bleu::compositor::wire_test @feat(POSIX);
import bleu::compositor::wire, bleu::error, std::core::test, std::collections::object;

fn void lines_are_taken_across_partial_feeds() @test
{
	wire::Buffer buffer;
	buffer.init(mem, 64);
	defer buffer.free();
	buffer.feed("ab")!!;
	test::@error(buffer.take_line(), NOT_FOUND);
	buffer.feed("c\nde")!!;
	String first = buffer.take_line()!!;
	test::@check(first == "abc", "first line must be 'abc'");
	test::@error(buffer.take_line(), NOT_FOUND);
	buffer.feed("f\nxy\n")!!;
	test::@check(buffer.take_line()!! == "def", "the split line must join up");
	test::@check(buffer.take_line()!! == "xy", "two lines in one feed must both come out");
	test::@error(buffer.take_line(), NOT_FOUND);
}

fn void a_line_longer_than_the_buffer_is_refused() @test
{
	wire::Buffer buffer;
	buffer.init(mem, 8);
	defer buffer.free();
	test::eq((usz)8, buffer.feed("12345678")!!);
	test::@error(buffer.feed("9"), error::PROTOCOL);
}

fn void units_wait_for_all_their_bytes() @test
{
	wire::Buffer buffer;
	buffer.init(mem, 32);
	defer buffer.free();
	buffer.feed("abcdef")!!;
	test::@error(buffer.peek_exact(7), NOT_FOUND);
	test::@check(buffer.peek_exact(4)!! == "abcd", "a peek must not consume");
	buffer.consume(4);
	test::eq((usz)2, buffer.pending());
}

fn void comma_fields_keep_commas_in_the_last_field() @test
{
	String payload = "0x55,3,kitty,Log: a, b";
	test::@check(wire::nth_field(payload, 0, 4)!! == "0x55", "field 0");
	test::@check(wire::nth_field(payload, 2, 4)!! == "kitty", "field 2");
	test::@check(wire::nth_field(payload, 3, 4)!! == "Log: a, b", "the last field keeps its commas");
	test::@check(
		wire::nth_field(payload, 1, 2)!! == "3,kitty,Log: a, b",
		"a field count of 2 leaves the rest in field 1"
	);
	test::@check(wire::nth_field(payload, 0, 1)!! == payload, "a count of 1 is the whole payload");
	test::@error(wire::nth_field("only", 1, 2), NOT_FOUND);
}

fn void ids_are_checked_before_they_reach_a_command() @test
{
	test::@check(wire::is_decimal("42"), "digits are a decimal id");
	test::@check(!wire::is_decimal("4 2"), "a space is not");
	test::@check(!wire::is_decimal("-1"), "a sign is not");
	test::@check(!wire::is_decimal(""), "empty is not");
	test::@check(wire::is_token("0x55d1c0a4e2b0"), "a Hyprland address is a token");
	test::@check(!wire::is_token("0x1,address:0x2"), "a comma would change the dispatch");
	test::@check(!wire::is_token("a b"), "a space would split the dispatch");
	test::@check(wire::is_quotable("2:web"), "a plain workspace name can be quoted");
	test::@check(!wire::is_quotable("say \"hi\""), "a double quote cannot be quoted in sway");
}

fn void json_accessors_fall_back_on_the_wrong_type() @test
{
	@pool()
	{
		Object* root = wire::parse_document("{\"name\": [1], \"count\": \"x\", \"list\": {\"a\": 1}}", "test")!!;
		test::@check(wire::peek(root, "name", "none") == "none", "an array where text is expected falls back");
		test::eq((long)-1, wire::integer_member(root, "count", -1));
		test::@check(!wire::optional_integer(root, "missing").has_value, "a missing member is absent");
		test::@error(wire::array_member(root, "list"), error::PROTOCOL);
		test::eq((sz)0, wire::length(root));
	};
}

fn void invalid_json_is_a_protocol_error() @test
{
	@pool()
	{
		test::@error(wire::parse_document("{\"a\": ", "test"), error::PROTOCOL);
		test::@error(wire::parse_document("[1, 2] tail", "test"), error::PROTOCOL);
	};
}

fn void a_line_split_over_several_feeds_is_found_when_it_completes() @test
{
	wire::Buffer buffer;
	buffer.init(mem, 16);
	defer buffer.free();
	buffer.feed("ab")!!;
	test::@error(buffer.take_line(), NOT_FOUND);
	buffer.feed("cd")!!;
	test::@error(buffer.take_line(), NOT_FOUND);
	buffer.feed("e\nf")!!;
	test::@check(buffer.take_line()!! == "abcde", "the line joins its pieces, scanned from where the search stopped");
	test::@error(buffer.take_line(), NOT_FOUND);
	// The next feed compacts the buffer; the scan position must move with the bytes.
	buffer.feed("g\n")!!;
	test::@check(buffer.take_line()!! == "fg", "the remainder survives the compaction");
}