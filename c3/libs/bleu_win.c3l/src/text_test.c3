// Unit tests for the UTF-8 / UTF-16 boundary.
module bleu::win::text;
import bleu::error;

fn void wide_round_trip_keeps_text() @test
{
	String original = "héllo €𝄞 ok";
	WideZ wide = to_wide(tmem, original)!!;
	assert(wide.len() == 12);
	assert(wide.as_wstring()[wide.len()] == 0);
	String back = from_wide(tmem, wide.as_wstring())!!;
	assert(back == original);
}

fn void wide_units_slice_round_trip() @test
{
	WideZ wide = to_wide(tmem, "abc")!!;
	assert(from_wide_units(tmem, wide.units)!! == "abc");
}

fn void invalid_utf8_is_rejected() @test
{
	String bad = "\xff\xfe";
	if (catch e = to_wide(tmem, bad)) { assert(e == error::INVALID_ARGUMENT); return; }
	unreachable("invalid UTF-8 was accepted");
}

fn void null_wide_string_is_rejected() @test
{
	if (catch e = from_wide(tmem, null)) { assert(e == error::INVALID_ARGUMENT); return; }
	unreachable("a null wide string was accepted");
}
