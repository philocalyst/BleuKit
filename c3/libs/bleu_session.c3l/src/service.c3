<*
 The session service: open it, read `latest()`, wait for changes, and ask for locks and
 sleeps.

 Session* session = session::open(mem)!;
 defer session.close();
 if (try snapshot = session.latest())
 {
 defer snapshot.release();
 // snapshot.value.locked, snapshot.value.sessions ...
 }

 Every method may be called from any thread.
*>
module bleu::session;
import std::atomic, std::collections::enummap, std::time, bleu::availability, bleu::error, bleu::observe, bleu::operation, bleu::stream, bleu::service;

alias SessionHub = Hub{State, Command, Event};
alias Capabilities = EnumMap{Cap, Availability};

<* Idle time is polled this often by the backends that measure it themselves. *>
const Duration DEFAULT_IDLE_POLL = (Duration)1_000_000; // 1 s in microseconds (time::sec() cannot initialise a global)

<* How `open` finds and tunes a backend. *>
struct Options
{
	Backend backend; // AUTO tries every backend of the platform in priority order
	String bus_address; // logind: the bus to use; "" for the system bus. Copied by `open`.
	Duration[] idle_thresholds; // idle levels `State.idle` reports; copied by `open`. Empty where IDLE_WATCH is unavailable.
	Duration idle_poll; // polling backends check idle time this often; 0 means DEFAULT_IDLE_POLL
	bool allow_private; // macOS: resolve private system symbols (see `macos_lock_private.c3`); off by default
}

<* An open service. Close it with `close`, after every `IdleWatch` has been closed. *>
struct Session
{
	Allocator allocator;
	SessionHub hub;
	Driver* driver;
	void* driver_state;
	Capabilities capabilities;
	Atomic{ulong} watches; // the last id handed to an idle watch; ids start at 1
}

<*
 Open the first working backend of this platform (or the one in `options`).

 @param allocator : "Allocator for the service and its snapshots"
 @return? error::UNAVAILABLE : "No backend works here, or the one in `options` is not running"
 @return? error::UNSUPPORTED : "The requested backend does not exist on this platform"
*>
fn Session*? open(Allocator allocator, Options options = { })
{
	if (options.idle_poll == time::DURATION_ZERO) options.idle_poll = DEFAULT_IDLE_POLL;
	Driver* driver = select_driver(options)!;
	Session* self  = alloc::new(allocator, Session);
	self.allocator = allocator;
	self.driver = driver;
	void*? state = driver.create(allocator, options, &self.capabilities);
	if (catch err = state)
	{
		alloc::free(allocator, self);
		return err~;
	}
	self.driver_state = state;
	if (catch err = self.hub.start(
		allocator,
		"session",
		driver.info.name,
		driver.run,
		self.driver_state,
		abandon: &abandon_command
	))
	{
		driver.destroy(allocator, self.driver_state);
		alloc::free(allocator, self);
		return err~;
	}
	return self;
}

<* Stop the backend and release everything. Close every `IdleWatch` first. *>
fn void Session.close(&self)
{
	self.hub.free();
	self.driver.destroy(self.allocator, self.driver_state);
	Allocator allocator = self.allocator;
	alloc::free(allocator, self);
}

<* Name of the backend in use, for diagnostics ("logind", "macos", "win32"). *>
fn String Session.backend_name(&self) => self.hub.backend_name;

<* Whether `cap` works with this backend, and if not, why. *>
fn Availability Session.capability(&self, Cap cap) => self.capabilities.values[cap.ordinal];

<*
 The newest state, retained for the caller (call `release()` on it).

 @return? error::UNAVAILABLE : "The backend has not produced its first reading yet"
*>
fn Snapshot{State}*? Session.latest(&self) => self.hub.latest();

<*
 Block until a state newer than `seen` exists. Start with `seen = 0`, then pass the previous
 snapshot's `generation`.

 @return? TIMEOUT : "Nothing changed in time"
 @return? error::DISCONNECTED : "The service was closed"
*>
fn Snapshot{State}*? Session.wait_after(&self, ulong seen, Duration timeout = time::FOREVER)
{
	return self.hub.state.wait_after(seen, timeout);
}

<* Call `listener` on the worker thread for the current and every later state. Quick and non-blocking only. *>
fn WatchId{State} Session.watch(
	&self,
	Listener{State} listener,
	void* context
) => self.hub.state.watch(listener, context);

<*
 Remove a listener; when this returns it is not running.

 @return? error::INVALID_STATE : "Called from inside the listener it would remove"
*>
fn void? Session.unwatch(&self, WatchId{State} id) => self.hub.state.unwatch(id);

<*
 Subscribe to the transient events: LOCKED, UNLOCKED, WILL_SLEEP and DID_WAKE, and the idle
 edges of `Options.idle_thresholds` (watch 0). Release the reader when done.

 @return? error::DISCONNECTED : "The service was closed"
*>
fn stream::Reader{Event}*? Session.subscribe(&self) => self.hub.events.subscribe();

