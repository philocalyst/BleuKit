module bleu::notify;
import bleu::availability, bleu::error, bleu::operation, bleu::rt::worker, bleu::service;

// The start-up report of a backend: completed when the backend has its bus name, or failed with the reason.
alias StartOp = Operation{bool};

<*
 Everything the service needs to know about one way of showing notifications.
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
	<*
	 Allocate the backend's state and fill `capabilities`. `startup` is completed by
	 the backend's run function once it holds its name; the bus connection itself
	 must be made on the worker thread, so the outcome is only known there.
	*>
	DriverCreateFn create;
	DriverDestroyFn destroy;
	NotifyRunFn run;
}

alias DriverProbeFn = fn bool(Options* options);
alias DriverCreateFn = fn void*?(Allocator allocator, Options options, Capabilities* capabilities, StartOp* startup);
alias DriverDestroyFn = fn void(Allocator allocator, void* state);
alias NotifyRunFn = fn void(void* state, NotifyHub* hub, Host{Command}* host);

<*
 The first backend of this platform that probes true, or the one named in `options`.

 @return? error::UNSUPPORTED : "The requested backend does not exist on this platform"
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
