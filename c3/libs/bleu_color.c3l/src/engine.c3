<*
 The engine: the displays, the schedule and the commands that change them, on the worker thread.

 Platform-neutral. A backend supplies a `Platform` (write a ramp to a display, give a display's
 ramp back) and the displays it found; the engine decides what each command means for each
 display, builds the state, and publishes it. A display whose ramp is neutral (6500 K and
 brightness 1.0) is released, so another client may use its gamma control.

 Every command completes its `ApplyOperation` on this thread. A command that touches several
 displays applies to each, reports the first failure, and leaves the displays it could write in
 their new state: a refused display stays refused, and the others are not rolled back.
*>
module bleu::color::engine;
import bleu::color, bleu::color::kelvin, bleu::color::ramp, bleu::color::schedule, bleu::error, bleu::operation, bleu::observe, bleu::rt::poller, bleu::rt::worker, bleu::unit, std::collections::maybe, std::time, std::time::datetime, std::math, std::core::mem;

<*
 Writes a ramp to display `index`, acquiring the display's gamma control when it does not hold it.
 `ramp` holds `3 * size` floats for the display's `control.size`; it is valid during the call.

 @return? error::BUSY : "Another client holds the display's gamma control, or the display refused it"
 @return? error::UNSUPPORTED, error::BACKEND_FAILURE : "The display or the platform cannot take the ramp"
*>
alias WriteFn = fn void?(void* context, usz index, float[] ramp);

<*
 Gives display `index`'s ramp back to the system: its gamma control is released, and the display
 shows what it showed before this service wrote to it. Cannot fail: a release that the platform
 cannot complete is nothing to report, because the display no longer holds the ramp either way.
*>
alias ReleaseFn = fn void(void* context, usz index);

<* The backend's hand on the platform, as the engine calls it. `context` is the backend's own state. *>
struct Platform
{
	void* context;
	WriteFn write;
	ReleaseFn release;
}

<* One display as the engine tracks it: what clients see, and the buffer its ramps are built in. *>
struct Display
{
	Output output;
	float[] ramp;
	bool refused_seen;
}

<* The engine's state. Owned by one worker thread; the backend allocates and frees it. *>
struct Engine
{
	Allocator allocator;
	ColorHub* hub;
	Platform* platform;
	Display[] displays;
	Schedule schedule;
	bool temperature_moved;
}

<* Most commands the worker takes from its mailbox in one batch. *>
const usz COMMAND_BATCH = 8;

<*
 The number of displays a command touched, and the first failure among them. A failing display
 does not stop the others.
*>
struct Writes
{
	uint written;
	bool failed;
	fault first;
}

// Remember the first failure; later ones are not reported.
fn void Writes.failure(&self, fault failure)
{
	if (self.failed) return;
	self.failed = true;
	self.first = failure;
}

<*
 Set up the engine over `outputs`, which the backend found. Each display gets a ramp buffer of
 `3 * control.size` floats (none when the display has no size). Copies the outputs' strings.

 @param outputs : "The displays, with `id`, `name` and `control` set; `control.size` is 0 for none"
*>
fn void Engine.init(&self, Allocator allocator, ColorHub* hub, Platform* platform, Output[] outputs)
{
	*self = { .allocator = allocator, .hub = hub, .platform = platform };
	self.displays = alloc::new_array(allocator, Display, outputs.len);
	foreach (i, output : outputs)
	{
		usz size = (usz)output.control.size;
		float[] ramp;
		if (size >= 2) ramp = alloc::new_array(allocator, float, (sz)(3 * size));
		self.displays[i] = {
			.output = {
				.id = output.id.copy(allocator),
				.name = copy_text(output.name, allocator),
				.control = output.control
			},
			.ramp = ramp,
			.refused_seen = output.control.refused,
		};
	}
}

