<*
 The Bluetooth service: open it, read `latest()`, wait for changes, and ask it
 to do things.

 Bluetooth* bt = bluetooth::open(mem)!;
 defer bt.close();
 Snapshot{State}* snapshot = bt.wait_after(0, time::sec(5))!;
 defer snapshot.release();
 Task* task = bt.set_powered(adapter_address, true)!;
 defer task.release();
 task.wait(time::sec(10))!;

 Reading is always cheap: `latest` and `wait_after` return the last published
 state. Asking is an `Operation` (`Task`): it is accepted at once, completes
 later on the worker, and the world's change arrives through the state, not
 through the operation alone. The caller releases each `Task` when done.

 Every method may be called from any thread.
*>
module bleu::bluetooth;
import std::collections::enummap, std::time, bleu::error, bleu::availability, bleu::observe, bleu::operation,
	bleu::stream, bleu::service;

<* The result of a request that can fail or take time. *>
alias Task = Operation{Done};
alias BluetoothHub = Hub{State, Request, Event};
alias Capabilities = EnumMap{Cap, Availability};

<* A Bluetooth service instance: one backend, one worker thread, one state. *>
struct Bluetooth
{
	Allocator allocator;
	BluetoothHub hub;
	Driver* driver;
	void* driver_state;
	Capabilities capabilities;
}

<*
 Open the first working backend of this platform, or the one in `options`.

 @param allocator : "Allocator for the service, its snapshots and its tasks"
 @return? error::UNAVAILABLE : "No backend works here (no Bluetooth service is running)"
 @return? error::UNSUPPORTED : "The requested backend does not exist on this platform"
*>
fn Bluetooth*? open(Allocator allocator, Options options = { })
{
	Driver* driver = select_driver(options)!;
	Bluetooth* self = alloc::new(allocator, Bluetooth);
	self.allocator = allocator;
	self.driver = driver;
	void*? state = driver.create(allocator, options, &self.capabilities);
	if (catch err = state)
	{
		alloc::free(allocator, self);
		return err~;
	}
	self.driver_state = state!!;
	if (catch err = self.hub.start(allocator, "bluetooth", driver.info.name, driver.run, self.driver_state))
	{
		driver.destroy(allocator, self.driver_state);
		alloc::free(allocator, self);
		return err~;
	}
	return self;
}

<* Stop the backend, finish or cancel what is queued, and release everything. *>
fn void Bluetooth.close(&self)
{
	self.hub.stop();
	self.driver.destroy(self.allocator, self.driver_state);
	Allocator allocator = self.allocator;
	alloc::free(allocator, self);
}

<* Name of the backend in use, for diagnostics ("bluez", "iobluetooth", "win32"). *>
fn String Bluetooth.backend_name(&self) => self.hub.backend_name;

<* Whether `cap` works with this backend, and if not, why. *>
fn Availability Bluetooth.capability(&self, Cap cap) => self.capabilities.values[cap.ordinal];

<*
 The newest state, retained for the caller (call `release()` on it).

 @return? error::UNAVAILABLE : "The backend has not produced its first state yet"
*>
fn Snapshot{State}*? Bluetooth.latest(&self) => self.hub.latest();

<*
 Block until a state newer than `seen` exists. Start with `seen = 0`, then
 pass the previous snapshot's `generation`.

 @return? TIMEOUT : "Nothing changed in time"
 @return? error::DISCONNECTED : "The service was closed"
*>
fn Snapshot{State}*? Bluetooth.wait_after(&self, ulong seen, Duration timeout = time::FOREVER)
{
	return self.hub.state.wait_after(seen, timeout);
}

<* Call `listener` on the worker thread for the current and every later state. Quick and non-blocking only. *>
fn WatchId{State} Bluetooth.watch(&self, Listener{State} listener, void* context) => self.hub.state.watch(listener, context);

<* Remove a listener; when this returns it is not running. Not from inside a listener. *>
fn void Bluetooth.unwatch(&self, WatchId{State} id) => self.hub.state.unwatch(id);

<*
 Subscribe to transient events: adapters and devices added, changed or removed,
 disconnections, and pairing prompts. Release the reader when done.

 @return? error::DISCONNECTED : "The service was closed"
*>
fn Reader{Event}*? Bluetooth.subscribe(&self) => self.hub.events.subscribe();

<*
 Ask for a fresh read of the hardware now, instead of waiting for the next change.
*>
fn Task*? Bluetooth.refresh(&self) => submit(self, { .kind = REFRESH });

<*
 Switch a controller on or off. An adapter with `blocked` set cannot be turned
 on; the kill switch has to be released by the user.

 @param adapter : "Controller address; \"\" for the first controller"
 @return? error::UNSUPPORTED : "This backend cannot switch controllers"
 @return? error::PERMISSION_DENIED : "The platform does not allow this without consent"
*>
fn Task*? Bluetooth.set_powered(&self, String adapter, bool on)
{
	ensure_available(self, POWER)!;
	return submit(self, { .kind = SET_POWERED, .adapter = adapter, .flag = on });
}

<*
 Make a controller visible to other devices, for `timeout_seconds` (0 means
 until switched off again).

 @param adapter : "Controller address; \"\" for the first controller"
 @return? error::UNSUPPORTED : "This backend cannot change discoverability"
*>
fn Task*? Bluetooth.set_discoverable(&self, String adapter, bool on, uint timeout_seconds = 0)
{
	ensure_available(self, DISCOVERABLE)!;
	return submit(self, { .kind = SET_DISCOVERABLE, .adapter = adapter, .flag = on, .number = timeout_seconds });
}

