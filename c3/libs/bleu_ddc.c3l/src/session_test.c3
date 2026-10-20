// Session tests: the protocol exchanges run against `MockMonitor`, with a
// recording sleeper, so each test checks the outcome and the exact sequence of
// waits. The expected waits are the timing policy of `session::default_options`
// (40 ms write-to-read, 50 ms between commands, 40 ms before a retry, 200 ms after
// a save), so a change to that policy shows up here.
module bleu::ddc::session_test;
import std::core::mem, std::time, bleu::error, bleu::ddc::session, bleu::ddc::mock, bleu::ddc::transport, bleu::ddc::vcp, bleu::ddc::capabilities;

const usz MAX_WAITS = 64;

<* Records the duration of every wait, in order, instead of waiting. *>
struct Recorder
{
	Duration[MAX_WAITS] waits;
	usz count;
}

fn void record(void* context, Duration duration) @private
{
	Recorder* r = (Recorder*)context;
	r.waits[r.count] = duration;
	r.count++;
}

fn Session session_for(Transport transport, Recorder* recorder) @private
{
	return session::open(transport, { .sleep = &record, .context = (void*)recorder }, session::default_options());
}

fn void get_reads_value_and_keeps_the_gap() @test
{
	@pool()
	{
		MockMonitor m = mock::new_monitor("(vcp(10))");
		m.add_feature(VcpCode.LUMINANCE, 50, 100);
		Recorder rec;
		Transport t = &m;
		Session s = session_for(t, &rec);
		session::Reading r = s.get_vcp(VcpCode.LUMINANCE)!!;
		test::eq(r.current, (ushort)50);
		test::eq(r.maximum, (ushort)100);
		test::eq(r.momentary, false);
		// Write to read 40 ms, then the 50 ms gap after the command.
		test::eq(rec.count, (usz)2);
		test::eq(rec.waits[0], time::ms(40));
		test::eq(rec.waits[1], time::ms(50));
		test::eq(s.stats.attempts, (ulong)1);
		test::eq(s.stats.operations, (ulong)1);
	};
}

fn void transport_latency_extends_the_read_wait() @test
{
	@pool()
	{
		MockMonitor m = mock::new_monitor("(vcp(10))");
		m.add_feature(VcpCode.LUMINANCE, 1, 2);
		m.latency = time::ms(60);
		Recorder rec;
		Transport t = &m;
		Session s = session_for(t, &rec);
		s.get_vcp(VcpCode.LUMINANCE)!!;
		test::eq(rec.waits[0], time::ms(60));
	};
}

fn void corrupt_reply_is_retried() @test
{
	@pool()
	{
		MockMonitor m = mock::new_monitor("(vcp(10))");
		m.add_feature(VcpCode.LUMINANCE, 7, 9);
		m.corrupt_replies = 1;
		Recorder rec;
		Transport t = &m;
		Session s = session_for(t, &rec);
		session::Reading r = s.get_vcp(VcpCode.LUMINANCE)!!;
		test::eq(r.current, (ushort)7);
		test::eq(s.stats.attempts, (ulong)2);
		test::eq(s.stats.retries, (ulong)1);
		test::eq(s.stats.protocol_errors, (ulong)1);
		// write-to-read, retry delay, write-to-read, gap.
		test::eq(rec.count, (usz)4);
		test::eq(rec.waits[1], time::ms(40));
	};
}

fn void dropped_reply_is_a_io_error_and_is_retried() @test
{
	@pool()
	{
		MockMonitor m = mock::new_monitor("(vcp(10))");
		m.add_feature(VcpCode.LUMINANCE, 7, 9);
		m.drop_replies = 1;
		Recorder rec;
		Transport t = &m;
		Session s = session_for(t, &rec);
		s.get_vcp(VcpCode.LUMINANCE)!!;
		test::eq(s.stats.io_errors, (ulong)1);
		test::eq(s.stats.retries, (ulong)1);
	};
}