// Free the displays and their buffers. Call once, when the worker has stopped.
fn void Engine.free(&self)
{
	foreach (&display : self.displays)
	{
		alloc::free(self.allocator, display.output.id.ptr);
		if (display.output.name.len > 0) alloc::free(self.allocator, display.output.name.ptr);
		if (display.ramp.len > 0) alloc::free(self.allocator, display.ramp.ptr);
	}
	alloc::free(self.allocator, self.displays.ptr);
	*self = { };
}

// A copy of `text` in `allocator`; the empty string needs no copy.
fn String copy_text(String text, Allocator allocator) @inline => text.len == 0 ? "" : text.copy(allocator);

// Whether `command` concerns the display called `id`: every display when the command names none.
fn bool selects(
	Command* command,
	String id
) => command.output_len == 0 || id == (String)command.output[0:command.output_len];

// The index of the display called `id`, or -1 when there is none.
fn sz Engine.index_of(&self, String id)
{
	foreach (i, &display : self.displays)
	{
		if (display.output.id == id) return (sz)i;
	}
	return -1;
}

// A command that names a display must name one the engine has.
fn void? Engine.check_target(&self, Command* command)
{
	if (command.output_len == 0) return;
	String id = (String)command.output[0:command.output_len];
	if (self.index_of(id) < 0)
	{
		return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "no display called '%s'", id)~;
	}
}

<*
 Bring display `index` in line with its control: write its ramp, or release it when the ramp is
 neutral. Records a refusal on the control, so that the state says so.

 @return? error::BUSY : "Another client holds the display's gamma control"
 @return? error::UNSUPPORTED : "The display has no gamma table through this backend"
*>
fn void? Engine.apply(&self, usz index)
{
	Display* display = &self.displays[index];
	Control* control = &display.output.control;
	bool neutral     = (!control.temperature.has_value || control.temperature.value == kelvin::NEUTRAL)
		&& (float)control.brightness == 1.0f;
	if (neutral)
	{
		if (control.active) self.platform.release(self.platform.context, index);
		control.active = false;
		// Nothing is asked of the display now, so an old refusal is no longer what the state says.
		control.refused = false;
		return;
	}
	if (!control.gamma_supported)
	{
		// A refused display with no table, or one whose table is unknown: the protocol does not say which.
		if (control.refused)
		{
			return error::raise(
				error::BUSY,
				error::Domain.INTERNAL,
				0,
				"display %s: its gamma control was refused",
				display.output.id
			)~;
		}
		return error::raise(
			control.availability.refusal(),
			error::Domain.INTERNAL,
			0,
			"display %s: %s",
			display.output.id,
			control.availability.note
		)~;
	}
	// A refused display is tried again: this attempt decides whether it is still refused.
	Kelvin temperature = control.temperature.has_value ? control.temperature.value : kelvin::NEUTRAL;
	if (catch err = ramp::fill(display.ramp, (usz)control.size, temperature, control.brightness, 1.0)) return err~;
	if (catch err = self.platform.write(self.platform.context, index, display.ramp))
	{
		// Whatever the cause, the display no longer shows the ramp this service set.
		control.active = false;
		if (err == error::BUSY) control.refused = true;
		return err~;
	}
	control.active = true;
	control.refused = false;
}

<*
 The display `index` lost its gamma control to another client, or was refused it at a later
 attempt. The state says so, and the next command that needs the display reports BUSY. The
 announcement follows at the next publication.
*>
fn void Engine.lost(&self, usz index)
{
	Display* display = &self.displays[index];
	display.output.control.refused = true;
	display.output.control.active = false;
}

// Emit one transient about `output_id` (empty for every display).
fn void Engine.announce(&self, EventKind kind, String output_id)
{
	Snapshot{Event}* packet = self.hub.emit_begin();
	packet.value = { .kind = kind, .output_id = copy_text(output_id, packet.allocator()) };
	self.hub.emit(packet);
}

