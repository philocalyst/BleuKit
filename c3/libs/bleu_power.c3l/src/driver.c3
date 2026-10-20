module bleu::power;
import std::thread, bleu::availability, bleu::error, bleu::rt::worker, bleu::service;

<*
 Everything the service needs to know about one way of providing power
 management. A backend file defines a `Driver` constant; `probe.c3` lists them.
*>
struct Driver
{
	BackendInfo info;
	Backend id;
	<*
	 Cheap check that the backend can work here, without starting anything and
	 without touching the bus or the OS.
	*>
	DriverProbeFn probe;
	DriverCreateFn create;
	DriverDestroyFn destroy;
	PowerRunFn run;
}

alias DriverProbeFn = fn bool(Options* options);
alias DriverCreateFn = fn void*?(Allocator allocator, Options options, Capabilities* capabilities, Startup* startup);
alias DriverDestroyFn = fn void(Allocator allocator, void* state);
alias PowerRunFn = fn void(void* state, PowerHub* hub, Host{Command}* host);

<*
 The rendezvous between the worker thread and `open`. The backend's `run`
 fills in `capabilities` and then calls `succeed` or `fail`; `open` blocks in
 `wait` until it has. Connections are owned by the thread that opens them, so a
 backend can only probe the platform from its own worker.
*>
struct Startup
{
	Mutex mutex;
	ConditionVariable done;
	bool finished;
	bool failed;
	fault failure;
}

<* Prepare the latch. Call before the worker starts. *>
fn void Startup.init(&self)
{
	self.mutex.init()!!;
	self.done.init()!!;
}

<* Release the latch's primitives. Call after the worker has stopped. *>
fn void Startup.free(&self)
{
	self.done.destroy()!!;
	self.mutex.destroy();
}

<* The backend is running and its capabilities are filled in. Only the first call has an effect. *>
fn void Startup.succeed(&self)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	if (self.finished) return;
	self.finished = true;
	self.done.broadcast()!!;
}

<* The backend could not start. Only the first call has an effect. *>
fn void Startup.fail(&self, fault failure)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	if (self.finished) return;
	self.finished = true;
	self.failed = true;
	self.failure = failure;
	self.done.broadcast()!!;
}

<*
 Block until the backend has started or failed.

 @return? error::UNAVAILABLE : "The backend failed to start; the fault it reported is returned"
*>
fn void? Startup.wait(&self)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	while (!self.finished) self.done.wait(&self.mutex)!!;
	if (self.failed) return self.failure~;
}

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
