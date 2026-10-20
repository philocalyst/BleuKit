// Tests for the UTF-8 decoder and checker: well-formed sequences are accepted, and
// every RFC 3629 refusal (overlong forms, surrogates, out-of-range values, bad
// continuation bytes, truncation) is an error rather than a wrong code point.
module bleu::plist::text;
import bleu::error, std::core::test;

// Whether `bytes` passes `check_utf8`.
fn bool is_utf8(String bytes) @local
{
	if (catch err = check_utf8(bytes)) return false;
	return true;
}

fn void well_formed_utf8_is_accepted() @test
{
	test::@check(is_utf8("abc"), "ASCII");
	test::@check(is_utf8("\xC3\xA9"), "U+00E9, two bytes");
	test::@check(is_utf8("\xE2\x82\xAC"), "U+20AC, three bytes");
	test::@check(is_utf8("\xF0\x9F\x98\x80"), "U+1F600, four bytes");
	test::@check(is_utf8("\xED\x9F\xBF"), "U+D7FF, the last code point before the surrogates");
	test::@check(is_utf8("\xF4\x8F\xBF\xBF"), "U+10FFFF, the last code point");
}

fn void malformed_utf8_is_refused() @test
{
	test::@check(!is_utf8("\x80"), "a lone continuation byte");
	test::@check(!is_utf8("\xFF"), "a byte that never occurs in UTF-8");
	test::@check(!is_utf8("\xC0\x80"), "an overlong NUL");
	test::@check(!is_utf8("\xE0\x80\x80"), "an overlong three-byte form");
	test::@check(!is_utf8("\xED\xA0\x80"), "an encoded surrogate U+D800");
	test::@check(!is_utf8("\xED\xBF\xBF"), "an encoded surrogate U+DFFF");
	test::@check(!is_utf8("\xF4\x90\x80\x80"), "U+110000, above the last code point");
	test::@check(!is_utf8("\xF5\x80\x80\x80"), "a lead byte above F4");
	test::@check(!is_utf8("\xE2\x82"), "a sequence cut short");
	test::@check(!is_utf8("\xC3\x28"), "a missing continuation byte");
}

fn void decoding_reports_value_and_width() @test
{
	CodePoint euro = decode_at("\xE2\x82\xAC", 0)!!;
	test::eq((uint)0x20AC, euro.value);
	test::eq((usz)3, euro.width);
	CodePoint ascii = decode_at("xy", 1)!!;
	test::eq((uint)'y', ascii.value);
	test::eq((usz)1, ascii.width);
}