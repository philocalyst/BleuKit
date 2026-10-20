// Unit tests for WinRT parameterized IIDs. The expected values are the IIDs of
// the MIDL-generated Windows SDK header (mingw-w64 windows.foundation.h, e.g.
// `IID___FIAsyncOperation_1_boolean`), so these are independent of this code.
module bleu::win::pinterface;
import bleu::win::guid, std::io;

fn void expect_iid(Guid piid, String args, String expected) @local
{
	Guid got  = instance(piid, args);
	Guid want = guid::parse(expected)!!;
	if (!got.equals(want))
	{
		io::printfn("instance(%s) = %s, want %s", args, got.format(tmem), want.format(tmem));
		unreachable("pinterface derivation mismatch");
	}
}

fn void iid_async_operation_of_bool() @test
{
	expect_iid(PIID_ASYNC_OPERATION, SIG_BOOL, "cdb5efb3-5788-509d-9be1-71ccb8a3362a");
}

fn void iid_vector_view_of_hstring() @test
{
	expect_iid(PIID_VECTOR_VIEW, SIG_STRING, "2f13c006-a03a-5f69-b090-75a43e33423e");
}

fn void iid_iterable_of_hstring() @test
{
	expect_iid(PIID_ITERABLE, SIG_STRING, "e2fcc7c1-3bfc-5a0b-b2b0-72e769d1cb7e");
}

fn void iid_async_operation_of_hstring() @test
{
	expect_iid(PIID_ASYNC_OPERATION, SIG_STRING, "3e1fe603-f897-5263-b328-0806426b8a79");
}

fn void iid_completed_handler_of_bool() @test
{
	expect_iid(PIID_ASYNC_OPERATION_COMPLETED, SIG_BOOL, "c1d3d1a2-ae17-5a5f-b5a2-bdcc8844889a");
}

fn void iid_reference_of_int32() @test
{
	expect_iid(PIID_REFERENCE, SIG_I32, "548cefbd-bc8a-5fa0-8df2-957440fc8bf4");
}

fn void iid_reference_of_bool() @test
{
	expect_iid(PIID_REFERENCE, SIG_BOOL, "3c00fd60-2950-5939-a21a-2d12c5a01b8a");
}

fn void signature_text_is_lower_case_and_braced() @test
{
	assert(interface_signature(
		guid::parse("00000000-0000-0000-C000-000000000046")!!
	) == "{00000000-0000-0000-c000-000000000046}");
}