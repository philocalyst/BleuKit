<*
 The engine: the loop every platform's worker runs. It serves the command
 mailbox, steps smooth transitions, re-reads the platform on its poll interval
 and publishes the result, announcing what changed.

 Platform code supplies only `read` and `write` (see `Platform`). Everything
 about requests, policies, transitions and publication is here, once.
*>
module bleu::brightness;
import std::thread, std::time, std::time::clock, bleu::equal, bleu::error, bleu::observe, bleu::operation, bleu::rt::poller, bleu::rt::worker, bleu::service, bleu::unit;

<* Most smooth transitions in progress at once; one per device in practice. *>
const usz MAX_RAMPS = 8;

<* Commands taken from the mailbox per batch. *>
const usz COMMAND_BATCH = 16;

<* A smooth transition in progress: its request, where it started and when. *>
struct Ramp
{
	Command command;
	Level from;
	Clock started;
	bool active;
}

<* The state the loop carries between passes. *>
struct Engine
{
	BrightnessHub* hub;
	Platform* platform;
	Duration poll;
	Duration step;
	Clock published;
	Ramp[MAX_RAMPS] ramps;
}

<*
 Run the engine until the worker is asked to stop. Called on the worker thread
 by each platform's `run`.

 @param poll : "How often the platform is re-read"
 @param step : "How often a transition in progress advances"
*>
fn void serve(BrightnessHub* hub, Host{Command}* host, Platform* platform, Duration poll, Duration step)
{
	Engine engine = { .hub = hub, .platform = platform, .poll = poll, .step = step, .published = clock::now() };
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 0)) return;
	defer poller.free();
	engine.publish();
	Command[COMMAND_BATCH] batch;
	while (!host.stopping())
	{
		// Sleeps until the next poll, the next transition step, or a command.
		Duration wait = engine.transitions_active() ? step : poll;
		if (catch err = poller.wait(wait))
		{
			// TIMEOUT is the normal tick. Any other failure would spin this loop, so pause a tick instead.
			if (err != TIMEOUT) thread::sleep(wait);
		}
		usz taken;
		while ((taken = host.mailbox().take_all(batch[..])) > 0)
		{
			for (usz i = 0; i < taken; i++) engine.handle(&batch[i]);
		}
		engine.step_ramps();
		if (since(engine.published) >= poll) engine.publish();
	}
	engine.finish(host);
}

// Time elapsed since `then`, in the service's duration unit.
fn Duration since(Clock then) @inline => (Duration)((long)clock::now().nano_diff(then) / 1000);

<*
 Read the platform and publish the state if it differs from the last one. The state is
 published first and its transients are announced after it, so a listener woken by an event
 reads the state that event describes.

 A failed read keeps the last published state: an empty state would announce every device
 as removed. Until the first successful read there is no state at all.
*>
fn void Engine.publish(&self)
{
	Snapshot{State}* snapshot = self.hub.begin();
	State? state              = self.platform.read(self.platform.context, snapshot.allocator());
	self.published = clock::now();
	if (catch err = state)
	{
		snapshot.release();
		return;
	}
	else
	{
		snapshot.value = state;
	}
	if (try previous = self.hub.latest())
	{
		defer previous.release();
		if (equal::deep(previous.value, snapshot.value))
		{
			snapshot.release();
			return;
		}
		self.hub.publish(snapshot);
		if (try current = self.hub.latest())
		{
			defer current.release();
			self.announce(&previous.value, &current.value);
		}
		return;
	}
	self.hub.publish(snapshot);
}

// Emit the transients that turn `before` into `after`.
fn void Engine.announce(&self, State* before, State* after)
{
	foreach (&device : after.devices)
	{
		Device* old = find_device(before, device.id);
		if (!old)
		{
			self.emit(DEVICE_ADDED, device.id, BACKLIGHT);
			continue;
		}
		foreach (&control : device.controls)
		{
			Control* previous = old.control(control.mechanism);
			if (!previous || same_level(previous.level, control.level)) continue;
			self.emit(LEVEL_CHANGED, device.id, control.mechanism);
		}
	}
	foreach (&device : before.devices)
	{
		if (!find_device(after, device.id)) self.emit(DEVICE_REMOVED, device.id, BACKLIGHT);
	}
}

fn void Engine.emit(&self, EventKind kind, String device_id, Mechanism mechanism)
{
	Snapshot{Event}* packet = self.hub.emit_begin();
	packet.value = { .kind = kind, .device_id = device_id.copy(packet.allocator()), .mechanism = mechanism };
	self.hub.emit(packet);
}

fn bool Engine.transitions_active(&self)
{
	foreach (&ramp : self.ramps)
	{
		if (ramp.active) return true;
	}
	return false;
}

