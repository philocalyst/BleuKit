<*
 The display service: open it, read `latest()`, change the layout with `apply`.

 Display* display = display::open(mem)!;
 defer display.close();
 if (try snapshot = display.latest())
 {
 defer snapshot.release();
 // snapshot.value.outputs: positions, modes, scale, transform per output
 }

 Every method may be called from any thread. A change is carried out by the backend's worker;
 `apply` returns at once and completes when the platform has accepted (or refused) it.
*>
module bleu::display;
import std::collections::enummap, std::time, bleu::error, bleu::availability, bleu::observe, bleu::stream, bleu::operation, bleu::service;

alias DisplayHub = Hub{State, Command, Event};

<* How `open` finds and tunes a backend. *>
struct Options
{
	Backend backend; // AUTO tries every backend of the platform in priority order
	String root; // prefix for kernel pseudo-files (Linux EDID lookup), "" for the real system
}

<* The open display service. Allocated by `open`, released by `close`. *>
struct Display
{
	Allocator allocator;
	DisplayHub hub;
	Driver* driver;
	void* driver_state;
	Capabilities capabilities;
}

<*
 Open the first working backend of this platform (or the one in `options`).

 @param allocator : "Allocator for the service and its snapshots"
 @return? error::UNAVAILABLE : "No display backend works here"
 @return? error::UNSUPPORTED : "The requested backend does not exist on this platform"
*>
fn Display*? open(Allocator allocator, Options options = { })
{
	Driver* driver = select_driver(options)!;
	Display* self  = alloc::new(allocator, Display);
	self.allocator = allocator;
	self.driver = driver;
	self.driver_state = driver.create(allocator, options, &self.capabilities)!;
	if (catch err = self.hub.start(allocator, "display", driver.info.name, driver.run, self.driver_state))
	{
		driver.destroy(allocator, self.driver_state);
		alloc::free(allocator, self);
		return err~;
	}
	return self;
}

<* Stop the backend and release everything. Operations still waiting are failed with DISCONNECTED. *>
fn void Display.close(&self)
{
	self.hub.stop();
	self.driver.destroy(self.allocator, self.driver_state);
	Allocator allocator = self.allocator;
	alloc::free(allocator, self);
}

<* Name of the backend in use, for diagnostics ("wayland", "coregraphics", "windows"). *>
fn String Display.backend_name(&self) => self.hub.backend_name;

<* Whether `cap` works with this backend, and if not, why. *>
fn Availability Display.capability(&self, Cap cap) => self.capabilities.values[cap.ordinal];

<*
 The newest state, retained for the caller (call `release()` on it).

 @return? error::UNAVAILABLE : "The backend has not produced its first reading yet"
*>
fn Snapshot{State}*? Display.latest(&self) => self.hub.latest();

<*
 Block until a state newer than `seen` exists. Start with `seen = 0`, then pass the previous
 snapshot's `generation`.

 @return? TIMEOUT : "Nothing changed in time"
 @return? error::DISCONNECTED : "The service was closed"
*>
fn Snapshot{State}*? Display.wait_after(&self, ulong seen, Duration timeout = time::FOREVER)
{
	return self.hub.state.wait_after(seen, timeout);
}

<* Call `listener` on the worker thread for the current and every later state. Quick and non-blocking only. *>
fn WatchId{State} Display.watch(&self, Listener{State} listener, void* context) => self.hub.state.watch(listener, context);

<* Remove a listener; when this returns it is not running. Not from inside a listener. *>
fn void Display.unwatch(&self, WatchId{State} id) => self.hub.state.unwatch(id);

<* Subscribe to transient events (outputs added, removed, changed; a change reverted). *>
fn Reader{Event}*? Display.subscribe(&self) => self.hub.events.subscribe();

<* Ask the backend to re-read the hardware now; returns once the request is queued. *>
fn void? Display.refresh(&self)
{
	Command command = { .kind = REFRESH };
	return self.hub.post(command);
}

<*
 Carry out `config`, a full desired layout (one entry per output, from `latest()`). The returned
 operation completes with the outcome once the platform has accepted or refused the change.

 `APPLY_WITH_REVERT` makes the change live and rolls it back to the current state after
 `revert_after` unless `confirm` is called first. The caller must keep the operation until it
 completes; the arguments are copied, so the caller's `config` may be released at once.

 @return? error::UNSUPPORTED : "This backend cannot revert, or cannot persist, the change"
 @return? error::BUSY : "The request queue is full"
*>
fn ApplyOp*? Display.apply(&self, Config config, ApplyMode mode, Duration revert_after = time::DURATION_ZERO)
{
	if (mode == APPLY_WITH_REVERT) require_cap(self, REVERT)!;
	if (config.persistent) require_cap(self, PERSISTENT)!;
	ApplyOp* op = operation::begin(self.allocator);
	Command command = {
		.kind = APPLY,
		.op = op,
		.config = copy_config(config, op.allocator()),
		.mode = mode,
		.revert_after = revert_after,
	};
	op.retain();
	if (catch err = self.hub.post(command))
	{
		op.release();
		op.release();
		return err~;
	}
	return op;
}

<*
 Keep the change waiting for confirmation (see `apply` with `APPLY_WITH_REVERT`). Nothing is
 waiting, or the deadline has passed, makes this a no-op.
*>
fn void? Display.confirm(&self)
{
	Command command = { .kind = CONFIRM };
	return self.hub.post(command);
}

// Refuse, as UNSUPPORTED or UNAVAILABLE, a request the backend cannot serve.
fn void? require_cap(Display* display, Cap cap)
{
	Availability availability = display.capabilities.values[cap.ordinal];
	if (!availability.ok()) return availability.refusal()~;
}

// A deep copy of `config` in `allocator`, so that a command owns its bytes.
fn Config copy_config(Config config, Allocator allocator)
{
	OutputChange[] outputs = alloc::new_array(allocator, OutputChange, config.outputs.len);
	for (sz i = 0; i < config.outputs.len; i++) {
		outputs[i] = config.outputs[i];
		outputs[i].output_id = config.outputs[i].output_id.copy(allocator);
	}
	return { .outputs = outputs, .persistent = config.persistent };
}
