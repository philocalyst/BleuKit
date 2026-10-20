<*
 Everything the service needs to know about one way of reaching a keyring.
 A backend file defines a `Driver` constant; `probe.c3` lists them.
*>
module bleu::secrets;
import bleu::availability, bleu::error, bleu::service, bleu::rt::worker;

<*
 One way of reaching a keyring service.
*>
struct Driver
{
	BackendInfo info;
	Backend id;
	<* Cheap check that the backend exists here, without starting anything. *>
	DriverProbeFn probe;
	<* Create the backend's state and fill `Capabilities`. Fails when the keyring is absent. *>
	DriverCreateFn create;
	DriverDestroyFn destroy;
	KeyringRunFn run;
}

alias DriverProbeFn = fn bool(Options* options);
alias DriverCreateFn = fn void*?(Allocator allocator, Options options, Capabilities* capabilities);
alias DriverDestroyFn = fn void(Allocator allocator, void* state);
alias KeyringRunFn = fn void(void* state, KeyringHub* hub, Host{Command}* host);

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