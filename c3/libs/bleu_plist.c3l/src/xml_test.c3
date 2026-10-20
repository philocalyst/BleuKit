// Tests for the XML reader and writer: golden comparisons with Python's
// plistlib, malformed input, and round trips.
module bleu::plist::xml;
import bleu::error, bleu::plist::value, std::core::test;

fn void sample_matches_plistlib() @test
{
	String text = $embed("../fixtures/sample.plist");
	String expected = $embed("../fixtures/sample.plist.canon");
	Value root = parse(tmem, text)!!;
	test::eq(expected.trim("\n"), value::canonical(tmem, &root));
}

fn void handwritten_document_matches_plistlib() @test
{
	String text = $embed("../fixtures/handwritten.plist");
	String expected = $embed("../fixtures/handwritten.plist.canon");
	Value root = parse(tmem, text)!!;
	test::eq(expected.trim("\n"), value::canonical(tmem, &root));
}

fn void byte_order_mark_is_skipped() @test
{
	Value root = parse(tmem, "\xEF\xBB\xBF<plist><string>x</string></plist>")!!;
	test::eq("x", root.as_string()!!);
}

fn void malformed_documents_are_refused() @test
{
	test::@error(parse(tmem, "not xml at all"), error::PROTOCOL);
	test::@error(parse(tmem, "<plist><string>a</plist>"), error::PROTOCOL);
	test::@error(parse(tmem, "<root><string>a</string></root>"), error::PROTOCOL);
	test::@error(parse(tmem, "<plist><string>a</string><string>b</string></plist>"), error::PROTOCOL);
	test::@error(parse(tmem, "<plist></plist>"), error::PROTOCOL);
	test::@error(parse(tmem, "<plist><blob>x</blob></plist>"), error::PROTOCOL);
	test::@error(parse(tmem, "<plist><integer>12x</integer></plist>"), error::PROTOCOL);
	test::@error(parse(tmem, "<plist><integer>9223372036854775808</integer></plist>"), error::PROTOCOL);
	test::@error(parse(tmem, "<plist><real>abc</real></plist>"), error::PROTOCOL);
	test::@error(parse(tmem, "<plist><date>2013-02-30T00:00:00Z</date></plist>"), error::PROTOCOL);
	test::@error(parse(tmem, "<plist><data>@@@@</data></plist>"), error::PROTOCOL);
	test::@error(parse(tmem, "<plist><true>x</true></plist>"), error::PROTOCOL);
	test::@error(parse(tmem, "<plist><string>a<integer>1</integer></string></plist>"), error::PROTOCOL);
	test::@error(parse(tmem, "<plist><dict><string>a</string></dict></plist>"), error::PROTOCOL);
	test::@error(parse(tmem, "<plist><dict><key>a</key></dict></plist>"), error::PROTOCOL);
	test::@error(parse(tmem, "<plist><dict><key>a</key><integer>1</integer><key>a</key><integer>2</integer></dict></plist>"), error::PROTOCOL);
}

fn void nesting_is_limited() @test
{
	DString deep;
	deep.init(tmem);
	deep.append_string("<plist>");
	for (int i = 0; i <= value::MAX_NESTING; i++) deep.append_string("<array>");
	for (int i = 0; i <= value::MAX_NESTING; i++) deep.append_string("</array>");
	deep.append_string("</plist>");
	test::@error(parse(tmem, deep.str_view()), error::PROTOCOL);
}

fn void entities_and_whitespace_are_kept() @test
{
	Value root = parse(tmem, "<plist><string>  a &amp; b  </string></plist>")!!;
	test::eq("  a & b  ", root.as_string()!!);
}

fn void writer_round_trips_the_sample() @test
{
	String text = $embed("../fixtures/sample.plist");
	Value first = parse(tmem, text)!!;
	String written = write(tmem, &first)!!;
	Value second = parse(tmem, written)!!;
	test::eq(value::canonical(tmem, &first), value::canonical(tmem, &second));
}

fn void writer_escapes_and_formats() @test
{
	Value text = { .kind = STRING, .text = "a<b>&c\r" };
	String written = write(tmem, &text)!!;
	test::@check(written.contains("<string>a&lt;b&gt;&amp;c&#xD;</string>"), "markup is escaped");
	Value tenth = { .kind = REAL, .real = 0.1 };
	test::@check(write(tmem, &tenth)!!.contains("<real>0.1</real>"), "shortest real");
	Value date = { .kind = DATE, .date = 393589080.0 };
	test::@check(write(tmem, &date)!!.contains("<date>2013-06-22T10:18:00Z</date>"), "ISO date");
}

fn void writer_refuses_what_xml_cannot_hold() @test
{
	Value control = { .kind = STRING, .text = "bell\x07" };
	test::@error(write(tmem, &control), error::INVALID_ARGUMENT);
	// The quiet NaN bit pattern; the standard library has no NaN constant.
	Value nan = { .kind = REAL, .real = bitcast((ulong)0x7FF8000000000000, double) };
	test::@error(write(tmem, &nan), error::INVALID_ARGUMENT);
}
