<*
 Everything the service needs to know about one way of reading keyboard layouts. A backend file
 defines a `Driver` constant; `probe.c3` lists them.
*>
module bleu::input;
import bleu::availability, bleu::error, bleu::rt::worker, bleu::service;

<* One backend of this platform, as the service sees it. *>
struct Driver
{
	BackendInfo info;
	Backend id;
	<*
	 Cheap check that the backend can work here, without keeping anything open.
	*>
	DriverProbeFn probe;
	DriverCreateFn create;
	DriverDestroyFn destroy;
	InputRunFn run;
}

alias DriverProbeFn = fn bool(Options* options);
alias DriverCreateFn = fn void*?(Allocator allocator, Options options, Capabilities* capabilities);
alias DriverDestroyFn = fn void(Allocator allocator, void* state);
alias InputRunFn = fn void(void* state, InputHub* hub, Host{Command}* host);

<*
 The first backend, in priority order, whose `probe` succeeds; `options.backend` forces one by name.

 @return? error::UNSUPPORTED : "The forced backend does not exist on this platform"
 @return? error::UNAVAILABLE : "No backend works here"
*>
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
