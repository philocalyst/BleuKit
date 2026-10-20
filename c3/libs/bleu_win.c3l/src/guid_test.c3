// Unit tests for the platform-neutral GUID code. Run with
// `c3c --libdir libs --lib bleu_core --lib bleu_win compile-test libs/bleu_win.c3l/src/guid_test.c3`.
module bleu::win::guid;
import std::io, bleu::error;

fn void guid_literal_matches_fields() @test
{
	const Guid IID = guid("2f13c006-a03a-5f69-b090-75a43e33423e");
	Guid fields    = make(0x2f13c006, 0xa03a, 0x5f69, 0xb0, 0x90, 0x75, 0xa4, 0x3e, 0x33, 0x42, 0x3e);
	assert(IID.equals(fields));
	assert(IID.data1 == 0x2f13c006);
	assert(IID.data4[7] == 0x3e);
}

fn void guid_parse_accepts_braces_and_case() @test
{
	Guid a = parse("{00000000-0000-0000-C000-000000000046}")!!;
	assert(a.equals(guid("00000000-0000-0000-c000-000000000046")));
	assert(a.data4[0] == 0xc0 && a.data4[7] == 0x46);
	assert(NIL.equals(parse("00000000-0000-0000-0000-000000000000")!!));
}

fn void expect_rejected(String text) @local
{
	if (catch e = parse(text))
	{
		assert(e == error::INVALID_ARGUMENT);
		return;
	}
	unreachable("a malformed GUID was accepted");
}

fn void guid_parse_rejects_malformed() @test
{
	expect_rejected("");
	expect_rejected("2f13c006a03a5f69b09075a43e33423e");
	expect_rejected("2f13c006-a03a-5f69-b090-75a43e3342zz");
	expect_rejected("2f13c006-a03a-5f69-b090x75a43e33423e");
	expect_rejected("{2f13c006-a03a-5f69-b090-75a43e33423e");
}

fn void guid_format_round_trips() @test
{
	Guid g      = guid("2f13c006-a03a-5f69-b090-75a43e33423e");
	String text = g.format(tmem);
	assert(text == "{2F13C006-A03A-5F69-B090-75A43E33423E}");
	assert(parse(text)!!.equals(g));
}

fn void guid_compare_orders_by_bytes() @test
{
	Guid lo = guid("00000000-0000-0000-0000-000000000001");
	Guid hi = guid("00000000-0000-0000-0000-000000000002");
	assert(lo.compare(hi) < 0);
	assert(hi.compare(lo) > 0);
	assert(lo.compare(lo) == 0);
}

fn void guid_layout_is_sixteen_bytes() @test
{
	assert(Guid::size == 16);
	assert(Guid::alignment == 4);
}