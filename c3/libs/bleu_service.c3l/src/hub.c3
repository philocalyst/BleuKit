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
*>
module bleu::service <State, Command, Event>;
import bleu::error, bleu::equal, bleu::observe, bleu::stream, bleu::rt::worker;

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

const usz DEFAULT_QUEUE = 256;

struct Hub
{
	Allocator allocator;
	Observable{State} state;
	Stream{Event} events;
	Worker{Command} worker;
	String backend_name;
	RunFn run;
	void* backend;
	bool running;
}

<*
 Create the hub and start the backend on its own thread. On failure nothing is
 left running or allocated.

 @param name : "Service name for diagnostics, e.g. \"network\""
 @param backend_name : "Stable identifier of the chosen backend, e.g. \"networkmanager\""
 @param max_queue : "Most commands that may wait for the worker"
 @return? error::BACKEND_FAILURE : "The mailbox or the thread could not be created"
*>
fn void? Hub.start(
	&self,
	Allocator allocator,
	String name,
	String backend_name,
	RunFn run,
	void* backend,
	usz max_queue = DEFAULT_QUEUE
)
{
	*self = { .allocator = allocator, .backend_name = backend_name, .run = run, .backend = backend };
	self.state.init(allocator);
	self.events.init(allocator);
	if (catch err = self.worker.init(allocator, max_queue))
	{
		self.events.close();
		self.state.close();
		return err~;
	}
	if (catch err = self.worker.start(name, &hub_main, self))
	{
		self.worker.free();
		self.events.close();
		self.state.close();
		return err~;
	}
	self.running = true;
}

// Thread entry: forward to the backend with the hub it publishes into.
fn void hub_main(void* context, WorkerHost* host) @private
{
	Hub* hub = (Hub*)context;
	hub.run(hub.backend, hub, host);
}

<*
 Stop the backend, wait for its thread, then close the observable and the
 stream so every waiter and reader is released. Idempotent.
*>
fn void Hub.stop(&self)
{
	if (!self.running) return;
	self.running = false;
	self.worker.stop();
	self.state.close();
	self.events.close();
	self.worker.free();
}

<*
 Queue a command for the worker.

 @return? error::BUSY : "The queue is full"
 @return? error::UNAVAILABLE : "The hub is stopping"
*>
fn void? Hub.post(&self, Command command) => self.worker.mailbox.post(command);

<* Begin building a new state snapshot (zero-initialised value, caller holds one reference). *>
fn StateSnapshot* Hub.begin(&self) => observe::begin{State}(self.allocator);

<* Publish a snapshot built with `begin`, consuming the caller's reference. Returns its generation. *>
fn ulong Hub.publish(&self, StateSnapshot* snapshot) => self.state.publish(snapshot);

<* Begin building an event packet. *>
fn EventPacket* Hub.emit_begin(&self) => self.events.begin();

<* Deliver an event packet to all readers, consuming the caller's reference. *>
fn void Hub.emit(&self, EventPacket* packet) => self.events.publish(packet);

<* The latest published state, retained for the caller; `UNAVAILABLE` before the first publication. *>
fn StateSnapshot*? Hub.latest(&self) => self.state.latest();

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