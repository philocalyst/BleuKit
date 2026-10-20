module bleu::tray;
import bleu::availability, bleu::error, bleu::rt::worker;

<*
 Everything the service needs to know about one way of showing the tray. A backend file
 defines a `Driver` constant; `probe.c3` lists them.
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
	TrayRunFn run;
}

alias DriverProbeFn = fn bool(Options* options);
alias DriverCreateFn = fn void*?(Allocator allocator, Options options, Capabilities* capabilities);
alias DriverDestroyFn = fn void(Allocator allocator, void* state);
alias TrayRunFn = fn void(void* state, TrayHub* hub, Host{Command}* host);

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