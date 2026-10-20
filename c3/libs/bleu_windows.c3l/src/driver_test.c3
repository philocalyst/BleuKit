module bleu::windows;
import bleu::error, std::core::test;

// A forced backend that this platform lists but whose probe fails exists here and does not
// work now: that is UNAVAILABLE, not UNSUPPORTED. The probe result depends on the session
// (a compositor may or may not be running), so the check runs only when the probe failed.
fn void a_forced_backend_whose_probe_fails_is_unavailable() @test
{
	Options options = { .backend = Backend.COMPOSITOR };
	if (catch err = select_driver(options))
	{
		test::@check(err == error::UNAVAILABLE, "a listed backend that does not work here is UNAVAILABLE");
	}
}