<* Carry out one command. Requests complete their operation; a refresh publishes. *>
fn void Engine.handle(&self, Command* command)
{
	if (command.kind == REFRESH)
	{
		self.publish();
		return;
	}
	String device_id = command.device_id();
	self.cancel_ramps(device_id);
	if (command.transition == time::DURATION_ZERO)
	{
		Applied? applied = self.apply_now(device_id, command.policy, command.level);
		if (catch err = applied)
		{
			finish_op(command.operation, err);
		}
		else
		{
			succeed_op(command.operation, applied);
		}
		self.publish();
		return;
	}
	Ramp* ramp = self.free_ramp();
	if (!ramp)
	{
		finish_op(
			command.operation,
			error::raise(error::BUSY, error::Domain.INTERNAL, 0, "%d transitions are already running", MAX_RAMPS)
		);
		return;
	}
	Level? from = self.current_level(device_id);
	if (catch err = from)
	{
		// A ramp needs a level to start from; without one it would jump, so the request is refused.
		finish_op(
			command.operation,
			error::raise(
				error::UNAVAILABLE,
				error::Domain.INTERNAL,
				0,
				"'%s' has no readable level to ramp from",
				device_id
			)
		);
		return;
	}
	*ramp = { .command = *command, .from = from, .started = clock::now(), .active = true };
}

// The first ramp slot that is not running, or null.
fn Ramp* Engine.free_ramp(&self)
{
	foreach (&ramp : self.ramps)
	{
		if (!ramp.active) return ramp;
	}
	return null;
}

// End every transition running for `device_id`: a new request replaces it.
fn void Engine.cancel_ramps(&self, String device_id)
{
	foreach (&ramp : self.ramps)
	{
		if (!ramp.active || ramp.command.device_id() != device_id) continue;
		ramp.active = false;
		finish_op(ramp.command.operation, error::CANCELLED);
	}
}

// Advance every running transition by its due step.
fn void Engine.step_ramps(&self)
{
	foreach (&ramp : self.ramps)
	{
		if (ramp.active) self.step_ramp(ramp);
	}
}

fn void Engine.step_ramp(&self, Ramp* ramp)
{
	Command* command = &ramp.command;
	Duration elapsed = since(ramp.started);
	Level level      = ramp_level(ramp.from, command.level, elapsed, command.transition);
	Applied? applied = self.apply_now(command.device_id(), command.policy, level);
	if (catch err = applied)
	{
		ramp.active = false;
		finish_op(command.operation, err);
	}
	else if (ramp_done(elapsed, command.transition))
	{
		ramp.active = false;
		succeed_op(command.operation, applied);
	}
	self.publish();
}

// Carry out one write against the last published state.
fn Applied? Engine.apply_now(&self, String device_id, Policy policy, Level level)
{
	Snapshot{State}* snapshot = self.hub.latest()!;
	defer snapshot.release();
	return apply(self.platform, &snapshot.value, device_id, policy, level);
}

// The level `device_id` shows now, from its first control that has one.
fn Level? Engine.current_level(&self, String device_id)
{
	Snapshot{State}* snapshot = self.hub.latest()!;
	defer snapshot.release();
	Device* device = find_device(&snapshot.value, device_id);
	if (!device) return NOT_FOUND~;
	foreach (&control : device.controls)
	{
		if (control.level.has_value) return control.level.value;
	}
	return NOT_FOUND~;
}

// Succeed an operation with `applied`, and release the worker's reference.
fn void succeed_op(SetOperation* operation, Applied applied)
{
	operation.succeed(applied);
	operation.release();
}

// Fail an operation with `failure`, and release the worker's reference.
fn void finish_op(SetOperation* operation, fault failure)
{
	operation.fail(failure);
	operation.release();
}

<*
 Called by the Hub for every request still queued when `run` returns, including an early return on
 an error. Such a request can never run, so its operation fails DISCONNECTED.
*>
fn void abandon_command(void* backend, Command* command)
{
	if (command.kind == SET_LEVEL) finish_op(command.operation, error::DISCONNECTED);
}

// The device this command names.
fn String Command.device_id(&self) => (String)self.device[0:self.device_len];

// Shutdown: every transition and every queued request ends CANCELLED.
fn void Engine.finish(&self, Host{Command}* host)
{
	foreach (&ramp : self.ramps)
	{
		if (!ramp.active) continue;
		ramp.active = false;
		finish_op(ramp.command.operation, error::CANCELLED);
	}
	Command[COMMAND_BATCH] batch;
	usz taken;
	while ((taken = host.mailbox().take_all(batch[..])) > 0)
	{
		for (usz i = 0; i < taken; i++)
		{
			if (batch[i].kind == SET_LEVEL) finish_op(batch[i].operation, error::CANCELLED);
		}
	}
}