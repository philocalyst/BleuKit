module bleu::rt::worker_test;
import bleu::rt::worker, bleu::rt::poller, bleu::error, std::core::test, std::time;

// What the test worker reports back: filled in on the worker thread, read by
// the test after `stop` has joined that thread.
struct Tally
{
	int sum;
	int seen;
}

// Takes commands until stopped, sleeping in a poller on the wake-up in between,
// then drains whatever was still queued.
fn void tally_until_stopped(void* context, worker::Host{int}* host)
{
	Tally* tally = (Tally*)context;
	poller::Poller waiter;
	waiter.init(mem, host.wakeup(), 0)!!;
	defer waiter.free();
	int[8] buffer;
	while (true)
	{
		usz taken = host.mailbox().take_all(buffer[..]);
		for (usz i = 0; i < taken; i++)
		{
			tally.sum += buffer[i];
			tally.seen++;
		}
		if (host.stopping())
		{
			while (host.mailbox().pending() > 0)
			{
				taken = host.mailbox().take_all(buffer[..]);
				for (usz i = 0; i < taken; i++)
				{
					tally.sum += buffer[i];
					tally.seen++;
				}
			}
			return;
		}
		if (taken == 0) waiter.wait()!!;
	}
}

fn void worker_runs_commands_and_stops_cleanly() @test
{
	worker::Worker{int} w;
	w.init(mem, 256)!!;
	defer w.free();
	Tally tally;
	w.start("tally", &tally_until_stopped, &tally)!!;
	for (int i = 1; i <= 100; i++) w.mailbox.post(i)!!;
	w.stop();
	// Every command posted before `stop` was processed, on the worker, before join.
	test::eq(100, tally.seen);
	test::eq(5050, tally.sum);
	// `stop` is idempotent, a stopped worker cannot restart, and refuses commands.
	w.stop();
	test::@error(w.start("again", &tally_until_stopped, &tally), error::INVALID_STATE);
	test::@error(w.mailbox.post(1), error::UNAVAILABLE);
}