// Announce each display whose refusal began or ended since the last publication. Called after the state is published.
fn void Engine.announce_refusals(&self)
{
	foreach (&display : self.displays)
	{
		bool refused = display.output.control.refused;
		if (refused == display.refused_seen) continue;
		display.refused_seen = refused;
		self.announce(CONTROL_CHANGED, display.output.id);
	}
}

// Apply `command` to the displays it selects and describe the result.
fn Applied? Engine.execute(&self, Command* command)
{
	switch (command.kind)
	{
		case CommandKind.SET_TEMPERATURE: return self.set_temperature(command);
		case CommandKind.SET_DIM: return self.set_dim(command);
		case CommandKind.RESET: return self.reset();
		case CommandKind.SET_SCHEDULE: return self.set_schedule(command);
	}
}

// Set the colour temperature of the selected displays, and stop any schedule: a command is manual.
fn Applied? Engine.set_temperature(&self, Command* command)
{
	if (catch err = self.check_target(command)) return err~;
	Kelvin target = math::clamp(command.temperature, kelvin::MIN, kelvin::MAX);
	self.schedule = { };
	Writes writes;
	for (usz i = 0; i < self.displays.len; i++)
	{
		Control* control = &self.displays[i].output.control;
		if (!selects(command, self.displays[i].output.id)) continue;
		control.temperature = maybe::value(target);
		if (catch err = self.apply(i))
		{
			writes.failure(err);
		}
		else
		{
			writes.written++;
		}
	}
	if (writes.failed) return writes.first~;
	return { .outputs = writes.written, .temperature = maybe::value(target) };
}

// Set the software dimming of the selected displays. Leaves the schedule alone.
fn Applied? Engine.set_dim(&self, Command* command)
{
	if (catch err = self.check_target(command)) return err~;
	Level level = command.brightness;
	Writes writes;
	for (usz i = 0; i < self.displays.len; i++)
	{
		if (!selects(command, self.displays[i].output.id)) continue;
		self.displays[i].output.control.brightness = level;
		if (catch err = self.apply(i))
		{
			writes.failure(err);
		}
		else
		{
			writes.written++;
		}
	}
	if (writes.failed) return writes.first~;
	return { .outputs = writes.written, .brightness = maybe::value(level) };
}

// Forget the schedule, the temperatures and the dimming: every display goes back to its own ramp.
fn Applied? Engine.reset(&self)
{
	self.schedule = { };
	Writes writes;
	for (usz i = 0; i < self.displays.len; i++)
	{
		Control* control = &self.displays[i].output.control;
		control.temperature.reset();
		control.brightness = (Level)1.0f;
		if (catch err = self.apply(i))
		{
			writes.failure(err);
		}
		else
		{
			writes.written++;
		}
	}
	if (writes.failed) return writes.first~;
	return { .outputs = writes.written };
}

// Replace the schedule and apply its temperature now, rather than at the next tick.
fn Applied? Engine.set_schedule(&self, Command* command)
{
	self.schedule = command.schedule;
	Maybe{Kelvin} target = self.target_now(time::now());
	if (!target.has_value) return { .outputs = (uint)self.displays.len };
	if (catch err = self.follow(target.value)) return err~;
	return { .outputs = (uint)self.displays.len, .temperature = target };
}

<*
 The temperature the schedule asks for at `now`, or empty for MANUAL.
*>
fn Maybe{Kelvin} Engine.target_now(&self, Time now)
{
	if (self.schedule.mode == Mode.MANUAL) return { };
	return maybe::value(schedule::temperature_at(self.schedule, now, local_offset(now)));
}

<*
 Give every display `target` as its temperature, and write those whose temperature changed (or
 that were refused, so that they are tried again). A change of temperature is announced at the
 next publication, and a display that is only retried announces nothing.

 @return? error::BUSY, error::UNSUPPORTED, error::BACKEND_FAILURE : "The first display that could not take the ramp"
