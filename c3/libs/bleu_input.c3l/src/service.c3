<*
 The input service: open it, read `latest()`, change the layout, wait for changes.

 Input* input = input::open(mem)!;
 defer input.close();
 if (try snapshot = input.latest())
 {
 defer snapshot.release();
 // snapshot.value.layouts, snapshot.value.current ...
 }
 SwitchOperation* operation = input.next()!;
 defer operation.release();
 SwitchOutcome outcome = operation.wait(time::sec(2))!;

 Every method may be called from any thread.
*>
module bleu::input;
import std::collections::enummap, std::time, bleu::availability, bleu::error, bleu::observe, bleu::operation, bleu::service, bleu::stream;

alias Capabilities = EnumMap{Cap, Availability};

<*
 The poll interval for backends that are not woken by a change: 1 s, in microseconds (`time::sec()`
 cannot initialise a global).
*>
const Duration DEFAULT_POLL = (Duration)1_000_000;

<* An open input service. Created by `open`, released by `close`. *>
struct Input
{
	Allocator allocator;
	InputHub hub;
	Driver* driver;
	void* driver_state;
	Capabilities capabilities;
}

<*
 Open the first working backend of this platform (or the one in `options`).

 @param allocator : "Allocator for the service and its snapshots"
 @return? error::UNAVAILABLE : "No backend works here (no compositor, no system bus, no keyboard API)"
 @return? error::UNSUPPORTED : "The requested backend does not exist on this platform"
*>
fn Input*? open(Allocator allocator, Options options = { })
{
	if (options.poll == time::DURATION_ZERO) options.poll = DEFAULT_POLL;
	Driver* driver = select_driver(options)!;
	Input* self    = alloc::new(allocator, Input);
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
		"input",
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

<* Stop the backend and release everything. *>
fn void Input.close(&self)
{
	self.hub.free();
	self.driver.destroy(self.allocator, self.driver_state);
	Allocator allocator = self.allocator;
	alloc::free(allocator, self);
}

<* Name of the backend in use, for diagnostics ("compositor", "locale1", "tis", "win32"). *>
fn String Input.backend_name(&self) => self.hub.backend_name;

<* Whether `cap` works with this backend, and if not, why. *>
fn Availability Input.capability(&self, Cap cap) => self.capabilities.values[cap.ordinal];

<*
 The newest state, retained for the caller (call `release()` on it).

 @return? error::UNAVAILABLE : "The backend has not produced its first reading yet"
*>
fn Snapshot{State}*? Input.latest(&self) => self.hub.latest();

<*
 Block until a state newer than `seen` exists. Start with `seen = 0`, then pass the previous snapshot's
 `generation`.

 @return? TIMEOUT : "Nothing changed in time"
 @return? error::DISCONNECTED : "The service was closed"
*>
fn Snapshot{State}*? Input.wait_after(&self, ulong seen, Duration timeout = time::FOREVER)
{
	return self.hub.state.wait_after(seen, timeout);
}

<* Call `listener` on the worker thread for the current and every later state. Quick and non-blocking only. *>
fn WatchId{State} Input.watch(
	&self,
	Listener{State} listener,
	void* context
) => self.hub.state.watch(listener, context);

<*
 Remove a listener; when this returns it is not running.

 @return? error::INVALID_STATE : "Called from inside the listener it would remove"
*>
fn void? Input.unwatch(&self, WatchId{State} id) => self.hub.state.unwatch(id);

<* Subscribe to transient events (layouts or the active layout changed). *>
fn Reader{Event}*? Input.subscribe(&self) => self.hub.events.subscribe();

<*
 Make the layout `layout_id` the active one. Returns at once. The operation finishes when the backend
 has handed the request over (see `SwitchOutcome`); the change itself arrives through `latest()`.

 @param layout_id : "A `Layout.id` from the current state"
 @return? error::UNSUPPORTED, error::UNAVAILABLE : "This backend cannot switch here (see `capability(SWITCH)`)"
 @return? error::INVALID_ARGUMENT : "The id is empty"
 @return? NOT_FOUND : "No layout in the current state has that id"
 @return? error::BUSY : "The worker's queue is full"
*>
fn SwitchOperation*? Input.switch_to(&self, String layout_id)
{
	if (layout_id.len == 0)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "the layout id is empty")~;
	}
	Availability switch_ok = self.capability(Cap.SWITCH);
	if (!switch_ok.ok()) return switch_ok.refusal()~;
	Snapshot{State}* snapshot = self.hub.latest()!;
	defer snapshot.release();
	if (index_of(snapshot.value.layouts, layout_id) < 0)
	{
		return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "no layout '%s' in the current state", layout_id)~;
	}
	return self.post_switch(layout_id);
}

<*
 Make the next layout in the list active, wrapping around from the last. With no known active layout,
 the first one is chosen. Same results as `switch_to`.

 @return? error::INVALID_STATE : "Fewer than two layouts are known"
 @return? error::UNSUPPORTED, error::UNAVAILABLE : "This backend cannot switch here (see `capability(SWITCH)`)"
 @return? error::UNAVAILABLE : "The backend has not produced its first reading yet"
*>
fn SwitchOperation*? Input.next(&self)
{
	Availability switch_ok = self.capability(Cap.SWITCH);
	if (!switch_ok.ok()) return switch_ok.refusal()~;
	Snapshot{State}* snapshot = self.hub.latest()!;
	defer snapshot.release();
	usz count = snapshot.value.layouts.len;
	if (count < 2)
	{
		return error::raise(
			error::INVALID_STATE,
			error::Domain.INTERNAL,
			0,
			"%d layout(s) known: nothing to switch to",
			count
		)~;
	}
	usz from   = snapshot.value.current.has_value ? (usz)snapshot.value.current.value : count - 1;
	usz target = (from + 1) % count;
	return self.post_switch(snapshot.value.layouts[target].id);
}

// Queue a switch to `layout_id` for the worker. The id is copied into the operation's arena, which lives
// until the worker completes the operation.
fn SwitchOperation*? Input.post_switch(&self, String layout_id)
{
	SwitchOperation* operation = operation::begin{SwitchOutcome}(self.allocator);
	String id                  = layout_id.copy(operation.allocator());
	Command command            = { .kind = SWITCH_TO, .id = id, .operation = operation };
	// The worker holds its own reference until it completes the operation.
	operation.retain();
	if (catch err = self.hub.post(command))
	{
		operation.release();
		operation.release();
		return err~;
	}
	return operation;
}

<* Ask the backend to read the platform now; returns once the request is queued. *>
fn void? Input.refresh(&self)
{
	Command command = { .kind = REFRESH };
	return self.hub.post(command);
}