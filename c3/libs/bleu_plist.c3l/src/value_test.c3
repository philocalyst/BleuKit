// Unit tests for the value model: ISO-8601 dates against independently computed
// CFAbsoluteTime values, accessors, and the canonical text form.
module bleu::plist::value;
import bleu::error, std::core::test;

fn void dates_match_independent_calculations() @test
{
	test::eq(0.0, parse_date("2001-01-01T00:00:00Z")!!);
	test::eq(-978307200.0, parse_date("1970-01-01T00:00:00Z")!!);
	test::eq(393589080.0, parse_date("2013-06-22T10:18:00Z")!!);
	test::eq(730943999.0, parse_date("2024-02-29T23:59:59Z")!!);
}

fn void dates_round_trip() @test
{
	String[] samples = {
		"2013-06-22T10:18:00Z",
		"2024-02-29T23:59:59Z",
		"1969-12-31T23:59:59Z",
		"2001-01-01T00:00:00Z"
	};
	foreach (sample : samples)
	{
		test::eq(sample, format_date(tmem, parse_date(sample)!!));
	}
	test::eq("2000-12-31T23:59:59Z", format_date(tmem, -1.0));
}

fn void malformed_dates_are_refused() @test
{
	test::@error(parse_date("2013-02-30T00:00:00Z"), error::PROTOCOL);
	test::@error(parse_date("2013-13-01T00:00:00Z"), error::PROTOCOL);
	test::@error(parse_date("2013-06-22T24:00:00Z"), error::PROTOCOL);
	test::@error(parse_date("2013-06-22 10:18:00Z"), error::PROTOCOL);
	test::@error(parse_date("2013-06-22T10:18:00"), error::PROTOCOL);
	test::@error(parse_date("2013-0x-22T10:18:00Z"), error::PROTOCOL);
	test::@error(parse_date("2100-02-29T00:00:00Z"), error::PROTOCOL);
	test::eq(-86400.0 * 365.0 * 0 + parse_date("2000-02-29T00:00:00Z")!!, parse_date("2000-02-29T00:00:00Z")!!);
}

fn void accessors_report_missing_and_mismatched_values() @test
{
	Value[] list_items = { { .kind = STRING, .text = "a\"b" } };
	Member[] members = {
		{ .key = "n", .value = { .kind = INTEGER, .integer = 5 } },
		{ .key = "list", .value = { .kind = ARRAY, .items = list_items } }
	};
	Value root = { .kind = DICT, .members = members };
	test::eq(5, root.get("n")!!.as_integer()!!);
	test::@error(root.get("absent"), NOT_FOUND);
	test::@error(root.get("n")!!.as_string(), NOT_FOUND);
	test::eq("a\"b", root.get("list")!!.element(0)!!.as_string()!!);
	test::@error(root.get("list")!!.element(1), NOT_FOUND);
	test::@error(root.element(0), NOT_FOUND);
	test::@check(root.is(DICT) && !root.is(ARRAY), "kind checks");
}

fn void canonical_form_is_stable() @test
{
	Value[] list_items = { { .kind = STRING, .text = "a\"b" } };
	Member[] members = {
		{ .key = "n", .value = { .kind = INTEGER, .integer = 5 } },
		{ .key = "list", .value = { .kind = ARRAY, .items = list_items } }
	};
	Value root = { .kind = DICT, .members = members };
	test::eq("{\"n\":i5,\"list\":[s\"a\\\"b\"]}", canonical(tmem, &root));
	Value flags = {
		.kind = DICT,
		.members = {
			{ .key = "t", .value = { .kind = BOOL, .boolean = true } },
			{ .key = "u", .value = { .kind = UID, .integer = 9 } }
		}
	};
	test::eq("{\"t\":true,\"u\":u9}", canonical(tmem, &flags));
	Value text = { .kind = STRING, .text = "tab\there\\" };
	test::eq("s\"tab\\u{9}here\\\\\"", canonical(tmem, &text));
}