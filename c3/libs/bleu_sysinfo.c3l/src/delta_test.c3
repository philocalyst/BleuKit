// Arithmetic of the sampler: rates, shares, process ordering. No I/O.
module bleu::sysinfo::delta_test;
import std::core::test, std::collections::maybe, std::time, bleu::sysinfo, bleu::sysinfo::delta, bleu::sysinfo::busiest;

fn void busy_percent_from_two_readings() @test
{
	Ticks before = { .busy = 100, .total = 1000 };
	Ticks now = { .busy = 150, .total = 1100 };
	test::eq_approx((double)delta::busy_percent(before, now).value, 50.0, 4);
	test::@check(!delta::busy_percent(now, now).has_value, "no time passed: unknown, not zero");
	test::@check(!delta::busy_percent(now, before).has_value, "counters went backwards: unknown");
}

fn void byte_rate_uses_the_measured_elapsed_time() @test
{
	// 1 MB in one second, and in half a second (a late tick must not inflate the rate).
	test::eq(delta::byte_rate(0, 1_000_000, time::sec(1)).value, 1_000_000UL);
	test::eq(delta::byte_rate(0, 1_000, time::ms(500)).value, 2_000UL);
	test::@check(!delta::byte_rate(10, 5, time::sec(1)).has_value, "a counter that went back is unknown");
	test::@check(!delta::byte_rate(0, 5, time::DURATION_ZERO).has_value, "no elapsed time is unknown");
}

// 2 s of CPU time over 4 s of wall time is 50 % of one processor.
fn void process_share_is_per_processor_and_clamped() @test
{
	test::eq_approx((double)delta::process_percent(0, 200, 100, time::sec(4), 8).value, 50.0, 4);
	// 16 s of CPU in 1 s on 4 processors would be 1600 %; the ceiling is 400 %.
	test::eq_approx((double)delta::process_percent(0, 1600, 100, time::sec(1), 4).value, 400.0, 4);
	test::@check(!delta::process_percent(0, 10, 0, time::sec(1), 4).has_value, "unknown tick unit");
}

fn void process_identity_includes_its_start_time() @test
{
	ProcessTicks[] earlier = { { .pid = 7, .started = 100, .ticks = 5 } };
	test::@check(delta::find_process(earlier, 7, 100)!!.ticks == 5, "same process");
	test::@error(delta::find_process(earlier, 7, 101), NOT_FOUND);
}

fn void busiest_first_and_unknown_last() @test
{
	Process[] list = {
		{ .pid = 9, .cpu = maybe::value((Percent)10.0f) },
		{ .pid = 3 },
		{ .pid = 4, .cpu = maybe::value((Percent)10.0f) },
		{ .pid = 7, .cpu = maybe::value((Percent)55.0f) },
	};
	busiest::sort_busiest(list);
	test::eq(list[0].pid, 7);
	test::eq(list[1].pid, 4);
	test::eq(list[2].pid, 9);
	test::eq(list[3].pid, 3);
}
