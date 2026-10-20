<*
 The notification centre: open it, read `latest()`, send it commands.

 Notify* centre = notify::open(mem)!;
 defer centre.close();
 if (try snapshot = centre.latest())
 {
 defer snapshot.release();
 // snapshot.value.active, snapshot.value.history ...
 }

 `open` takes the freedesktop notification bus name for this process, or fails
 with UNAVAILABLE and the owner's identity when another daemon has it. Every
 method may be called from any thread.
*>
module bleu::notify;
import std::time, std::collections::enummap, bleu::error, bleu::availability, bleu::observe, bleu::stream, bleu::service, bleu::operation;

alias NotifyHub = Hub{State, Command, Event};

// How long `open` waits for the backend to take the bus name. Connecting to the session bus is the slow part.
const Duration START_TIMEOUT = (Duration)10_000_000; // 10 s, microseconds

<* A running notification centre. Created by `open`, released by `close`. *>
struct Notify
{
	Allocator allocator;
	NotifyHub hub;
	Driver* driver;
	void* driver_state;
	Capabilities capabilities;
}

<*
 Open the first notification centre this platform offers (or the one in `options`)
 and take the notification bus name for this process.

 @param allocator : "Allocator for the centre and its snapshots"
 @return? error::UNSUPPORTED : "This platform has no notification centre, or the requested backend does not exist here"
 @return? error::UNAVAILABLE : "No session bus, or another daemon owns org.freedesktop.Notifications; the message names the owner. Options.replace takes the name over"
 @return? error::PERMISSION_DENIED : "The bus refused the name"
*>
fn Notify*? open(Allocator allocator, Options options = { })
{
	if (options.policy.max_open == 0) options.policy = DEFAULT_POLICY;
	Driver* driver = select_driver(options)!;
	Notify* self   = alloc::new(allocator, Notify);
	*self = { .allocator = allocator, .driver = driver };
	StartOp* startup = operation::begin{bool}(allocator);
	// One reference for `open`, one for the worker, which releases its own when it returns.
	startup.retain();
	void*? state = driver.create(allocator, options, &self.capabilities, startup);
	if (catch err = state)
	{
		startup.release();
		startup.release();
		alloc::free(allocator, self);
		return err~;
	}
	self.driver_state = state;
	if (catch err = self.hub.start(allocator, "notify", driver.info.name, driver.run, self.driver_state))
	{
		driver.destroy(allocator, self.driver_state);
		startup.release();
		startup.release();
		alloc::free(allocator, self);
		return err~;
	}
	if (catch err = startup.wait(START_TIMEOUT))
	{
		// The worker failed (its reason travels with the operation) or never reported.
		*error::last() = *startup.detail();
		self.hub.stop();
		driver.destroy(allocator, self.driver_state);
		startup.release();
		alloc::free(allocator, self);
		return err~;
	}
	startup.release();
	return self;
}

<* Stop the backend, release the bus name and everything else. *>
fn void Notify.close(&self)
{
	self.hub.stop();
	self.driver.destroy(self.allocator, self.driver_state);
	Allocator allocator = self.allocator;
	alloc::free(allocator, self);
}

<* Name of the backend in use, for diagnostics ("fdo"). *>
fn String Notify.backend_name(&self) => self.hub.backend_name;

<* Whether `cap` works with this backend, and if not, why. *>
fn Availability Notify.capability(&self, Cap cap) => self.capabilities.values[cap.ordinal];

<*
 The newest state, retained for the caller (call `release()` on it).

 @return? error::UNAVAILABLE : "The backend has not published its first state yet"
*>
fn Snapshot{State}*? Notify.latest(&self) => self.hub.latest();

<*
 Block until a state newer than `seen` exists. Start with `seen = 0`, then pass
 the previous snapshot's `generation`.

 @return? TIMEOUT : "Nothing changed in time"
 @return? error::DISCONNECTED : "The centre was closed"
*>
fn Snapshot{State}*? Notify.wait_after(&self, ulong seen, Duration timeout = time::FOREVER)
{
	return self.hub.state.wait_after(seen, timeout);
}

<* Call `listener` on the worker thread for the current and every later state. Quick and non-blocking only. *>
fn WatchId{State} Notify.watch(
	&self,
	Listener{State} listener,
	void* context
) => self.hub.state.watch(listener, context);

<* Remove a listener; when this returns it is not running. Not from inside a listener. *>
fn void Notify.unwatch(&self, WatchId{State} id) => self.hub.state.unwatch(id);

<*
 Subscribe to what happened: POSTED, CLOSED and ACTION_INVOKED. A reader that
 falls behind loses the oldest events; re-read `latest()` to resynchronise.
*>
fn Reader{Event}*? Notify.subscribe(&self) => self.hub.events.subscribe();

<*
 Close an open notification and say why. A shell's dismiss button uses
 `DISMISSED`; `CLOSED_BY_CALL` and `EXPIRED` are for the same purposes as the spec.

 @return "Completes true when it was open and is now closed, NOT_FOUND when no open notification has the id"
 @return? error::INVALID_ARGUMENT : "UNDEFINED is reserved for the server's own evictions"
 @return? error::UNAVAILABLE : "The request queue is full or the centre is stopping"
*>
fn Operation{bool}*? Notify.close_notification(&self, NoteId id, CloseReason reason)
{
	if (reason == CloseReason.UNDEFINED) return error::INVALID_ARGUMENT~;
	return submit(self, { .kind = CLOSE, .id = id, .reason = reason });
}

<*
 Invoke an action of an open notification (`default` is the click). Emits
 ActionInvoked, then closes the notification unless it is resident.

 @return "Completes true when the action was invoked, NOT_FOUND for an unknown notification, INVALID_ARGUMENT for an action it does not have"
 @return? error::INVALID_ARGUMENT : "The key is empty or longer than MAX_ACTION_KEY"
 @return? error::UNAVAILABLE : "The request queue is full or the centre is stopping"
*>
fn Operation{bool}*? Notify.invoke_action(&self, NoteId id, String key)
{
	if (key.len == 0 || key.len > MAX_ACTION_KEY) return error::INVALID_ARGUMENT~;
	Command command = { .kind = INVOKE_ACTION, .id = id, .key_len = (usz)key.len };
	foreach (i, c : key) command.key[i] = c;
	return submit(self, command);
}

<* Hold back new non-critical notifications (they are recorded in history) or show them again. *>
fn void? Notify.set_do_not_disturb(&self, bool on) => self.hub.post({ .kind = SET_DO_NOT_DISTURB, .flag = on });

<* Drop the history. Open notifications are not affected. *>
fn void? Notify.clear_history(&self) => self.hub.post({ .kind = CLEAR_HISTORY });

// Queue a command that reports back. The caller gets one reference, the worker the other.
fn Operation{bool}*? submit(Notify* self, Command command)
{
	Operation{bool}* operation = operation::begin{bool}(self.allocator);
	operation.retain();
	command.operation = operation;
	if (catch err = self.hub.post(command))
	{
		operation.release();
		operation.release();
		return err~;
	}
	return operation;
}