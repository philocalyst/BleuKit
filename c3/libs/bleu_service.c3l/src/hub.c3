<*
 The machinery every Bleu service shares: one worker thread, one observable
 state, one event stream, one command mailbox.

 A service library defines its `State`, `Command` and `Event` types and a
 backend; the `Hub` wires them together so that no service re-implements
 threading, publication or shutdown.

 alias NetHub = Hub{NetState, NetCommand, NetEvent};

 The backend's run function executes on the hub's worker thread:

 fn void run(void* backend, NetHub* hub, Host* host)
 {
 // poll native sources + host.wakeup(); take commands from host.mailbox();
 // build a snapshot with hub.begin(), fill it, hub.publish(snapshot);
 // emit transients with hub.emit_begin()/hub.emit(packet).
 }

 Public service methods are callable from any thread: they `post` a command
 (returning an `Operation` whose completion the worker drives) or read the
 published state.

 Life cycle: `start` (once), `stop` (waits for the backend), `free` (releases
 everything). `stop` releases nothing that a concurrent `post` could touch, so
 a post racing with `stop` is either queued or refused, never a fault. Only
 `free` destroys the locks, and it must not run while another thread is still
 inside a method of the hub.
*>
module bleu::service <State, Command, Event>;
import std::atomic, std::io, bleu::error, bleu::equal, bleu::observe, bleu::stream, bleu::rt::worker;

alias StateSnapshot = Snapshot{State};
alias EventPacket = Packet{Event};
alias WorkerHost = Host{Command};

<*
 The backend's body. Runs on the hub's worker thread until it returns, which
 it should do soon after `host.stopping()` turns true.

 @param backend : "The pointer given to `Hub.start`"
 @param hub : "Where to publish state and events"
 @param host : "Mailbox, wake-up and stop flag"
*>
alias RunFn = fn void(void* backend, Hub* hub, WorkerHost* host);

<*
 Called once for every command still queued when the backend's run function has
 returned (normally on stop, but also when `run` bails out early on an error):
 complete its `Operation` with a fault (typically `error::DISCONNECTED` or
 `CANCELLED`) so no waiter hangs. Runs on the worker thread, after `run` returned.
*>
alias AbandonFn = fn void(void* backend, Command* command);

const usz DEFAULT_QUEUE = 256;

// How many leftover commands are taken out of the mailbox at a time when they are abandoned.
const usz ABANDON_BATCH = 16;

<*
 Where a hub is in its life cycle. The zero value is `NEW`, so a hub that was never
 started (or was freed) reads as idle.
*>
enum HubPhase : char
{
	NEW,     // not started, or freed: holds no resources
	RUNNING, // the worker and its locks exist
	STOPPED, // the worker has returned; the resources are held until `free`
}

<*
 A service's hub. Declare it, `start` it, `stop` and `free` it when the service closes.
*>
struct Hub
{
	Allocator allocator;
	String name;
	String backend_name;
	RunFn run;
	AbandonFn abandon;
	void* backend;
	Observable{State} state;
	Stream{Event} events;
	Worker{Command} worker;
	HubPhase phase;
	Atomic{bool} accepting; // set while the worker runs; `post` checks it before touching the mailbox
	Atomic{bool} initialized; // set by a successful `start`, cleared by `free`: the locks exist
}

<*
 Create the hub and start the backend on its own thread. On failure nothing is
 left running or allocated, and the hub can be started again.

 @param name : "Service name for diagnostics, e.g. \"network\""
 @param backend_name : "Stable identifier of the chosen backend, e.g. \"networkmanager\""
 @param max_queue : "Most commands that may wait for the worker"
 @param abandon : "Completes leftover commands' operations when the backend stops or bails out. Services whose commands carry an `Operation` must pass it: without it leftover commands are dropped, their operations never complete, and a waiter blocks forever. Dropped commands are logged to stderr."
 @return? error::INVALID_STATE : "The hub is already started (stop and free it first)"
 @return? error::BACKEND_FAILURE : "The mailbox or the thread could not be created"
*>
fn void? Hub.start(
	&self,
	Allocator allocator,
	String name,
	String backend_name,
	RunFn run,
	void* backend,
	usz max_queue = DEFAULT_QUEUE,
	AbandonFn abandon = null
)
{
	if (self.phase != NEW)
	{
		return error::raise(
			error::INVALID_STATE,
			error::Domain.INTERNAL,
			0,
			"hub '%s' is already started; stop and free it first",
			name
		)~;
	}
	self.allocator = allocator;
	self.name = name;
	self.backend_name = backend_name;
	self.run = run;
	self.abandon = abandon;
	self.backend = backend;
	self.state.init(allocator);
	self.events.init(allocator);
	if (catch err = self.worker.init(allocator, max_queue))
	{
		self.events.destroy();
		self.state.destroy();
		return err~;
	}
	if (catch err = self.worker.start(name, &hub_main, self))
	{
		self.worker.free();
		self.events.destroy();
		self.state.destroy();
		return err~;
	}
	self.accepting.store(true);
	self.initialized.store(true);
	self.phase = RUNNING;
}

