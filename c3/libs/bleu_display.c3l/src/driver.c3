<*
 Everything the service needs to know about one way of reading and changing displays. A backend
 file defines a `Driver` constant; `probe.c3` lists them.
*>
module bleu::display;
import bleu::availability, bleu::error, bleu::rt::worker;

<*
 One backend. `probe` is cheap and side-effect free; `create` may do the work that decides what
 the backend can do, and fills `Capabilities` truthfully.
*>
struct Driver
{
	BackendInfo info;
	Backend id;
	DriverProbeFn probe;
	DriverCreateFn create;
	DriverDestroyFn destroy;
	DisplayRunFn run;
}

alias DriverProbeFn = fn bool(Options* options);
alias DriverCreateFn = fn void*?(Allocator allocator, Options options, Capabilities* capabilities);
alias DriverDestroyFn = fn void(Allocator allocator, void* state);
alias DisplayRunFn = fn void(void* state, DisplayHub* hub, Host{Command}* host);

<* The backends of this platform in priority order; defined per platform in `probe.c3`. *>
fn Driver*? select_driver(Options options)
{
	foreach (driver : platform_drivers())
	{
		if (options.backend != AUTO && options.backend != driver.id) continue;
		if (driver.probe(&options)) return driver;
	}
	if (options.backend != AUTO) return error::UNSUPPORTED~;
	return error::UNAVAILABLE~;
}