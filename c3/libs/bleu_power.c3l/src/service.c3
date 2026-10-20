<*
 The power service: open it, read `latest()`, ask for changes, wait for events.

 Power* power = power::open(mem)!;
 defer power.close();
 if (try snapshot = power.latest())
 {
 defer snapshot.release();
 // snapshot.value.active_profile, snapshot.value.lid_closed ...
 }
 if (try request = power.set_profile(POWER_SAVER))
 {
 // request.wait() says whether the daemon accepted the change
 }

 Every method may be called from any thread. Requests return an operation
 (`Operation{Value}*`) that the caller releases; the worker completes it once.
*>
module bleu::power;
import std::collections::enummap, std::time, bleu::error, bleu::availability, bleu::observe, bleu::operation,
	bleu::stream, bleu::service;

alias PowerHub = Hub{State, Command, Event};
alias Capabilities = EnumMap{Cap, Availability};

<*
 How `open` finds and tunes a backend.
*>
struct Options
{
	Backend backend; // AUTO tries every mechanism of the platform in priority order
	bool sleep_barrier; // hold a delay lock so that `PREPARE_SLEEP` waits for `ack` (Linux)
	String bus_address; // Linux: the system bus address, "" for the default (DBUS_SYSTEM_BUS_ADDRESS, then the well-known socket)
}

<* The service: one worker thread, one `State`, one event stream. *>
struct Power
{
	Allocator allocator;
	PowerHub hub;
	Driver* driver;
	void* driver_state;
	Capabilities capabilities;
	Startup startup;
}

<*
 Open the first working mechanism of this platform (or the one in `options`).
 Blocks until the mechanism has connected and read its first state.

 @param allocator : "Allocator for the service and its snapshots"
 @return? error::UNAVAILABLE : "No mechanism works here (no power management service is running)"
 @return? error::UNSUPPORTED : "The requested mechanism does not exist on this platform"
*>
fn Power*? open(Allocator allocator, Options options = { })
{
	Driver* driver = select_driver(options)!;
	Power* self    = alloc::new(allocator, Power);
	self.allocator = allocator;
	self.driver    = driver;
	self.capabilities.init(availability::no(availability::Reason.BACKEND_STOPPED, "the mechanism has not started"));
	self.startup.init();
	void*? state = driver.create(allocator, options, &self.capabilities, &self.startup);
	if (catch err = state)
	{
		self.startup.free();
		alloc::free(allocator, self);
		return err~;
	}
	self.driver_state = state;
	if (catch err = self.hub.start(allocator, "power", driver.info.name, driver.run, self.driver_state))
	{
		driver.destroy(allocator, self.driver_state);
		self.startup.free();
		alloc::free(allocator, self);
		return err~;
	}
	if (catch err = self.startup.wait())
	{
		self.close();
		return err~;
	}
	return self;
}

<* Stop the worker, release everything, and fail every request still queued. *>
fn void Power.close(&self)
{
	self.hub.stop();
	self.driver.destroy(self.allocator, self.driver_state);
	self.startup.free();
	Allocator allocator = self.allocator;
	alloc::free(allocator, self);
}

<* Name of the mechanism in use, for diagnostics ("logind", "macos", "win32"). *>
fn String Power.backend_name(&self) => self.hub.backend_name;

<* Whether `cap` works with this mechanism, and if not, why. *>
fn Availability Power.capability(&self, Cap cap) => self.capabilities.get(cap);

<*
 The newest state, retained for the caller (call `release()` on it).

 @return? error::UNAVAILABLE : "The mechanism has not produced its first reading yet"
*>
fn Snapshot{State}*? Power.latest(&self) => self.hub.latest();

<*
 Block until a state newer than `seen` exists. Start with `seen = 0`, then pass
 the previous snapshot's `generation`.

 @return? TIMEOUT : "Nothing changed in time"
 @return? error::DISCONNECTED : "The service was closed"
*>
fn Snapshot{State}*? Power.wait_after(&self, ulong seen, Duration timeout = time::FOREVER)
{
	return self.hub.state.wait_after(seen, timeout);
}

