module bleu::session;
import bleu::availability, bleu::error, bleu::rt::worker;

<*
 Everything the service needs to know about one way of reading the session.
 A backend file defines a `Driver` constant; `probe.c3` lists them.
*>
struct Driver
{
	BackendInfo info;
	Backend id;
	<*
	 Cheap check that the backend can work here, without starting anything.
	*>
	DriverProbeFn probe;
	DriverCreateFn create;
	DriverDestroyFn destroy;
	SessionRunFn run;
}

alias DriverProbeFn = fn bool(Options* options);
alias DriverCreateFn = fn void*?(Allocator allocator, Options options, Capabilities* capabilities);
alias DriverDestroyFn = fn void(Allocator allocator, void* state);
alias SessionRunFn = fn void(void* state, SessionHub* hub, Host{Command}* host);

<* The backends of this platform in priority order; defined per platform in `probe.c3`. *>
fn Driver*? select_driver(Options options)
{
	bool listed = false; // the forced backend exists on this platform, whether or not it runs
	foreach (driver : platform_drivers())
	{
		if (options.backend != AUTO && options.backend != driver.id) continue;
		listed = true;
		if (driver.probe(&options)) return driver;
	}
	if (options.backend != AUTO && !listed) return error::UNSUPPORTED~;
	return error::UNAVAILABLE~;
}