<*
 Lock the session this process runs in. The request completes once the OS accepted it; the
 change itself arrives through `latest` and the LOCKED event. A process that is not in a session
 the backend can lock gets UNAVAILABLE from the operation, not from this call.

 @return? error::UNSUPPORTED : "This backend cannot lock (see `capability`)"
 @return? error::BUSY : "The worker's queue is full"
*>
fn SessionOperation*? Session.lock(&self) => self.request(Request.LOCK, Cap.LOCK, "");

<*
 Ask the locker of the session this process runs in to unlock it. Only the session's locker
 can unlock: this is a request, and it may be refused. An outside-session process gets
 UNAVAILABLE from the operation, as for `lock`.

 @return? error::UNSUPPORTED : "This backend cannot ask for an unlock (see `capability`)"
 @return? error::BUSY : "The worker's queue is full"
*>
fn SessionOperation*? Session.unlock(&self) => self.request(Request.UNLOCK, Cap.UNLOCK, "");

<*
 Lock the session `session_id`.

 @param session_id : "A session id from `State.sessions`; must not be empty"
 @return? error::INVALID_ARGUMENT : "The id is empty"
 @return? error::UNSUPPORTED : "This backend cannot lock another session (see `capability`)"
 @return? error::BUSY : "The worker's queue is full"
*>
fn SessionOperation*? Session.lock_session(&self, String session_id)
{
	check_session_id(session_id)!;
	return self.request(Request.LOCK_SESSION, Cap.LOCK_SESSION, session_id);
}

<*
 End the session `session_id`: its processes are stopped and it is logged out. Ending the session
 this process runs in ends this process too; the operation then completes as the logout happens.

 @param session_id : "A session id from `State.sessions`; must not be empty"
 @return? error::INVALID_ARGUMENT : "The id is empty"
 @return? error::UNSUPPORTED : "This backend cannot end a session (see `capability`)"
 @return? error::BUSY : "The worker's queue is full"
*>
fn SessionOperation*? Session.terminate_session(&self, String session_id)
{
	check_session_id(session_id)!;
	return self.request(Request.TERMINATE_SESSION, Cap.TERMINATE_SESSION, session_id);
}

// An empty id names no session: refuse it here instead of letting the backend see it.
fn void? check_session_id(String session_id) @private
{
	if (session_id.len == 0) return error::raise(
		error::INVALID_ARGUMENT,
		error::Domain.INTERNAL,
		0,
		"the session id is empty"
	)~;
}

<*
 Start watching for `threshold` of inactivity. The returned watch reports IDLE once the user
 has been inactive for `threshold`, and RESUMED when input arrives again. Close it when done.

 Only the edges are known: no call returns the idle time, because no Wayland protocol offers
 one. The edge can come up to `Options.idle_poll` late on polling backends.

 @param threshold : "The inactivity that counts as idle; zero reports IDLE at the next check"
 @return? error::UNSUPPORTED : "This backend cannot measure idle time (see `capability`)"
 @return? error::BUSY : "The worker's queue is full"
*>
fn IdleWatch*? Session.watch_idle(&self, Duration threshold)
{
	check(self, Cap.IDLE_WATCH)!;
	IdleWatch* watch = alloc::new(self.allocator, IdleWatch);
	watch.session = self;
	watch.id = self.watches.add(1) + 1;
	// Subscribe before the worker starts the watch, so that no edge can be missed.
	stream::Reader{Event}*? reader = self.hub.events.subscribe();
	if (catch err = reader)
	{
		alloc::free(self.allocator, watch);
		return err~;
	}
	watch.reader = reader;
	if (catch err = self.hub.post({ .kind = CommandKind.WATCH_IDLE, .watch = watch.id, .threshold = threshold }))
	{
		watch.reader.release();
		alloc::free(self.allocator, watch);
		return err~;
	}
	return watch;
}

// Refuse a capability the backend does not offer, with the reason it gives.
fn void? check(Session* self, Cap cap) @private
{
	Availability availability = self.capabilities.values[cap.ordinal];
	if (!availability.ok()) return availability.refusal()~;
}

// Queue a request. The worker completes the operation; the caller keeps one reference to it.
fn SessionOperation*? Session.request(&self, Request request, Cap cap, String session_id)
{
	check(self, cap)!;
	SessionOperation* operation = operation::begin{Request}(self.allocator);
	Command command = {
		.kind = CommandKind.REQUEST,
		.request = request,
		.session = session_id.len > 0 ? session_id.copy(operation.allocator()) : "",
		.operation = operation,
	};
	if (catch err = post_retained(self, command, operation))
	{
		operation.release();
		return err~;
	}
	return operation;
}

// Queue a command that carries an operation. The worker's reference is taken before posting, and
// dropped by the worker when it completes the operation (or here, if the post fails).
fn void? post_retained(Session* self, Command command, SessionOperation* operation) @private
{
	operation.retain();
	if (catch err = self.hub.post(command))
	{
		operation.release();
		return err~;
	}
}