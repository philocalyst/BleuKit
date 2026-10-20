// The logind backend must refuse, not fake a session, when org.freedesktop.login1 has no owner.
// run.sh runs this after it has stopped the mock, on the same private bus.
module bleu::session::logind_absent_test @feat(LINUX);
import bleu::error, bleu::session;

fn void refuses_without_the_name() @test
{
	if (catch err = session::open(mem, { .backend = LOGIND }))
	{
		assert(err == error::UNAVAILABLE, "no login1 owner: UNAVAILABLE");
	}
	else
	{
		unreachable("the backend opened without an owner for org.freedesktop.login1");
	}
}