<*
 The colour service: open it, set a temperature or a dimming, follow the sun.

 Color* color = color::open(mem)!;
 defer color.close();
 ApplyOperation* operation = color.set_temperature(color::ALL_OUTPUTS, (Kelvin)3500)!;
 defer operation.release();
 Applied applied = operation.wait(time::sec(5))!;
 if (try snapshot = color.latest())
 {
 defer snapshot.release();
 // snapshot.value.outputs[i].control.temperature, .active, .refused ...
 }

 Every method may be called from any thread. Commands return an `ApplyOperation*`: call
 `release()` on it when done, and `wait()` for the outcome. The state itself arrives through
 `latest()` and `wait_after()`.
*>
module bleu::color;
import std::collections::enummap, std::math, std::time, bleu::error, bleu::availability, bleu::observe, bleu::stream, bleu::service, bleu::operation, bleu::unit, bleu::color::schedule;

alias ColorHub = Hub{State, Command, Event};
alias Capabilities = EnumMap{Cap, Availability};

<* Requests that may wait for the worker at once; a full queue refuses with BUSY. *>
const usz COMMAND_QUEUE = 256;

<*
 The output id that addresses every display: pass it where a command takes an output. No display
 has an empty id.
*>
const String ALL_OUTPUTS = "";

struct Color
{
	Allocator allocator;
	ColorHub hub;
	Driver* driver;
	void* driver_state;
	Capabilities capabilities;
}

<*
 Open the first working backend of this platform (or the one in `options`).

 @param allocator : "Allocator for the service and its snapshots"
 @return? error::UNAVAILABLE : "No backend works here (no compositor with gamma control, or no display API)"
 @return? error::UNSUPPORTED : "The requested backend does not exist on this platform"