<* Call `listener` on the worker thread for the current and every later state. Quick and non-blocking only. *>
fn WatchId{State} Power.watch(
	&self,
	Listener{State} listener,
	void* context
) => self.hub.state.watch(listener, context);

<* Remove a listener; when this returns it is not running. Not from inside a listener. *>
fn void Power.unwatch(&self, WatchId{State} id) => self.hub.state.unwatch(id);

<* Subscribe to transient events (lid, external power, sleep and resume). *>
fn Reader{Event}*? Power.subscribe(&self) => self.hub.events.subscribe();

<*
 Select a profile. The operation's value is the profile the daemon accepted.

 @return? error::UNSUPPORTED : "This mechanism has no power profiles"
 @return? error::UNAVAILABLE : "The profile daemon is not running"
 @return? error::INVALID_ARGUMENT : "UNKNOWN is not a profile"
 @return? error::BUSY : "The worker's queue is full"
*>
fn ProfileOperation*? Power.set_profile(&self, Profile profile)
{
	if (profile == UNKNOWN)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "UNKNOWN is not a profile")~;
	}
	check_capability(self, PROFILE_SET)!;
	ProfileOperation* operation = operation::begin{Profile}(self.allocator);
	Command command = { .kind = SET_PROFILE, .profile = profile, .profile_op = operation };
	if (catch err = post_retained{Profile}(self, command, operation))
	{
		operation.release();
		return err~;
	}
	return operation;
}

<*
 Hold a profile (power-saver or performance) until the returned hold is released
 or this process's bus connection goes away.

 @param reason : "Text the daemon shows, for example \"video playback\""
 @return? error::UNSUPPORTED : "This mechanism cannot hold profiles, or the daemon is too old to offer it"
 @return? error::INVALID_ARGUMENT : "Only power-saver and performance can be held"
 @return? error::BUSY : "The worker's queue is full"
*>
fn HoldOperation*? Power.hold_profile(&self, Profile profile, String reason)
{
	if (profile != POWER_SAVER && profile != PERFORMANCE)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "only power-saver and performance can be held")~;
	}
	check_capability(self, PROFILE_HOLD)!;
	HoldOperation* operation = operation::begin{ProfileHold}(self.allocator);
	Command command = {
		.kind = HOLD_PROFILE,
		.profile = profile,
		.why = copy_into(reason, operation.allocator()),
		.owner = self,
		.hold_op = operation,
	};
	if (catch err = post_retained{ProfileHold}(self, command, operation))
	{
		operation.release();
		return err~;
	}
	return operation;
}

<*
 Keep the machine from doing what `kind` forbids, until the returned inhibitor
 is released or this process's bus connection goes away.

 @param who : "The application's name, shown in the system's inhibitor list"
 @param why : "Why it is needed, shown to the user"
 @return? error::UNSUPPORTED : "This mechanism cannot provide `kind`"
 @return? error::PERMISSION_DENIED : "The system refused the inhibitor"
 @return? error::BUSY : "The worker's queue is full"
*>
fn InhibitOperation*? Power.inhibit(&self, InhibitKind kind, String who, String why)
{
	if (who.len == 0)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "an inhibitor needs a name")~;
	}
	check_capability(self, inhibit_cap(kind))!;
	InhibitOperation* operation = operation::begin{Inhibitor}(self.allocator);
	Command command = {
		.kind = INHIBIT,
		.inhibit = kind,
		.who = copy_into(who, operation.allocator()),
		.why = copy_into(why, operation.allocator()),
		.owner = self,
		.inhibit_op = operation,
	};
	if (catch err = post_retained{Inhibitor}(self, command, operation))
	{
		operation.release();
		return err~;
	}
	return operation;
}

<*
 Ask whether `action` can be performed now, by this user, without an
 interactive challenge. The operation's value says so, with the reason when not.

 @return? error::BUSY : "The worker's queue is full"
