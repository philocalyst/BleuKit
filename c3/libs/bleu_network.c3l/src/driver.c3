module bleu::network;
import bleu::availability, bleu::error, bleu::rt::worker;

<*
 Everything the service needs to know about one way of reading networks.
 A backend file defines a `Driver` constant; `probe.c3` lists them.
*>
struct Driver
{
	BackendInfo info;
	Backend id;
	<*
	 Cheap check that the backend might work here, without starting anything.
	*>
	DriverProbeFn probe;
	<*
	 Start the backend's state. Fills `Capabilities` truthfully: a capability the
	 backend does not offer keeps its reason.
	*>
	DriverCreateFn create;
	DriverDestroyFn destroy;
	NetworkRunFn run;
}

alias DriverProbeFn = fn bool(Options* options);
alias DriverCreateFn = fn void*?(Allocator allocator, Options options, Capabilities* capabilities);
alias DriverDestroyFn = fn void(Allocator allocator, void* state);
alias NetworkRunFn = fn void(void* state, NetworkHub* hub, Host{Command}* host);
