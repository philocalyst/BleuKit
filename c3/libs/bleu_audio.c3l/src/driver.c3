<*
 Everything the service needs to know about one way of reaching the audio
 system. A backend file defines a `Driver` constant; `probe.c3` lists them.
*>
module bleu::audio;
import bleu::availability, bleu::error, bleu::service, bleu::rt::worker;

<* One backend's entry point: probing, creation, teardown and its worker loop. *>
struct Driver
{
	BackendInfo info;
	Backend id;
	<* Cheap check that the backend can work here, without starting anything. *>
	DriverProbeFn probe;
	DriverCreateFn create;
	DriverDestroyFn destroy;
	AudioRunFn run;
}

alias DriverProbeFn = fn bool(Options* options);
alias DriverCreateFn = fn void*?(Allocator allocator, Options options, Capabilities* capabilities);
alias DriverDestroyFn = fn void(Allocator allocator, void* state);
alias AudioRunFn = fn void(void* state, AudioHub* hub, Host{Command}* host);

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