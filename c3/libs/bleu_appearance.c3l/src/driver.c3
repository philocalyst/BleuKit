module bleu::appearance;
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
	 Cheap check that the backend can work here, without changing anything on
	 the desktop. A bus connection and a name lookup are the most it does.
	*>
	DriverProbeFn probe;
	DriverCreateFn create;
	DriverDestroyFn destroy;
	AppearanceRunFn run;
}

alias DriverProbeFn = fn bool(Options* options);
alias DriverCreateFn = fn void*?(Allocator allocator, Options options, Capabilities* capabilities);
alias DriverDestroyFn = fn void(Allocator allocator, void* state);
alias AppearanceRunFn = fn void(void* state, AppearanceHub* hub, Host{Command}* host);

<*
 The backend to run: the first one of the platform's list that probes true, or
 the one named in `options`.

 @return? error::UNSUPPORTED : "The named backend does not exist on this platform"
 @return? error::UNAVAILABLE : "No backend works here, or the named one does not"
*>
fn Driver*? select_driver(Options options)
{
	bool named_exists = false;
	foreach (driver : platform_drivers())
	{
		if (options.backend != AUTO && options.backend != driver.id) continue;
		named_exists = true;
		if (driver.probe(&options)) return driver;
	}
	if (options.backend != AUTO)
	{
		return named_exists ? error::UNAVAILABLE~ : error::UNSUPPORTED~;
	}
	return error::UNAVAILABLE~;
}