*>
fn AvailabilityOperation*? Power.can(&self, Action action)
{
	AvailabilityOperation* operation = operation::begin{Availability}(self.allocator);
	Command command = { .kind = CAN, .action = action, .can_op = operation };
	if (catch err = post_retained{Availability}(self, command, operation))
	{
		operation.release();
		return err~;
	}
	return operation;
}

<*
 Perform `action`. The operation succeeds once the system has accepted it; the
 state change arrives later through `latest()` and `subscribe()`. Where the
 system asks the user to authenticate, it does so through its own dialog.

 @return? error::UNSUPPORTED : "This mechanism cannot perform the action"
 @return? error::UNAVAILABLE : "The action is blocked right now"
 @return? error::PERMISSION_DENIED : "The system refused the action for this user"
 @return? error::AUTH_REQUIRED : "The system needs the user to authenticate, and did not get it"
 @return? error::BUSY : "The worker's queue is full"
*>
fn ActionOperation*? Power.perform(&self, Action action)
{
	check_capability(self, action_cap(action))!;
	ActionOperation* operation = operation::begin{Action}(self.allocator);
	Command command = { .kind = PERFORM, .action = action, .action_op = operation };
	if (catch err = post_retained{Action}(self, command, operation))
	{
		operation.release();
		return err~;
	}
	return operation;
}

<*
 Acknowledge a `PREPARE_SLEEP` barrier, so the machine may sleep. Tickets that
 are no longer waited for (the OS went ahead on its own timeout) are ignored.

 @return? error::BUSY : "The worker's queue is full"
*>
fn void? Power.ack(&self, uint ticket) => self.hub.post({ .kind = ACK_SLEEP, .number = ticket });

<* Release the profile hold. The release is queued; a hold that the daemon no longer knows is already gone. *>
fn void? ProfileHold.release(&self) => self.owner.hub.post({ .kind = RELEASE_PROFILE, .number = self.cookie, .owner = self.owner });

<* Release the inhibitor. The release is queued and cannot fail: closing the descriptor is what releases it. *>
fn void? Inhibitor.release(&self) => self.owner.hub.post({ .kind = RELEASE_INHIBITOR, .number = self.id, .owner = self.owner });

<*
 Complete `operation` with `result` (a value, or the fault that ended the
 request) and drop the worker's reference to it. Called by the worker only.
*>
fn void finish{T}(Operation{T}* operation, T? result)
{
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

<*
 End `operation` with `failure` and drop the worker's reference to it. Called by
 the worker when a request cannot be carried out at all.
*>
fn void abort{T}(Operation{T}* operation, fault failure)
{
	operation.fail(failure);
	operation.release();
}

<*
 End the request in `command` with `failure`, if it has an operation. Commands
 that carry no operation (releases, acknowledgements) have nothing to report to.
*>
fn void abort_command(Command* command, fault failure)
{
	switch (command.kind)
	{
		case SET_PROFILE: abort{Profile}(command.profile_op, failure);
		case HOLD_PROFILE: abort{ProfileHold}(command.hold_op, failure);
		case INHIBIT: abort{Inhibitor}(command.inhibit_op, failure);
		case CAN: abort{Availability}(command.can_op, failure);
		case PERFORM: abort{Action}(command.action_op, failure);
		case RELEASE_PROFILE:
		case RELEASE_INHIBITOR:
		case ACK_SLEEP: return;
	}
}

// Give the worker its own reference, then queue the command. On failure the
// worker's reference is dropped again; the caller still holds its own.
fn void? post_retained{T}(Power* self, Command command, Operation{T}* operation) @private
{
	operation.retain();
	if (catch err = self.hub.post(command))
	{
		operation.release();
		return err~;
	}
}

// Refuse a request the mechanism cannot serve, before any work is queued.
fn void? check_capability(Power* self, Cap cap) @private
{
	Availability availability = self.capabilities.get(cap);
	if (availability.ok()) return;
	return error::raise(availability.refusal(), error::Domain.INTERNAL, 0, "%s", availability.note)~;
}

// A copy in the operation's arena, so the worker can read it while the operation lives.
fn String copy_into(String text, Allocator allocator) @private
{
	if (text.len == 0) return "";
	return text.copy(allocator);
}
