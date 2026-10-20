<*
 The global-shortcuts service: open it, register shortcuts, read the state, follow presses.

 Hotkey* hotkeys = hotkey::open(mem)!;
 defer hotkeys.close();
 Task* task = hotkeys.register("toggle-bar", "Show or hide the bar", chord)!;
 defer task.release();
 Binding binding = task.wait(time::ms(30000))!;   // BOUND, CONFLICT, or REFUSED
 Reader{Event}* presses = hotkeys.subscribe()!;

 Every method may be called from any thread.
*>
module bleu::hotkey;
import std::collections::enummap, std::time, bleu::error, bleu::availability, bleu::observe, bleu::operation, bleu::stream, bleu::service;

alias Capabilities = EnumMap{Cap, Availability};

<*
 An open shortcut service: one backend, one worker thread, one state.
*>
struct Hotkey
{
	Allocator allocator;
	HotkeyHub hub;
	Driver* driver;
	void* driver_state;
	Capabilities capabilities;
}

<*
 Open the first working backend of this platform (or the one in `options`).

 @param allocator : "Allocator for the service and its snapshots"
 @return? error::UNAVAILABLE : "No backend works here (no global-shortcut mechanism is running)"
 @return? error::UNSUPPORTED : "The requested backend does not exist on this platform"
*>
fn Hotkey*? open(Allocator allocator, Options options = { })
{
	Driver* driver = select_driver(options)!;
	Hotkey* self   = alloc::new(allocator, Hotkey);
	self.allocator = allocator;
	self.driver = driver;
	self.driver_state = driver.create(allocator, options, &self.capabilities)!;
	if (catch err = self.hub.start(allocator, "hotkey", driver.info.name, driver.run, self.driver_state))
	{
		driver.destroy(allocator, self.driver_state);
		alloc::free(allocator, self);
		return err~;
	}
	return self;
}

<* Stop the backend, unbind what it bound, and release everything. *>
fn void Hotkey.close(&self)
{
	self.hub.stop();
	self.hub.free();
	self.driver.destroy(self.allocator, self.driver_state);
	Allocator allocator = self.allocator;
	alloc::free(allocator, self);
}

<* Name of the backend in use, for diagnostics ("portal", "carbon", "win32"). *>
fn String Hotkey.backend_name(&self) => self.hub.backend_name;

<* Whether `cap` works with this backend, and if not, why. *>
fn Availability Hotkey.capability(&self, Cap cap) => self.capabilities.values[cap.ordinal];

<*
 The newest state, retained for the caller (call `release()` on it).

 @return? error::UNAVAILABLE : "The backend has not produced its first state yet"
*>
fn Snapshot{State}*? Hotkey.latest(&self) => self.hub.latest();

<*
 Block until a state newer than `seen` exists. Start with `seen = 0`, then pass the previous
 snapshot's `generation`.

 @return? TIMEOUT : "Nothing changed in time"
 @return? error::DISCONNECTED : "The service was closed"
*>
fn Snapshot{State}*? Hotkey.wait_after(&self, ulong seen, Duration timeout = time::FOREVER)
{
	return self.hub.state.wait_after(seen, timeout);
}

<* Call `listener` on the worker thread for the current and every later state. Quick and non-blocking only. *>
fn WatchId{State} Hotkey.watch(
	&self,
	Listener{State} listener,
	void* context
) => self.hub.state.watch(listener, context);

<* Remove a listener; when this returns it is not running. Not from inside a listener. *>
fn void? Hotkey.unwatch(&self, WatchId{State} id) => self.hub.state.unwatch(id);

<*
 Subscribe to presses and releases. Only events after this call are delivered. Release the reader
 when done.

 @return? error::DISCONNECTED : "The service was closed"
*>
fn Reader{Event}*? Hotkey.subscribe(&self) => self.hub.events.subscribe();

<*
 Register `chord` under `id`. The operation finishes with the binding as the platform left it.
 A platform that asks the user (the portal) may take a long time, so wait with a timeout.

 @param id : "Stable name of the shortcut, for example \"toggle-bar\"; not empty"
 @param description : "Text a settings UI shows for the shortcut"
 @return? error::INVALID_ARGUMENT : "The id is empty"
 @return? error::UNSUPPORTED : "This backend cannot bind shortcuts (see `Cap.REGISTER`)"
 @return? error::UNAVAILABLE : "The backend is absent or stopped (see `Cap.REGISTER`)"
*>
fn Task*? Hotkey.register(&self, String id, String description, Chord chord)
{
	if (id.len == 0) return error::INVALID_ARGUMENT~;
	ensure_available(self, REGISTER)!;
	return submit(self, { .kind = REGISTER, .chord = chord }, id, description);
}

<*
 Remove the shortcut `id`. Its operation finishes with the binding that was removed, or fails with
 NOT_FOUND when no shortcut has that id.

 @param id : "The id given to `register`"
 @return? error::INVALID_ARGUMENT : "The id is empty"
 @return? error::UNSUPPORTED : "This backend cannot remove shortcuts (see `Cap.UNREGISTER`)"
 @return? error::UNAVAILABLE : "The backend is absent or stopped (see `Cap.UNREGISTER`)"
*>
fn Task*? Hotkey.unregister(&self, String id)
{
	if (id.len == 0) return error::INVALID_ARGUMENT~;
	ensure_available(self, UNREGISTER)!;
	return submit(self, { .kind = UNREGISTER }, id, "");
}

// Refuse a request the backend's capability table says it cannot serve.
fn void? ensure_available(Hotkey* self, Cap cap) @private
{
	Availability availability = self.capabilities.values[cap.ordinal];
	if (!availability.ok()) return availability.refusal()~;
}

// Queue `command` with its strings copied into a new operation's arena; the worker completes the operation.
fn Task*? submit(Hotkey* self, Command command, String id, String description) @private
{
	Task* task      = operation::begin{Binding}(self.allocator);
	Allocator arena = task.allocator();
	command.id = copy_text(id, arena);
	command.description = copy_text(description, arena);
	command.operation = task.retain();
	if (catch err = self.hub.post(command))
	{
		task.release();
		task.release();
		return err~;
	}
	return task;
}

// A copy of `text` in `allocator`; the empty string needs no storage, and a zero-length copy is not made.
fn String copy_text(String text, Allocator allocator) @private
{
	if (text.len == 0) return "";
	return text.copy(allocator);
}