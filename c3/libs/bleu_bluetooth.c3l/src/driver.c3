module bleu::bluetooth;
import bleu::availability, bleu::error, bleu::rt::worker;

<*
 Everything the service needs to know about one way of reaching Bluetooth.
 A backend file defines a `Driver` constant; the per-OS file lists them.
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
	 Connects, checks the service is really there, and fills `Capabilities`
	 truthfully. Returns the backend's private state.
	*>
	DriverCreateFn create;
	DriverDestroyFn destroy;
	BluetoothRunFn run;
}

alias DriverProbeFn = fn bool(Options* options);
alias DriverCreateFn = fn void*?(Allocator allocator, Options options, Capabilities* capabilities);
alias DriverDestroyFn = fn void(Allocator allocator, void* state);
alias BluetoothRunFn = fn void(void* state, BluetoothHub* hub, Host{Request}* host);

<* The backends of this platform in priority order; defined per platform by the OS file. *>
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
