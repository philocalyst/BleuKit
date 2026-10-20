module bleu::apps;
import bleu::availability, bleu::error, bleu::rt::worker;

<*
 Everything the service needs to know about one way of listing apps. A backend
 file defines a `Driver` constant; `probe.c3` lists them, best first.
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
	AppsRunFn run;
	DriverIconFn icon;
}

alias DriverProbeFn = fn bool(Options* options);
alias DriverCreateFn = fn void*?(Allocator allocator, Options options, Capabilities* capabilities);
alias DriverDestroyFn = fn void(Allocator allocator, void* state);
alias AppsRunFn = fn void(void* state, AppsHub* hub, AppsHost* host);
alias DriverIconFn = fn String?(void* state, String icon, int size, int scale, Allocator allocator);

<*
 The icon lookup of a backend that has no icon themes. Raises `UNSUPPORTED`.

 @return? error::UNSUPPORTED : "This platform has no icon lookup in this service"
*>
fn String? icon_unsupported(void* state, String icon, int size, int scale, Allocator allocator)
{
	return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "icon lookup is not available here")~;
}

<*
 The backends of this platform in priority order; the first whose `probe`
 succeeds wins unless the caller forces one by name.

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