*>
fn void? Engine.follow(&self, Kelvin target)
{
	Writes writes;
	for (usz i = 0; i < self.displays.len; i++)
	{
		Control* control = &self.displays[i].output.control;
		bool moved = !control.temperature.has_value || control.temperature.value != target;
		if (!moved && !control.refused) continue;
		if (moved)
		{
			control.temperature = maybe::value(target);
			self.temperature_moved = true;
		}
		if (catch err = self.apply(i))
		{
			writes.failure(err);
		}
	}
	if (writes.failed) return writes.first~;
}

<*
 Re-evaluate the schedule. Called by the worker on every tick. Failures are in the state, not
 returned: nobody asked for this change.
*>
fn void Engine.tick(&self)
{
	if (catch self.follow_now())
	{
	}
}

// The schedule's temperature at the current time, applied.
fn void? Engine.follow_now(&self)
{
	Maybe{Kelvin} target = self.target_now(time::now());
	if (!target.has_value) return;
	return self.follow(target.value);
}

// The local offset from UTC at `now`, in microseconds (the platform's time zone rules).
fn Duration local_offset(Time now)
{
	DateTime utc     = datetime::from_time(now);
	TzDateTime local = utc.to_local();
	return (Duration)((long)local.gmt_offset * (long)time::SEC);
}

// Publish the current state if it differs from the last one published, then announce what changed. A transient
// always follows the state that shows it, so a listener woken by it reads that state.
fn void Engine.publish(&self)
{
	Snapshot{State}* snapshot = self.hub.begin();
	Allocator allocator       = snapshot.allocator();
	Output[] outputs;
	if (self.displays.len > 0) outputs = alloc::new_array(allocator, Output, self.displays.len);
	foreach (i, display : self.displays)
	{
		outputs[i] = {
			.id = copy_text(display.output.id, allocator),
			.name = copy_text(display.output.name, allocator),
			.control = display.output.control,
		};
	}
	snapshot.value = { .outputs = outputs, .schedule = self.schedule };
	self.hub.publish_if_changed(snapshot);
	self.announce_refusals();
	if (self.temperature_moved)
	{
		self.temperature_moved = false;
		self.announce(TEMPERATURE_CHANGED, "");
	}
}

// Take every queued command and handle it.
fn void Engine.drain(&self, Host{Command}* host)
{
	Command[COMMAND_BATCH] batch;
	usz taken;
	while ((taken = host.mailbox().take_all(batch[..])) > 0)
	{
		for (usz i = 0; i < taken; i++) self.handle(&batch[i]);
	}
}

// Run one command and complete its operation with the result, then release the worker's reference.
fn void Engine.handle(&self, Command* command)
{
	ApplyOperation* operation = command.operation;
	Applied? result           = self.execute(command);
	if (catch err = result)
	{
		operation.fail(err);
	}
	else
	{
		operation.succeed(result);
	}
	operation.release();
}

// Shutdown: commands still queued end CANCELLED, so that every waiter returns.
fn void Engine.cancel_queued(&self, Host{Command}* host)
{
	Command[COMMAND_BATCH] batch;
	usz taken;
	while ((taken = host.mailbox().take_all(batch[..])) > 0)
	{
		for (usz i = 0; i < taken; i++)
		{
			batch[i].operation.fail(error::CANCELLED);
			batch[i].operation.release();
		}
	}
}

<*
 The worker loop of a backend with no descriptor to wait on (Windows, macOS): wait for a command
 or the next tick, then run the commands, re-evaluate the schedule and publish. Returns when the
 worker stops; commands still queued end CANCELLED.
*>
fn void serve_timed(Engine* engine, Host{Command}* host, Duration tick)
{
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 0)) return;
	defer poller.free();
	engine.publish();
	while (!host.stopping())
	{
		// TIMEOUT is the normal tick; a command wakes the wait early.
		if (catch poller.wait(tick))
		{
		}
		engine.drain(host);
		engine.tick();
		engine.publish();
	}
	engine.cancel_queued(host);
}