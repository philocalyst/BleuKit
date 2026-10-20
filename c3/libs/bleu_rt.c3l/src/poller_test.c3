module bleu::rt::poller_test;
import bleu::rt::wakeup, bleu::rt::poller, bleu::rt::foreign, bleu::error, std::core::test, std::thread, std::time;

// Signals the wake-up from another thread after a short delay, the way a foreign
// callback would. The thread body runs `@foreign_entry`, like every entry point.
fn int signal_after_delay(void* arg)
{
	wakeup::Wakeup* wake = (wakeup::Wakeup*)arg;
	foreign::@foreign_entry()
	{
		thread::sleep(time::ms(5))!!;
		wake.signal()!!;
	};
	return 0;
}

fn void wait_times_out_until_signalled_from_another_thread() @test
{
	wakeup::Wakeup wake;
	wake.init()!!;
	defer wake.close();
	poller::Poller waiter;
	waiter.init(mem, &wake, 0)!!;
	defer waiter.free();

	test::@error(waiter.wait(time::ms(5)), TIMEOUT);

	Thread signaller;
	signaller.create(&signal_after_delay, &wake)!!;
	poller::Ready[] ready = waiter.wait(time::SEC * 5)!!;
	signaller.join()!!;
	test::eq((sz)1, ready.len);
	test::eq(poller::WAKEUP_TAG, ready[0].tag);
	// The poller drained the wake-up: nothing is pending now.
	test::@error(waiter.wait(time::ms(5)), TIMEOUT);
}

fn void many_signals_coalesce_into_one_wakeup() @test
{
	wakeup::Wakeup wake;
	wake.init()!!;
	defer wake.close();
	for (int i = 0; i < 10; i++) wake.signal()!!;
	poller::Poller waiter;
	waiter.init(mem, &wake, 0)!!;
	defer waiter.free();
	poller::Ready[] ready = waiter.wait()!!;
	test::eq((sz)1, ready.len);
	test::@error(waiter.wait(time::ms(5)), TIMEOUT);
}

fn void sources_must_have_unique_tags() @test
{
	wakeup::Wakeup wake;
	wake.init()!!;
	defer wake.close();
	poller::Poller waiter;
	waiter.init(mem, &wake, 2)!!;
	defer waiter.free();
	waiter.add({ .handle = wake.native(), .interest = { .readable = true }, .tag = 3 })!!;
	test::@error(waiter.add({ .handle = wake.native(), .interest = { }, .tag = 3 }), error::INVALID_ARGUMENT);
	test::@error(
		waiter.add({ .handle = wake.native(), .interest = { }, .tag = poller::WAKEUP_TAG }),
		error::INVALID_ARGUMENT
	);
	waiter.add({ .handle = wake.native(), .interest = { }, .tag = 4 })!!;
	test::@error(waiter.add({ .handle = wake.native(), .interest = { }, .tag = 5 }), error::OUT_OF_RANGE);
	waiter.remove(3)!!;
	test::@error(waiter.remove(3), NOT_FOUND);
}