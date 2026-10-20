// The real sleeper must wait at least the requested time, measured on the
// monotonic clock, so the DDC/CI gaps are never shortened by the platform.
module bleu::ddc::transport_test;
import std::time, std::time::clock, bleu::ddc::transport;

fn void real_sleeper_waits_at_least_the_duration() @test
{
	transport::Sleeper sleeper = transport::real_sleeper();
	Clock start                = clock::now();
	sleeper.sleep(sleeper.context, time::ms(20));
	Duration elapsed = (clock::now() - start).to_duration();
	test::eq(elapsed >= time::ms(20), true);
}