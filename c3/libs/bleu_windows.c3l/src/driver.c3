module bleu::windows;
import bleu::availability, bleu::error, bleu::rt::worker;

<*
 Everything the service needs to know about one way of reading the desktop.
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
	WindowsRunFn run;
}

alias DriverProbeFn = fn bool(Options* options);
alias DriverCreateFn = fn void*?(Allocator allocator, Options options, Capabilities* capabilities);
alias DriverDestroyFn = fn void(Allocator allocator, void* state);
alias WindowsRunFn = fn void(void* state, WindowsHub* hub, Host{Command}* host);

<* The backends of this platform in priority order; defined per platform in `probe.c3`. *>
fn Driver*? select_driver(Options options)
{
	// A forced backend that this platform lists but whose probe fails is UNAVAILABLE:
	// it exists here, it just does not work now. Only a backend not listed here is UNSUPPORTED.
	bool listed = false;
	foreach (driver : platform_drivers())
	{
		if (options.backend != AUTO && options.backend != driver.id) continue;
		listed = true;
		if (driver.probe(&options)) return driver;
	}
	if (options.backend != AUTO && listed)
	{
		return error::raise(
			error::UNAVAILABLE,
			error::Domain.INTERNAL,
			0,
			"the requested windows backend does not work here"
		)~;
	}
	if (options.backend != AUTO)
	{
		return error::raise(
			error::UNSUPPORTED,
			error::Domain.INTERNAL,
			0,
			"this platform has no such windows backend"
		)~;
	}
	return error::raise(
		error::UNAVAILABLE,
		error::Domain.INTERNAL,
		0,
		"no windows backend works here (no compositor and no desktop session)"
	)~;
}