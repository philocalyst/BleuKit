// Live test against mock_logind.py started with BLEU_LOGIND_LATE_SESSION_SECONDS: this process is in no
// session at first, and the backend must find its session once it appears, without a reconnect.
module bleu::session::logind_late_test @feat(LINUX);
import std::time, bleu::observe, bleu::session;

// The mock publishes nothing while no session is found, so a wait must outlast the late announcement.
const Duration LATE_STEP = (Duration)10_000_000;

fn void finds_its_session_when_it_appears() @test
{
	Session* service = session::open(mem, { .backend = LOGIND })!!;
	defer service.close();
	Snapshot{State}* latest = service.wait_after(0, LATE_STEP)!!;
	for (usz i = 0; i < 3; i++)
	{
		if (latest.value.current.id == "32")
		{
			latest.release();
			return;
		}
		Snapshot{State}* next = service.wait_after(latest.generation, LATE_STEP)!!;
		latest.release();
		latest = next;
	}
	latest.release();
	unreachable("the session that appeared after the first look was never found");
}