*>
fn Color*? open(Allocator allocator, Options options = { })
{
	if (options.tick == time::DURATION_ZERO) options.tick = DEFAULT_TICK;
	Driver* driver = select_driver(options)!;
	Color* self    = alloc::new(allocator, Color);
	self.allocator = allocator;
	self.driver = driver;
	self.driver_state = driver.create(allocator, options, &self.capabilities)!;
	if (catch err = self.hub.start(
		allocator,
		"color",
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

<*
 Stop the backend and give every display back its own ramp. Afterwards nothing this service
 wrote remains on the screen.
*>
fn void Color.close(&self)
{
	self.hub.stop();
	self.driver.destroy(self.allocator, self.driver_state);
	Allocator allocator = self.allocator;
	alloc::free(allocator, self);
}

<* Name of the backend in use, for diagnostics ("wlr-gamma", "win32-ramp", "coregraphics"). *>
fn String Color.backend_name(&self) => self.hub.backend_name;

<* Whether `cap` works with this backend, and if not, why. *>
fn Availability Color.capability(&self, Cap cap) => self.capabilities.values[cap.ordinal];

<*
 The newest state, retained for the caller (call `release()` on it).

 @return? error::UNAVAILABLE : "The backend has not produced its first state yet"
*>
fn Snapshot{State}*? Color.latest(&self) => self.hub.latest();

<*
 Block until a state newer than `seen` exists. Start with `seen = 0`, then pass the previous
 snapshot's `generation`.

 @return? TIMEOUT : "Nothing changed in time"
 @return? error::DISCONNECTED : "The service was closed"
*>
fn Snapshot{State}*? Color.wait_after(&self, ulong seen, Duration timeout = time::FOREVER)
{
	return self.hub.state.wait_after(seen, timeout);
}

<* Call `listener` on the worker thread for the current and every later state. Quick and non-blocking only. *>
fn WatchId{State} Color.watch(
	&self,
	Listener{State} listener,
	void* context
) => self.hub.state.watch(listener, context);

<* Remove a listener; when this returns it is not running. Not from inside a listener. *>
fn void Color.unwatch(&self, WatchId{State} id) => self.hub.state.unwatch(id);

<* Subscribe to transient events (gamma control taken or lost, the schedule moved the temperature). *>
fn Reader{Event}*? Color.subscribe(&self) => self.hub.events.subscribe();

<*
 Set the colour temperature of one display, or of every display when `output` is ALL_OUTPUTS.
 Stops the schedule for every display, not only the named one: the schedule is one setting of the
 service. The temperature is clamped to 1000 K .. 25000 K; the operation's value holds the clamped
 temperature.

 @param output : "A display's id, or ALL_OUTPUTS"
 @return? error::INVALID_ARGUMENT : "The output id is longer than OUTPUT_ID_CAPACITY bytes"
*>
fn ApplyOperation*? Color.set_temperature(&self, String output, Kelvin temperature)
{
	Command command = { .kind = CommandKind.SET_TEMPERATURE, .temperature = temperature };
	if (catch err = fill_output(&command, output)) return err~;
	return self.post(command);
}

<*
 Set the software dimming of one display, or of every display: the GAMMA brightness mechanism.
 The ramp is multiplied by `level` after the colour temperature, so it darkens the picture and
 does not touch the backlight. Does not stop a schedule. It shares gamma control with every other
 client: while another client holds the display's control, this returns BUSY.

 @param output : "A display's id, or ALL_OUTPUTS"
 @return? error::INVALID_ARGUMENT : "The output id is longer than OUTPUT_ID_CAPACITY bytes, or the level is NaN"
*>
fn ApplyOperation*? Color.set_dim(&self, String output, Level level)
{
	// NaN is not a level: `unit::level` would make it 0, a black picture, so it is refused.
	if (math::is_nan((float)level))
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "the dimming level is not a number")~;
	}
	Command command = { .kind = CommandKind.SET_DIM, .brightness = unit::level((float)level) };
	if (catch err = fill_output(&command, output)) return err~;
	return self.post(command);
}

<*
 Give every display back its own ramp: the schedule stops, and the temperature and dimming go to
 their defaults. The gamma controls are released, so other clients can take them.
*>
fn ApplyOperation*? Color.reset(&self)
{
	return self.post({ .kind = CommandKind.RESET });
}

<*
 Replace the schedule and apply it now. MANUAL stops following the sun or the clock and keeps the
 temperature in force.

 @return? error::INVALID_ARGUMENT : "A latitude, longitude or time of day is out of range, or the transition exceeds one hour"
*>
fn ApplyOperation*? Color.set_schedule(&self, Schedule wanted)
{
	if (catch err = schedule::validate(wanted)) return err~;
	return self.post({ .kind = CommandKind.SET_SCHEDULE, .schedule = wanted });
}

// Copy an output id into the command; an empty id addresses every display.
fn void? fill_output(Command* command, String output)
{
	if (output.len > OUTPUT_ID_CAPACITY)
	{
		return error::raise(
			error::INVALID_ARGUMENT,
			error::Domain.INTERNAL,
			0,
			"an output id is at most %d bytes",
			OUTPUT_ID_CAPACITY
		)~;
	}
	command.output_len = (usz)output.len;
	if (output.len > 0) mem::copy(&command.output, output.ptr, output.len);
}

<*
 Called by the Hub for every command still queued when the backend's run returned, whether it
 stopped or bailed out on an error. Nothing will carry such a command out, so its operation fails
 DISCONNECTED and the waiter returns.
*>
fn void abandon_command(void* backend, Command* command)
{
	command.operation.fail(error::DISCONNECTED);
	command.operation.release();
}

// Queue `command` with a fresh operation; the worker completes and releases its own reference.
fn ApplyOperation*? Color.post(&self, Command command)
{
	ApplyOperation* operation = operation::begin{Applied}(self.allocator);
	command.operation = operation;
	operation.retain();
	if (catch err = self.hub.post(command))
	{
		operation.release();
		operation.release();
		return err~;
	}
	return operation;
}