<*
 Let other devices pair with a controller, or refuse them.

 @param adapter : "Controller address; \"\" for the first controller"
 @return? error::UNSUPPORTED : "This backend cannot change pairability"
*>
fn Task*? Bluetooth.set_pairable(&self, String adapter, bool on)
{
	ensure_available(self, PAIRABLE)!;
	return submit(self, { .kind = SET_PAIRABLE, .adapter = adapter, .flag = on });
}

<*
 Start scanning for nearby devices. Each call is one scan; devices appear in
 the state as they are found.

 @param adapter : "Controller address; \"\" for the first controller"
 @return? error::UNSUPPORTED : "This backend cannot scan"
*>
fn Task*? Bluetooth.start_discovery(&self, String adapter, DiscoveryFilter filter = { })
{
	ensure_available(self, DISCOVERY)!;
	return submit(self, { .kind = START_DISCOVERY, .adapter = adapter, .filter = filter });
}

<* Stop the scan started by `start_discovery`. *>
fn Task*? Bluetooth.stop_discovery(&self, String adapter)
{
	ensure_available(self, DISCOVERY)!;
	return submit(self, { .kind = STOP_DISCOVERY, .adapter = adapter });
}

<*
 Pair with a device. Prompts the device needs answered arrive as
 `PAIRING_REQUEST` events, and are answered with `reply_pairing`.

 @param device : "Device address"
 @return? error::UNSUPPORTED : "This backend cannot pair"
*>
fn Task*? Bluetooth.pair(&self, String device)
{
	ensure_available(self, PAIR)!;
	return submit(self, { .kind = PAIR, .device = device });
}

<* Stop a pairing that is in progress with `device`; the pending `pair` task fails as cancelled. *>
fn Task*? Bluetooth.cancel_pairing(&self, String device)
{
	ensure_available(self, CANCEL_PAIRING)!;
	return submit(self, { .kind = CANCEL_PAIRING, .device = device });
}

<*
 Answer a pairing prompt. `accept` says whether the user agreed; `secret` is the
 PIN the user typed or the passkey as decimal digits, and is ignored when it is
 not needed. A PIN is never supplied by the library: it comes from the user only.

 @param request_id : "The `PairingRequest.id` of the prompt"
 @return? error::UNSUPPORTED : "This backend does not ask for pairing prompts"
 @return? error::INVALID_STATE : "No prompt with this id is waiting"
*>
fn Task*? Bluetooth.reply_pairing(&self, ulong request_id, bool accept, String secret = "")
{
	ensure_available(self, PAIRING_PROMPTS)!;
	return submit(self, { .kind = REPLY_PAIRING, .ticket = request_id, .flag = accept, .text = secret });
}

<* Connect every profile of a device that connects on its own. *>
fn Task*? Bluetooth.connect(&self, String device)
{
	ensure_available(self, CONNECT)!;
	return submit(self, { .kind = CONNECT, .device = device });
}

<* Disconnect a device. A device that is not connected counts as disconnected. *>
fn Task*? Bluetooth.disconnect(&self, String device)
{
	ensure_available(self, DISCONNECT)!;
	return submit(self, { .kind = DISCONNECT, .device = device });
}

<* Connect one profile of a device, such as the headset profile of a headset. *>
fn Task*? Bluetooth.connect_profile(&self, String device, Profile profile)
{
	ensure_available(self, PROFILE_CONNECT)!;
	return submit(self, { .kind = CONNECT_PROFILE, .device = device, .profile = profile });
}

<* Disconnect one profile of a device. *>
fn Task*? Bluetooth.disconnect_profile(&self, String device, Profile profile)
{
	ensure_available(self, PROFILE_DISCONNECT)!;
	return submit(self, { .kind = DISCONNECT_PROFILE, .device = device, .profile = profile });
}

<* Set whether a device may connect without asking. *>
fn Task*? Bluetooth.set_trusted(&self, String device, bool trusted)
{
	ensure_available(self, TRUST)!;
	return submit(self, { .kind = SET_TRUSTED, .device = device, .flag = trusted });
}

<* Set whether a device's connections are refused. *>
fn Task*? Bluetooth.set_blocked(&self, String device, bool blocked)
{
	ensure_available(self, BLOCK)!;
	return submit(self, { .kind = SET_BLOCKED, .device = device, .flag = blocked });
}

<*
 Change the name a device shows as. An empty name returns to the device's own name.
*>
fn Task*? Bluetooth.rename(&self, String device, String name)
{
	ensure_available(self, RENAME)!;
	return submit(self, { .kind = RENAME, .device = device, .text = name });
}

<* Forget a device: its keys and its entry are removed. *>
fn Task*? Bluetooth.remove(&self, String device)
{
	ensure_available(self, REMOVE)!;
	return submit(self, { .kind = REMOVE, .device = device });
}

// Refuses at once, with the capability's own reason, when `cap` cannot work here.
fn void? ensure_available(Bluetooth* self, Cap cap) @private
{
	Availability available = self.capabilities.values[cap.ordinal];
	if (!available.ok()) return available.refusal()~;
}

// Queue `request` for the worker. The task is created here; the worker releases the request's reference.
fn Task*? submit(Bluetooth* self, Request request) @private
{
	Task* task        = operation::begin{Done}(self.allocator);
	Allocator arena   = task.allocator();
	request.adapter   = copy_text(request.adapter, arena);
	request.device    = copy_text(request.device, arena);
	request.text      = copy_text(request.text, arena);
	request.filter.pattern = copy_text(request.filter.pattern, arena);
	request.op        = task.retain();
	if (catch err = self.hub.post(request))
	{
		task.release();
		task.release();
		return err~;
	}
	return task;
}
