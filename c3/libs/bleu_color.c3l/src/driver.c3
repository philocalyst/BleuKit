module bleu::color;
import bleu::availability, bleu::error, bleu::rt::worker;

<*
 Everything the service needs to know about one way of writing gamma ramps.
 A backend file defines a `Driver` constant; `probe.c3` lists them.
*>
struct Driver
{
	BackendInfo info;
	Backend id;
	<*
	 Cheap check that the backend can work here. Returns what it can do through `Capabilities`.
	 A probe may connect to a compositor, but it takes no gamma control.
	*>
	DriverProbeFn probe;
	DriverCreateFn create;
	DriverDestroyFn destroy;
	ColorRunFn run;
}

alias DriverProbeFn = fn bool(Options* options);
alias DriverCreateFn = fn void*?(Allocator allocator, Options options, Capabilities* capabilities);
alias DriverDestroyFn = fn void(Allocator allocator, void* state);
alias ColorRunFn = fn void(void* state, ColorHub* hub, Host{Command}* host);

<* The backends of this platform in priority order; defined per platform in `probe.c3`. *>
fn Driver*? select_driver(Options options)
{
	foreach (driver : platform_drivers())
	{
		if (options.backend != Backend.AUTO && options.backend != driver.id) continue;
		if (driver.probe(&options)) return driver;
	}
	if (options.backend != Backend.AUTO) return error::UNSUPPORTED~;
	return error::UNAVAILABLE~;
}