fn void repeated_null_messages_mean_unsupported() @test
{
	@pool()
	{
		MockMonitor m = mock::new_monitor("(vcp(10))");
		m.add_feature(VcpCode.LUMINANCE, 7, 9);
		m.null_replies = 10;
		Recorder rec;
		Transport t = &m;
		Session s = session_for(t, &rec);
		test::@error(s.get_vcp(VcpCode.LUMINANCE), error::UNSUPPORTED);
		// max_null_replies is 3: the fourth null message is the refusal.
		test::eq(s.stats.null_replies, (ulong)4);
		test::eq(s.stats.unsupported, (ulong)1);
		test::eq(s.stats.failures, (ulong)0);
	};
}

fn void a_single_null_message_is_retried() @test
{
	@pool()
	{
		MockMonitor m = mock::new_monitor("(vcp(10))");
		m.add_feature(VcpCode.LUMINANCE, 7, 9);
		m.null_replies = 1;
		Recorder rec;
		Transport t = &m;
		Session s = session_for(t, &rec);
		session::Reading r = s.get_vcp(VcpCode.LUMINANCE)!!;
		test::eq(r.current, (ushort)7);
		test::eq(s.stats.null_replies, (ulong)1);
	};
}

fn void unsupported_code_is_final() @test
{
	@pool()
	{
		MockMonitor m = mock::new_monitor("(vcp(10))");
		Recorder rec;
		Transport t = &m;
		Session s = session_for(t, &rec);
		test::@error(s.get_vcp((VcpCode)0xE0), error::UNSUPPORTED);
		// Result 0x01 is an answer, not a fault of the channel: no retry.
		test::eq(s.stats.attempts, (ulong)1);
		test::eq(s.stats.retries, (ulong)0);
		test::eq(rec.count, (usz)1);
	};
}

fn void persistent_corruption_gives_up_after_max_tries() @test
{
	@pool()
	{
		MockMonitor m = mock::new_monitor("(vcp(10))");
		m.add_feature(VcpCode.LUMINANCE, 7, 9);
		m.corrupt_replies = 100;
		Recorder rec;
		Transport t = &m;
		Session s = session_for(t, &rec);
		test::@error(s.get_vcp(VcpCode.LUMINANCE), error::PROTOCOL);
		test::eq(s.stats.attempts, (ulong)5);
		test::eq(s.stats.protocol_errors, (ulong)5);
		test::eq(s.stats.failures, (ulong)1);
		// Five read waits and four retry delays; no gap after a failure.
		test::eq(rec.count, (usz)9);
	};
}

fn void set_then_get_reflects_the_value() @test
{
	@pool()
	{
		MockMonitor m = mock::new_monitor("(vcp(12))");
		m.add_feature(VcpCode.CONTRAST, 0, 100);
		Recorder rec;
		Transport t = &m;
		Session s = session_for(t, &rec);
		s.set_vcp(VcpCode.CONTRAST, 33)!!;
		test::eq(m.value(VcpCode.CONTRAST), (ushort)33);
		test::eq(s.get_vcp(VcpCode.CONTRAST)!!.current, (ushort)33);
	};
}

fn void set_vcp_verified_returns_the_read_back() @test
{
	@pool()
	{
		MockMonitor m = mock::new_monitor("(vcp(12))");
		m.add_feature(VcpCode.CONTRAST, 0, 100);
		Recorder rec;
		Transport t = &m;
		Session s = session_for(t, &rec);
		test::eq(s.set_vcp_verified(VcpCode.CONTRAST, 41)!!, (ushort)41);
		test::eq(s.stats.verify_mismatches, (ulong)0);
	};
}

fn void set_vcp_verified_detects_a_lagging_monitor() @test
{
	@pool()
	{
		MockMonitor m = mock::new_monitor("(vcp(12))");
		m.add_feature(VcpCode.CONTRAST, 0, 100);
		m.lag_reads = 1;
		Recorder rec;
		Transport t = &m;
		Session s = session_for(t, &rec);
		test::@error(s.set_vcp_verified(VcpCode.CONTRAST, 41), error::BACKEND_FAILURE);
		test::eq(s.stats.verify_mismatches, (ulong)1);
		// The lagging monitor applies the value after that read.
		test::eq(m.value(VcpCode.CONTRAST), (ushort)41);
	};
}

