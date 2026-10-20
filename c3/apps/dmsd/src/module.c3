<*
 The module contract of dmsd.

 A DMS module is one group of IPC methods and the topics it publishes (for
 example `brightness`: `brightness.getState` and friends, and the topics
 `brightness` and `brightness.update`). Every module is described by a `Module`
 value, started once before the IPC server starts, and stopped once after it
 has stopped. Adding a module means one `mod_<name>.c3` file and one entry in
 `main.c3`; see `docs/DMSD.md` section "Adding a module".

 Rules every module follows:
 * `start` opens its Bleu service. When the backend is absent it prints one
   line to stderr and returns false: the module is not started, its capability
   is not advertised, and the daemon keeps running. Never fatal.
 * Methods and topics are registered in `start`, before the server starts.
 * A service's state reaches a topic through a `StatePump`: the service's
   listener only marks the pump dirty, and the pump's own thread encodes the
   newest state and publishes it. Several changes in a row cost one publication.
 * `stop` releases what `start` took: unwatch, stop pumps, close the service.
*>
module dmsd::contract;
import std::io, std::thread, std::collections::list, bleu::ipc, bleu::error, bleu::rt::foreign;

<* Set by `--debug`: `note` prints. *>
bool debug_logging = false;

<*
 The command line. Strings are views of the argument strings, valid for the
 whole run.
*>
struct Options
{
	String socket_path; // "" selects DMS's default `$XDG_RUNTIME_DIR/dmsd-<pid>.sock`
	String fake_root;   // "" uses the real system; otherwise the brightness backend reads this sysfs root (tests)
	List{String} module_off; // module names not to start
}

<* Whether `name` was named by `--module-off`. *>
fn bool Options.disables(&self, String name)
{
	foreach (off : self.module_off)
	{
		if (off == name) return true;
	}
	return false;
}

<*
 What every module sees. `capabilities` is filled in once the modules have
 started and is read by the IPC handshake, so it is never changed while the
 server runs.
*>
struct Context
{
	Allocator allocator;
	Options* options;
	ipc::Server* server;
	String[] capabilities;
}

<*
 Start a module. `self` is the module's own descriptor: the function stores its
 runtime state in `self.state`. Returns false when the backend is absent (the
 reason has been printed).
*>
alias StartFn = fn bool(Context* context, Module* self);

<* Stop a module started with `start` and release its state. Called in reverse start order. *>
alias StopFn = fn void(Context* context, Module* self);

<*
 One DMS module.

 `topics` and `capabilities` name what the module publishes and advertises. Both
 are only read when the module has started. `state` belongs to the module.
*>
struct Module
{
	String name;
	StartFn start;
	StopFn stop;
	String[] topics;
	String[] capabilities;
	void* state;
	bool running;
}

<* Print one line to stderr, prefixed with the program name. Always printed. *>
fn void warn(String fmt, args...) @format(0)
{
	@pool()
	{
		io::eprintfn("dmsd: %s", string::tformat(fmt, ...args));
	};
}

<* Print one line to stderr when `--debug` was given. *>
fn void note(String fmt, args...) @format(0)
{
	if (!debug_logging) return;
	@pool()
	{
		io::eprintfn("dmsd: %s", string::tformat(fmt, ...args));
	};
}

<*
 The text of the failure most recently raised on this thread, for a DMS error
 reply. Falls back to `fallback` when no detail was recorded.
*>
fn String failure_text(String fallback)
{
	Detail* detail = error::last();
	return detail.len > 0 ? detail.message() : fallback;
}

<*
 Encodes the service's newest state as one JSON line in `allocator`. Returns
 an error when there is no state yet. Runs on the pump's thread, inside a
 temporary-memory pool.
*>
alias EncodeFn = fn String?(void* context, Allocator allocator);

<*
 Publishes a service's state to a topic, from a thread of its own.

 `notify` is cheap and safe to call from a service listener: it sets a flag and
 wakes the thread. The thread encodes the newest state once per wake-up, so a
 burst of changes costs one publication, and the last state always wins.
*>
struct StatePump
{
	Mutex mutex;
	ConditionVariable wake;
	Thread thread;
	bool started;
	bool dirty;
	bool stopping;
	String name;
	ipc::Topic* topic;
	EncodeFn encode;
	void* context;
}

<*
 Prepare the pump and start its thread. The first publication happens on the
 first `notify`, which a `watch` on the service makes at once.

 @param name : "Module name, for diagnostics"
 @param topic : "The topic that receives the states, registered before the server starts"
 @param encode : "Encodes the newest state; see `EncodeFn`"
 @return? error::BACKEND_FAILURE : "The thread could not be started"
*>
fn void? StatePump.start(&self, String name, ipc::Topic* topic, EncodeFn encode, void* context)
{
	self.name = name;
	self.topic = topic;
	self.encode = encode;
	self.context = context;
	self.mutex.init()!!;
	self.wake.init()!!;
	self.thread.create(&pump_main, self)!;
	self.started = true;
}

<*
 Ask for a publication. Called from a service listener (any thread): it only
 sets the flag and signals the pump.
*>
fn void StatePump.notify(&self)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	self.dirty = true;
	self.wake.signal()!!;
}

<* Finish the pending publication, if any, and wait until the thread has returned. Idempotent. *>
fn void StatePump.stop(&self)
{
	if (!self.started) return;
	self.mutex.lock()!!;
	self.stopping = true;
	self.wake.broadcast()!!;
	self.mutex.unlock();
	self.thread.join()!!;
	self.started = false;
}

<* Release the pump's synchronisation objects. Call after `stop`. *>
fn void StatePump.free(&self)
{
	self.wake.destroy()!!;
	self.mutex.destroy();
}

// The thread's entry point. The temporary allocator is set up first (see bleu::rt::foreign).
fn int pump_main(void* arg) @private
{
	StatePump* pump = (StatePump*)arg;
	foreign::@foreign_entry()
	{
		pump.run();
	};
	return 0;
}

// Wait for a notification, then publish the newest state, until stopped.
fn void StatePump.run(&self) @private
{
	while (true)
	{
		self.mutex.lock()!!;
		while (!self.dirty && !self.stopping) self.wake.wait(&self.mutex)!!;
		if (self.stopping)
		{
			self.mutex.unlock();
			return;
		}
		self.dirty = false;
		self.mutex.unlock();
		self.publish_latest();
	}
}

// Encode the newest state and publish it. Temporary memory is released with the pool.
fn void StatePump.publish_latest(&self) @private
{
	@pool()
	{
		if (try json = self.encode(self.context, tmem))
		{
			if (catch err = self.topic.publish(json)) warn("%s: publish failed: %s", self.name, failure_text("publish failed"));
		}
		else
		{
			note("%s: no state to publish yet", self.name);
		}
	};
}
