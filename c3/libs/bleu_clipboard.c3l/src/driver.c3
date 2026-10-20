<*
 Everything the service needs to know about one way of reading and writing the clipboard.
 A backend file defines a `Driver` constant; `probe.c3` lists them in priority order.
*>
module bleu::clipboard;
import bleu::availability, bleu::error, bleu::service, bleu::rt::worker;

<* One way of reaching the clipboard. *>
struct Driver
{
	BackendInfo info;
	Backend id;
	<* Cheap check that the backend could work here, without connecting. *>
	DriverProbeFn probe;
	<*
	 Create the backend's state and fill `Capabilities`. Fails when the clipboard is not
	 reachable, so that `open` can try the next backend.
	*>
	DriverCreateFn create;
	DriverDestroyFn destroy;
	ClipboardRunFn run;
}

alias DriverProbeFn = fn bool(Options* options);
alias DriverCreateFn = fn void*?(Allocator allocator, Options options, Capabilities* capabilities);
alias DriverDestroyFn = fn void(Allocator allocator, void* state);
alias ClipboardRunFn = fn void(void* state, ClipboardHub* hub, Host{Command}* host);

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
