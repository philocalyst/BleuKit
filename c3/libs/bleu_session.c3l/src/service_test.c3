// Regression test for the shutdown rule: a request queued when its backend stops must complete, not hang.
module bleu::session::service_test;
import std::thread, std::time, bleu::availability, bleu::error, bleu::rt::worker, bleu::session;

<* A backend that never takes its commands: it only waits for the stop, like a worker stuck in its loop. *>
fn void waits_without_taking(void* state, SessionHub* hub, Host{Command}* host) @local
{
	while (!host.stopping())
	{
		if (catch thread::sleep((Duration)1_000))
		{
			// Interrupted: check the stop flag again.
		}
	}
}

fn void queued_requests_are_completed_when_the_backend_stops() @test
{
	session::Session svc;
	svc.allocator = mem;
	svc.capabilities.init(availability::YES);
	svc.hub.start(mem, "session", "fake", &waits_without_taking, null, abandon: &session::abandon_command)!!;
	SessionOperation* operation = svc.lock()!!;
	defer operation.release();
	// The request is queued and never taken: stopping the backend must hand it to abandon.
	svc.hub.stop();
	if (catch err = operation.wait((Duration)2_000_000))
	{
		assert(err == error::DISCONNECTED, "the abandoned request fails with DISCONNECTED");
		return;
	}
	unreachable("a request queued at shutdown must not succeed");
}
