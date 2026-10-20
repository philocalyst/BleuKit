module bleu::rt::timers_test;
import bleu::rt::timers, bleu::error, std::core::test, std::thread, std::time;

fn void timers_fire_in_due_order() @test
{
	timers::TimerQueue queue;
	queue.init(mem);
	defer queue.free();
	// The due times are taken when each timer is scheduled, so the gaps must exceed the time
	// between two schedule calls (much more than 1ms under valgrind): 2 is due at 10ms, 3 at
	// 60ms and 1 at 110ms, and the test sleeps past all of them.
	queue.schedule(1, time::ms(110))!!;
	queue.schedule(2, time::ms(10))!!;
	queue.schedule(3, time::ms(60))!!;
	test::@check(queue.next_timeout() <= time::ms(10), "the earliest timer is at most 10ms away");
	thread::sleep(time::ms(200))!!;
	usz[4] fired;
	usz n = queue.pop_expired(fired[..]);
	test::eq((usz)3, n);
	test::eq((usz)2, fired[0]);
	test::eq((usz)3, fired[1]);
	test::eq((usz)1, fired[2]);
	test::@check(queue.next_timeout() == time::FOREVER, "no timers left means an infinite timeout");
}

fn void timers_cancel_and_reject_duplicates() @test
{
	timers::TimerQueue queue;
	queue.init(mem);
	defer queue.free();
	queue.schedule(7, time::SEC)!!;
	test::@error(queue.schedule(7, time::SEC), error::INVALID_ARGUMENT);
	queue.cancel(7)!!;
	test::@error(queue.cancel(7), NOT_FOUND);
	usz[1] fired;
	test::eq((usz)0, queue.pop_expired(fired[..]));
}

fn void repeating_timers_rearm() @test
{
	timers::TimerQueue queue;
	queue.init(mem);
	defer queue.free();
	queue.schedule_repeating(9, time::ms(1))!!;
	usz[1] fired;
	usz total = 0;
	// Wait until it has fired at least twice, bounded so that a broken queue fails
	// instead of hanging.
	for (int attempt = 0; attempt < 1000 && total < 2; attempt++)
	{
		thread::sleep(time::ms(1))!!;
		total += queue.pop_expired(fired[..]);
	}
	test::@check(total >= 2, "a repeating timer must fire again after each period");
	test::eq((usz)9, fired[0]);
	queue.cancel(9)!!;
}
fn void a_repeating_timer_needs_a_positive_period() @test
{
	timers::TimerQueue queue;
	queue.init(mem);
	defer queue.free();
	test::@error(queue.schedule_repeating(4, time::DURATION_ZERO), error::INVALID_ARGUMENT);
	test::@check(queue.next_timeout() == time::FOREVER, "a refused timer was not queued");
}