// Thread entry: forward to the backend with the hub it publishes into.
fn void hub_main(void* context, WorkerHost* host) @private
{
	Hub* hub = (Hub*)context;
	hub.run(hub.backend, hub, host);
	// `run` returned, on stop or on an early error: nothing will serve the mailbox any more.
	// Refuse new commands, then hand back the queued ones.
	host.mailbox().close();
	abandon_leftovers(hub, host);
}

// Hand every command still queued to `abandon`. Without an `abandon` the commands are
// dropped, which is logged: their operations would never complete.
fn void abandon_leftovers(Hub* hub, WorkerHost* host) @private
{
	Command[ABANDON_BATCH] batch;
	usz dropped = 0;
	while (true)
	{
		usz count = host.mailbox().take_all(batch[..]);
		if (count == 0) break;
		if (!hub.abandon)
		{
			dropped += count;
			continue;
		}
		for (usz i = 0; i < count; i++) hub.abandon(hub.backend, &batch[i]);
	}
	if (dropped > 0)
	{
		io::eprintfn("bleu: service '%s' stopped with %d queued command(s) and no abandon handler; they were dropped",
			hub.name, dropped);
	}
}

<*
 Stop the backend, wait for its thread, then close the observable and the stream
 so every waiter and reader is released. Posts from now on are refused with
 `UNAVAILABLE`. Nothing is freed yet: call `free` afterwards. Idempotent.
*>
fn void Hub.stop(&self)
{
	if (self.phase != RUNNING) return;
	self.accepting.store(false);
	self.worker.stop();
	self.state.close();
	self.events.close();
	self.phase = STOPPED;
}

<*
 Release everything the hub holds: the worker's mailbox and lock, the observable's
 and the stream's locks. Stops the hub first if it is still running. A freed hub
 can be started again. Every `Reader` of its stream must be released before this,
 and no other thread may be inside a method of the hub.

 Idempotent.
*>
fn void Hub.free(&self)
{
	if (self.phase == NEW) return;
	self.stop();
	self.worker.free();
	self.state.destroy();
	self.events.destroy();
	self.initialized.store(false);
	self.phase = NEW;
}

<*
 Queue a command for the worker. Callable from any thread, at any time: a hub
 that is not running refuses the command.

 @return? error::BUSY : "The queue is full"
 @return? error::UNAVAILABLE : "The hub is not running (never started, stopped or freed)"
*>
fn void? Hub.post(&self, Command command)
{
	if (!self.accepting.load())
	{
		return error::raise_text(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "hub is not running")~;
	}
	return self.worker.mailbox.post(command);
}

<* Begin building a new state snapshot (zero-initialised value, caller holds one reference). *>
fn StateSnapshot* Hub.begin(&self) => observe::begin{State}(self.allocator);

<* Publish a snapshot built with `begin`, consuming the caller's reference. Returns its generation. *>
fn ulong Hub.publish(&self, StateSnapshot* snapshot) => self.state.publish(snapshot);

<* Begin building an event packet. *>
fn EventPacket* Hub.emit_begin(&self) => self.events.begin();

<* Deliver an event packet to all readers, consuming the caller's reference. *>
fn void Hub.emit(&self, EventPacket* packet) => self.events.publish(packet);

<*
 The latest published state, retained for the caller; `UNAVAILABLE` before the first
 publication, and on a hub that was never started or has been freed.
*>
fn StateSnapshot*? Hub.latest(&self)
{
	if (!self.initialized.load()) return error::raise_text(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "hub has no state")~;
	return self.state.latest();
}

<*
 Publish `snapshot` only if its value differs from the latest published one;
 otherwise drop it. Polling backends use this so consumers wake only on real
 change. Consumes the caller's reference either way.

 @return "true when a new generation was published"
*>
fn bool Hub.publish_if_changed(&self, StateSnapshot* snapshot)
{
	if (try current = self.state.latest())
	{
		defer current.release();
		if (equal::deep(current.value, snapshot.value))
		{
			snapshot.release();
			return false;
		}
	}
	self.state.publish(snapshot);
	return true;
}
