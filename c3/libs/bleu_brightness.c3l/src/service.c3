<*
 The brightness service: open it, read `latest()`, set levels, wait for changes.

 Brightness* brightness = brightness::open(mem)!;
 defer brightness.close();
 SetOperation* op = brightness.set_level("eDP-1", (Level)0.5)!;
 defer op.release();
 Applied applied = op.wait(time::sec(2))!;

 Every method may be called from any thread.
*>
module bleu::brightness;
import std::collections::enummap, std::math, std::time, bleu::error, bleu::availability, bleu::observe, bleu::stream, bleu::service, bleu::operation, bleu::unit;

alias BrightnessHub = Hub{State, Command, Event};

<* Requests that may wait for the worker at once; a full queue refuses with BUSY. *>
const usz COMMAND_QUEUE = 256;
alias Capabilities = EnumMap{Cap, Availability};

<*
 The worker's view of the platform, as the engine needs it. `read` builds a
 complete state into the given allocator; `write` moves one control of one device
 and reports what happened. Both run on the worker thread.
*>
alias ReadFn = fn State?(void* context, Allocator allocator);
alias WriteFn = fn Applied?(void* context, String device_id, Mechanism mechanism, Level level);

struct Platform
{
	void* context;
	ReadFn read;
	WriteFn write;
}

struct Brightness
{
	Allocator allocator;
	BrightnessHub hub;
	Driver* driver;
	void* driver_state;
	Capabilities capabilities;
}

<*
 Open the first working backend of this platform (or the one in `options`).

 @param allocator : "Allocator for the service and its snapshots"
 @return? error::UNAVAILABLE : "No backend works here (no backlight, LED, monitor or panel API)"
 @return? error::UNSUPPORTED : "The requested backend does not exist on this platform"
*>
fn Brightness*? open(Allocator allocator, Options options = { })
{
	if (options.poll == time::DURATION_ZERO) options.poll = DEFAULT_POLL;
	if (options.transition_step == time::DURATION_ZERO) options.transition_step = DEFAULT_TRANSITION_STEP;
	Driver* driver   = select_driver(options)!;
	Brightness* self = alloc::new(allocator, Brightness);
	self.allocator = allocator;
	self.driver = driver;
	self.driver_state = driver.create(allocator, options, &self.capabilities)!;
	if (catch err = self.hub.start(
		allocator,
		"brightness",
		driver.info.name,
		driver.run,
		self.driver_state,
		COMMAND_QUEUE,
		&abandon_command
	))
	{
		driver.destroy(allocator, self.driver_state);
		alloc::free(allocator, self);
		return err~;
	}
	return self;
}

<* Stop the backend, fail every request still waiting, and release everything. *>
fn void Brightness.close(&self)
{
	self.hub.stop();
	self.driver.destroy(self.allocator, self.driver_state);
	Allocator allocator = self.allocator;
	alloc::free(allocator, self);
}

<* Name of the backend in use, for diagnostics ("linux", "win32", "macos"). *>
fn String Brightness.backend_name(&self) => self.hub.backend_name;

<* Whether `cap` works with this backend, and if not, why. *>
fn Availability Brightness.capability(&self, Cap cap) => self.capabilities.values[cap.ordinal];

<*
 The newest state, retained for the caller (call `release()` on it).

 @return? error::UNAVAILABLE : "The backend has not produced its first reading yet"
*>
fn Snapshot{State}*? Brightness.latest(&self) => self.hub.latest();

<*
 Block until a state newer than `seen` exists. Start with `seen = 0`, then pass
 the previous snapshot's `generation`.

 @return? TIMEOUT : "Nothing changed in time"
 @return? error::DISCONNECTED : "The service was closed"
*>
fn Snapshot{State}*? Brightness.wait_after(&self, ulong seen, Duration timeout = time::FOREVER)
{
	return self.hub.state.wait_after(seen, timeout);
}

<* Call `listener` on the worker thread for the current and every later state. Quick and non-blocking only. *>
fn WatchId{State} Brightness.watch(
	&self,
	Listener{State} listener,
	void* context
) => self.hub.state.watch(listener, context);

<* Remove a listener; when this returns it is not running. Not from inside a listener. *>
fn void Brightness.unwatch(&self, WatchId{State} id) => self.hub.state.unwatch(id);

<* Subscribe to transient events (level changes, devices added or removed). *>
fn Reader{Event}*? Brightness.subscribe(&self) => self.hub.events.subscribe();

<*
 Ask for `device`'s light to be set to `level`. Returns at once; the operation
 finishes when the write has been carried out (after the ramp, when `transition`
 is not zero). The world's change then also arrives through `latest()`.

 `transition` is a smooth ramp from the current level, 0 for an immediate
 change. A new request for the same device ends a ramp in progress with
 CANCELLED.

 @param device : "The device id from `State`, for example a connector name or a backlight name"
 @param policy : "Which mechanisms the request may use; see `PolicyKind`"
 @return? error::INVALID_ARGUMENT : "The device id is empty or too long, the level is NaN, or the transition is negative"
 @return? error::BUSY : "The worker's queue is full"
 @return? error::UNAVAILABLE : "The service is closed"
*>
fn SetOperation*? Brightness.set_level(
	&self,
	String device,
	Level level,
	Policy policy = DEFAULT_POLICY,
	Duration transition = time::DURATION_ZERO
)
{
	if (device.len == 0 || device.len > DEVICE_ID_CAPACITY)
	{
		return error::raise(
			error::INVALID_ARGUMENT,
			error::Domain.INTERNAL,
			0,
			"device id must be 1 to %d bytes",
			DEVICE_ID_CAPACITY
		)~;
	}
	// NaN is not a level: refusing it keeps `unit::level`'s silent mapping of NaN to 0 out of requests.
	if (math::is_nan((float)level))
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "level is not a number")~;
	}
	if (transition < time::DURATION_ZERO)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "transition must not be negative")~;
	}
	SetOperation* operation = operation::begin{Applied}(self.allocator);
	Command command = {
		.kind = SET_LEVEL,
		.device_len = (usz)device.len,
		.level = unit::level((float)level),
		.policy = policy,
		.transition = transition,
		.operation = operation,
	};
	mem::copy(&command.device, device.ptr, device.len);
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

<* Ask the backend to re-read the hardware now; returns once the request is queued. *>
fn void? Brightness.refresh(&self) => self.hub.post({ .kind = REFRESH });