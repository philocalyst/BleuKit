module bleu::windows_backoff_test;
import std::time, bleu::windows;

fn void waits_double_up_to_the_limit() @test
{
	windows::Backoff backoff;
	backoff.init((Duration)1_000_000, (Duration)4_000_000);
	assert(backoff.take() == (Duration)1_000_000);
	assert(backoff.take() == (Duration)2_000_000);
	assert(backoff.take() == (Duration)4_000_000);
	assert(backoff.take() == (Duration)4_000_000);
}

fn void reset_returns_to_the_first_wait() @test
{
	windows::Backoff backoff;
	backoff.init((Duration)1_000_000, (Duration)30_000_000);
	backoff.take();
	backoff.take();
	backoff.reset();
	assert(backoff.take() == (Duration)1_000_000);
}