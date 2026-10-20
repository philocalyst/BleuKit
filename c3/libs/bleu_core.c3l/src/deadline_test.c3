module bleu::deadline_test;
import bleu::deadline, std::core::test, std::thread, std::time, std::time::clock;

fn void unbounded_never_expires() @test
{
	Deadline forever = deadline::after(time::FOREVER);
	test::@check(!forever.expired(), "FOREVER does not expire");
	test::@check(forever.remaining() == time::FOREVER, "FOREVER reports an infinite remainder");
}

fn void zero_timeout_is_already_expired() @test
{
	Deadline now = deadline::after(time::DURATION_ZERO);
	test::@check(now.expired(), "a zero timeout has expired at once");
	test::@check(now.remaining() == time::DURATION_ZERO, "nothing remains");
}

fn void a_future_deadline_expires_on_the_monotonic_clock() @test
{
	Deadline soon = deadline::after(time::ms(20));
	test::@check(!soon.expired(), "20 ms is not over yet");
	Duration left = soon.remaining();
	test::@check(left > time::DURATION_ZERO && left <= time::ms(20), "the remainder is within the timeout");
	thread::sleep(time::ms(30))!!;
	test::@check(soon.expired(), "after 30 ms the 20 ms deadline has passed");
	test::@check(soon.remaining() == time::DURATION_ZERO, "an expired deadline has nothing left");
}

fn void a_long_timeout_does_not_wrap_into_the_past() @test
{
	// About 30 years: the sum with the monotonic clock must not overflow into an early expiry.
	Deadline far = deadline::after((Duration)946_080_000_000_000);
	test::@check(!far.expired(), "a 30-year deadline is not already past");
	test::@check(far.remaining() > time::SEC * 86400, "a 30-year deadline leaves more than a day");
}

fn void wait_on_an_expired_deadline_returns_at_once() @test
{
	Mutex mutex;
	mutex.init()!!;
	defer mutex.destroy();
	ConditionVariable cond;
	cond.init()!!;
	defer cond.destroy();
	Deadline gone = deadline::after(time::DURATION_ZERO);
	mutex.lock()!!;
	test::@check(!gone.wait(&cond, &mutex), "wait reports the expired deadline without blocking");
	mutex.unlock();
}

fn void wait_gives_up_when_nothing_signals() @test
{
	Mutex mutex;
	mutex.init()!!;
	defer mutex.destroy();
	ConditionVariable cond;
	cond.init()!!;
	defer cond.destroy();
	Deadline soon = deadline::after(time::ms(5));
	mutex.lock()!!;
	while (soon.wait(&cond, &mutex))
	{
	}
	mutex.unlock();
	test::@check(soon.expired(), "the loop ends only when the deadline passed");
}