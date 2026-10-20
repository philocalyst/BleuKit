// The monitor side on its own: what `MockMonitor` answers to a well-formed request,
// what it ignores, and what the fault counters do. The bytes are the wire frames
// worked out in docs/research/bleu_ddc.md, recomputed independently in Python.
module bleu::ddc::mock_test;
import std::core::mem, std::time, bleu::error, bleu::ddc::mock, bleu::ddc::packet, bleu::ddc::transport, bleu::ddc::vcp;

fn bool equal_bytes(char[] a, char[] b) @private
{
	return a.len == b.len && mem::equals(a.ptr, b.ptr, a.len);
}

fn void unknown_code_is_answered_with_result_0x01() @test
{
	@pool()
	{
		mock::MockMonitor m = mock::new_monitor("(vcp(10))");
		Transport t         = &m;
		char[8] request;
		usz n               = packet::get_vcp((vcp::VcpCode)0x77).encode_i2c(request[..])!!;
		t.write(request[0:n])!!;
		char[11] reply;
		usz got           = t.read(reply[..], time::ms(100))!!;
		char[11] expected = { 0x6E, 0x88, 0x02, 0x01, 0x77, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC2 };
		test::eq(got, (usz)11);
		test::eq(equal_bytes(reply[0:got], expected[..]), true);
	};
}

fn void wrong_checksum_request_gets_no_answer() @test
{
	@pool()
	{
		mock::MockMonitor m = mock::new_monitor("(vcp(10))");
		m.add_feature(vcp::VcpCode.LUMINANCE, 1, 2);
		Transport t     = &m;
		// A correct Get VCP request for 0x10 with the checksum byte changed.
		char[5] request = { 0x51, 0x82, 0x01, 0x10, 0xAD };
		t.write(request[..])!!;
		char[11] reply;
		test::eq(t.read(reply[..], time::ms(100))!!, (usz)0);
		test::eq(m.bad_requests, (uint)1);
	};
}

fn void save_is_counted() @test
{
	@pool()
	{
		mock::MockMonitor m = mock::new_monitor("(vcp(10))");
		Transport t         = &m;
		char[4] request     = { 0x51, 0x81, 0x0C, 0xB2 };
		t.write(request[..])!!;
		test::eq(m.saves, (uint)1);
	};
}

fn void dropped_reply_reads_as_nothing() @test
{
	@pool()
	{
		mock::MockMonitor m = mock::new_monitor("(vcp(10))");
		m.add_feature(vcp::VcpCode.LUMINANCE, 1, 2);
		m.drop_replies = 1;
		Transport t     = &m;
		char[5] request = { 0x51, 0x82, 0x01, 0x10, 0xAC };
		t.write(request[..])!!;
		char[11] reply;
		test::eq(t.read(reply[..], time::ms(100))!!, (usz)0);
	};
}

fn void refused_write_is_a_fault() @test
{
	@pool()
	{
		mock::MockMonitor m = mock::new_monitor("(vcp(10))");
		m.fail_writes = 1;
		Transport t     = &m;
		char[4] request = { 0x51, 0x81, 0x0C, 0xB2 };
		test::@error(t.write(request[..]), error::BACKEND_FAILURE);
	};
}