fn void refused_writes_are_retried_then_succeed() @test
{
	@pool()
	{
		MockMonitor m = mock::new_monitor("(vcp(12))");
		m.add_feature(VcpCode.CONTRAST, 0, 100);
		m.fail_writes = 2;
		Recorder rec;
		Transport t = &m;
		Session s = session_for(t, &rec);
		s.set_vcp(VcpCode.CONTRAST, 9)!!;
		test::eq(s.stats.io_errors, (ulong)2);
		test::eq(s.stats.attempts, (ulong)3);
		test::eq(m.value(VcpCode.CONTRAST), (ushort)9);
		// Two retry delays, then the gap after the set.
		test::eq(rec.count, (usz)3);
		test::eq(rec.waits[2], time::ms(50));
	};
}

fn void save_waits_for_the_settle_time() @test
{
	@pool()
	{
		MockMonitor m = mock::new_monitor("(vcp(12))");
		Recorder rec;
		Transport t = &m;
		Session s = session_for(t, &rec);
		s.save_settings()!!;
		test::eq(m.saves, (uint)1);
		test::eq(rec.count, (usz)1);
		test::eq(rec.waits[0], time::ms(200));
	};
}

const String CAPS = "(prot(monitor)type(LCD)model(Test Panel)cmds(01 02 03 07 0C F3)vcp(10 12 14(05 06 08 0B) 60(11 12 0F) D6(01 04) DF)mccs_ver(2.2))";

fn void read_capabilities_joins_fragments() @test
{
	@pool()
	{
		MockMonitor m = mock::new_monitor(CAPS);
		Recorder rec;
		Transport t = &m;
		Session s = session_for(t, &rec);
		Capabilities caps = s.read_capabilities(tmem)!!;
		test::eq(caps.validity, capabilities::Validity.VALID);
		test::eq(caps.model, "Test Panel");
		test::eq(caps.mccs_version, "2.2");
		test::eq(caps.supports(VcpCode.INPUT_SOURCE), true);
		test::eq(caps.features.len, (sz)6);
		// One request per fragment of 32 bytes, plus the empty one that ends the string.
		usz requests = (CAPS.len + 31) / 32 + 1;
		test::eq(s.stats.operations, (ulong)1);
		test::eq(rec.count, requests * 2);
	};
}

fn void read_capabilities_tolerates_a_repeated_fragment() @test
{
	@pool()
	{
		MockMonitor m = mock::new_monitor(CAPS);
		m.duplicate_fragments = 1;
		Recorder rec;
		Transport t = &m;
		Session s = session_for(t, &rec);
		Capabilities caps = s.read_capabilities(tmem)!!;
		test::eq(caps.validity, capabilities::Validity.VALID);
		test::eq(caps.features.len, (sz)6);
		test::eq(s.stats.duplicate_fragments, (ulong)1);
	};
}

fn void read_capabilities_refuses_an_endless_string() @test
{
	@pool()
	{
		MockMonitor m = mock::new_monitor(CAPS);
		Recorder rec;
		Transport t = &m;
		Options options = session::default_options();
		options.max_capabilities = 40;
		Session s = session::open(t, { .sleep = &record, .context = (void*)&rec }, options);
		test::@error(s.read_capabilities(tmem), error::OUT_OF_RANGE);
	};
}

fn void retry_of_a_null_capabilities_fragment_is_refused() @test
{
	@pool()
	{
		MockMonitor m = mock::new_monitor(CAPS);
		m.null_replies = 10;
		Recorder rec;
		Transport t = &m;
		Session s = session_for(t, &rec);
		test::@error(s.read_capabilities(tmem), error::UNSUPPORTED);
	};
}
