<*
 A service's worker thread: one thread that owns one mailbox and runs one
 function until that function returns or the worker is stopped.

 This is the threading rule of ARCHITECTURE.md. Public methods of a service
 post a `Command` and return; the worker's function takes commands out of the
 mailbox, waits on its poller (which includes the mailbox's wake-up), and does
 all native I/O and publishing on this one thread. The thread is started with
 `start`, asked to finish with `stop`, and joined by `stop` before it returns.

 A worker runs once. After `stop` it cannot be started again; create a new one.
 A `Worker` must not move in memory after `start`: the thread refers to it.
*>
module bleu::rt::worker <Command>;
import std::thread, std::atomic, bleu::error, bleu::rt::mailbox, bleu::rt::wakeup, bleu::rt::foreign;

<* Life cycle of a worker: created, then running, then stopped (and joined). *>
enum WorkerState : char
{
	NEW,
	RUNNING,
	STOPPED,
}

<*
 The function a worker runs on its thread. It should return soon after
 `host.stopping()` becomes true.

 @param context : "The `context` given to `Worker.start`"
 @param host : "Access to the mailbox, the wake-up and the stop flag"
*>
alias RunFn = fn void(void* context, Host* host);

<*
 What the running function sees of its worker. Valid only while the function runs.
*>
struct Host
{
	Worker* worker;
}

<*
 A worker thread with its mailbox. Initialise with `init`, start with `start`,
 stop with `stop`, release with `free`.
*>
struct Worker
{
	Mailbox{Command} mailbox;
	Mutex lifecycle;
	Thread thread;
	Atomic{bool} stop_requested;
	WorkerState state;
	RunFn run;
	void* context;
}

<*
 Prepare a worker: the mailbox is created, but no thread runs yet.

 @param allocator : "Allocator for the mailbox's queue"
 @param max_queue : "Most commands the mailbox holds before `post` returns BUSY"
 @require max_queue > 0 : "A mailbox needs room for at least one command"
 @return? error::BACKEND_FAILURE : "The mailbox's wake-up could not be created"
*>
fn void? Worker.init(&self, Allocator allocator, usz max_queue)
{
	self.mailbox.init(allocator, max_queue)!;
	self.lifecycle.init()!!;
	self.stop_requested.store(false);
}

<*
 Release the mailbox and the lifecycle lock. Call after `stop`, or on a worker
 that was never started.
*>
fn void Worker.free(&self)
{
	self.mailbox.free();
	self.lifecycle.destroy();
}

<*
 Start the worker thread, which calls `run(context, host)`.

 The thread name is used in error messages. The standard library exposes no
 thread-naming call, so the name is not set on the OS thread.

 @param name : "Name for diagnostics"
 @param run : "The function the thread runs"
 @param context : "Passed to `run` unchanged"
 @require run != null : "A worker needs a function to run"
 @return? error::INVALID_STATE : "The worker was already started"
 @return? error::BACKEND_FAILURE : "The OS refused to create the thread"
*>
fn void? Worker.start(&self, String name, RunFn run, void* context)
{
	self.lifecycle.lock()!!;
	defer self.lifecycle.unlock();
	if (self.state != NEW)
	{
		return error::raise(error::INVALID_STATE, error::Domain.INTERNAL, 0, "worker '%s' was already started", name)~;
	}
	self.run = run;
	self.context = context;
	if (catch self.thread.create(&worker_main, self))
	{
		return error::raise(
			error::BACKEND_FAILURE,
			error::Domain.INTERNAL,
			0,
			"cannot start thread for worker '%s'",
			name
		)~;
	}
	self.state = RUNNING;
}

<*
 Ask the worker to finish, wake it, and wait until its thread has returned.
 Idempotent: a worker that is not running does nothing. Must not be called from
 the worker's own thread, which would wait for itself.

 Commands posted after `stop` are refused (the mailbox is closed); commands
 already queued stay there and can be drained with `host.mailbox().take_all`.
*>
fn void Worker.stop(&self)
{
	self.lifecycle.lock()!!;
	defer self.lifecycle.unlock();
	if (self.state != RUNNING) return;
	assert(!thread::current().equals(self.thread), "a worker must not stop itself");
	self.stop_requested.store(true);
	// Closing the mailbox signals its wake-up, so a poller waiting on it returns.
	self.mailbox.close();
	self.thread.join()!!;
	self.state = STOPPED;
}

<* True once `stop` has been requested: finish up and return. *>
fn bool Host.stopping(&self) @inline => self.worker.stop_requested.load();

<* The worker's mailbox. Take commands out with `take_all`; only the worker does. *>
fn Mailbox{Command}* Host.mailbox(&self) @inline => &self.worker.mailbox;

<* The wake-up for the worker's poller. It is signalled whenever the mailbox gets a command. *>
fn Wakeup* Host.wakeup(&self) @inline => self.worker.mailbox.wakeup();

// The thread's entry point. The temporary allocator is set up first, because a
// thread that the C3 runtime started still has none (see `foreign`).
fn int worker_main(void* arg) @private
{
	Worker* worker = (Worker*)arg;
	foreign::@foreign_entry()
	{
		Host host = { .worker = worker };
		worker.run(worker.context, &host);
	};
	return 0;
}