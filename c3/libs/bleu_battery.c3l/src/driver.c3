module bleu::battery;
import std::thread, bleu::availability, bleu::error, bleu::rt::worker;

<*
 Everything the service needs to know about one way of reading batteries.
 A backend file defines a `Driver` constant; `probe.c3` lists them.
*>
struct Driver
{
	BackendInfo info;
	Backend id;
	<*
	 Cheap check that the backend can work here, without starting anything.
	 Returns what it can do through `Capabilities`.
	*>
	DriverProbeFn probe;
	DriverCreateFn create;
	DriverDestroyFn destroy;
	BatteryRunFn run;
}

alias DriverProbeFn = fn bool(Options* options);
alias DriverCreateFn = fn void*?(Allocator allocator, Options options, Capabilities* capabilities, Startup* startup);
alias DriverDestroyFn = fn void(Allocator allocator, void* state);
alias BatteryRunFn = fn void(void* state, BatteryHub* hub, Host{Command}* host);

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

<*
 The rendezvous between the worker thread and `open`. The backend's `run` calls
 `succeed` once its poller exists, or `fail` with the fault that stopped it; `open`
 blocks in `wait` until one of them happened, so a backend that cannot start is an
 error from `open`, never a service that silently publishes nothing.
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

<* The backend is running. Only the first call has an effect. *>
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