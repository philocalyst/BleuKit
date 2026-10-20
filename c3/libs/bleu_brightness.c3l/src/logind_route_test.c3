// The logind route's retry state, on its own: a refused route stays off for the retry interval.
module bleu::brightness::logind_route_test @feat(LINUX);
import std::time, bleu::brightness::logind;

const Duration TEN_SECONDS = (Duration)10_000_000;

fn void a_refused_route_is_off_until_its_retry_interval() @test
{
	logind::Route route;
	assert(route.usable((Duration)0), "a route never refused is usable");
	route.refuse(TEN_SECONDS);
	assert(!route.usable(TEN_SECONDS + (Duration)1_000_000), "a refused route is off at once");
	assert(route.usable(TEN_SECONDS + logind::RETRY_INTERVAL), "a refused route is tried again after the interval");
	route.refuse(TEN_SECONDS + logind::RETRY_INTERVAL);
	route.accept();
	assert(route.usable(TEN_SECONDS), "an accepted route is usable at once");
}
