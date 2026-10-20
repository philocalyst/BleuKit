<*
 The `bluetooth` module: DMS's Bluetooth methods, the state topic and the pairing prompt
 stream, over `bleu::bluetooth`.

 Methods: `bluetooth.getState`, `startDiscovery`, `stopDiscovery`, `setPowered`,
 `togglePowered`, `pair`, `connect`, `disconnect`, `remove`, `trust`, `untrust`,
 `pairing.submit`, `pairing.cancel`. `mpris.publish` and the streaming `subscribe` answer
 `not supported: ...`. Topics: `bluetooth` (the `BluetoothState`, retained) and
 `bluetooth.pairing` (one `PairingPrompt` per prompt, not retained).

 Source of every shape and rule: `core/internal/server/bluez/` (types.go, handlers.go,
 manager.go, agent.go, broker.go, subscription_broker.go) and `server.go` (the
 subscriptions, :651-680) at DMS master 8be08999. The shapes are in `bluetooth_wire.c3`.
 Deviations are listed in docs/DMSD.md.

 Design points:
 * A request whose result takes time (pair, connect, ...) is answered when its
 `bleu::bluetooth` operation completes, through `Operation.then` and a `Deferred`
 reply. No handler thread waits, so a `pairing.submit` is served while a `pair` is
 still waiting for the user, as DMS serves it (the Go handlers run concurrently).
 * The prompts are kept in a small table, so a token names the kind of prompt it
 answers (PIN, passkey or decision) and an unknown token is refused the way DMS
 refuses it (broker.go Resolve).
*>
module dmsd::bluetooth_mod;
import std::atomic, std::collections::object, std::os::env, std::thread, std::time, bleu::bluetooth, bleu::error, bleu::ipc, bleu::json, bleu::observe, bleu::stream, bleu::rt::foreign, dmsd::contract, dmsd::wire, dmsd::params, dmsd::bluetooth_wire;

const String[2] TOPICS       = { "bluetooth", "bluetooth.pairing" };
const String[1] CAPABILITIES = { "bluetooth" };

// How often the events thread checks for its stop request while no event arrives.
const Duration EVENT_POLL            = (Duration)200_000;
// How many prompts may wait for an answer at once. Bleu's pairing agent refuses more (bluez_agent.c3 MAX_PROMPTS).
const usz MAX_PROMPTS                = 8;
// The longest decimal token that fits an unsigned 64-bit prompt id.
const sz MAX_TOKEN_DIGITS            = 19;
// Reply when there is no state yet: DMS's zero `BluetoothState` (types.go:10-16 with empty lists).
const String EMPTY_STATE             = "{\"powered\":false,\"discovering\":false,\"adapters\":[],\"devices\":[],\"pairedDevices\":[],\"connectedDevices\":[]}";
// Reply texts of the methods Bleu cannot serve.
const String NOT_SUPPORTED_MPRIS     = "not supported: Bleu cannot export an MPRIS player to BlueZ (no AVRCP; bleu_media's publishing side is not built), so no lease is granted";
const String NOT_SUPPORTED_SUBSCRIBE = "not supported: a streaming method cannot reply in this protocol; subscribe with services [\"bluetooth\", \"bluetooth.pairing\"] instead";

<* One prompt that waits for an answer: its id, and the kind that says what the answer is. *>
struct PromptSlot
{
	bool used;
	ulong id;
	bluetooth::PromptKind kind;
}

<*
 The prompts waiting for an answer, by id. The shell names a prompt by its token, the id in decimal.
 The mutex is taken by the events thread and by the handlers.
*>
struct PromptTable
{
	Mutex mutex;
	PromptSlot[MAX_PROMPTS] slots;
}

<* Record a waiting prompt. False when every slot is taken. *>
fn bool PromptTable.add(&self, ulong id, bluetooth::PromptKind kind)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	foreach (&slot : self.slots)
	{
		if (slot.used) continue;
		slot.used = true;
		slot.id = id;
		slot.kind = kind;
		return true;
	}
	return false;
}

<* The waiting prompt with `id`, or NOT_FOUND. *>
fn PromptSlot? PromptTable.find(&self, ulong id)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	foreach (&slot : self.slots)
	{
		if (slot.used && slot.id == id) return *slot;
	}
	return NOT_FOUND~;
}

<* Forget the prompt with `id`, once it is answered or has ended. Unknown ids are ignored. *>
fn void PromptTable.forget(&self, ulong id)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	foreach (&slot : self.slots)
	{
		if (slot.used && slot.id == id) slot.used = false;
	}
}

<* The module's runtime state. Allocated in `start`, freed in `stop`. *>
struct BluetoothModule
{
	Allocator allocator;
	bluetooth::Bluetooth* service;
	contract::StatePump state_pump;
	ipc::Topic* prompt_topic;
	observe::WatchId{bluetooth::State} watch_id;
	stream::Reader{bluetooth::Event}* events;
	Thread events_thread;
	Atomic{bool} stop_events;
	PromptTable prompts;
}

<*
 What a request answers when its operation completes. `message` is the DMS success text;
 `reports_power` replaces it with `PoweredResult`; `pair_device`, when set, is a pairing that
 trusts and connects the device on success (DMS does the same once it has paired a device).
*>
struct Reply
{
	Allocator allocator;
	BluetoothModule* owner;
	ipc::Deferred deferred;
	String message;
	bool reports_power;
	bool powered;
	String pair_device;
}

// The device verbs: each one call on the device the `device` parameter names.
enum DeviceVerb : char
{
	PAIR,
	CONNECT,
	DISCONNECT,
	REMOVE,
	TRUST,
	UNTRUST,
}

<* Parse a prompt token: its decimal id. NOT_FOUND when it is not one. *>
fn ulong? parse_token(String token) @private
{
	if (token.len == 0 || token.len > MAX_TOKEN_DIGITS) return NOT_FOUND~;
	ulong value = 0;
	for (sz i = 0; i < token.len; i++)
	{
		char c = token[i];
		if (c < '0' || c > '9') return NOT_FOUND~;
		value = value * 10 + (ulong)(c - '0');
	}
	return value;
}

// The token of the prompt `id`: its decimal id, or "" for a code shown to the user (id 0), which takes no answer.
fn String token_of(ulong id) @private
{
	if (id == 0) return "";
	return string::tformat("%d", (long)id);
}

// The waiting prompt a token names, or INVALID_STATE with DMS's text.
fn PromptSlot? find_prompt(BluetoothModule* m, String token) @private
{
	if (try id = parse_token(token))
	{
		if (try slot = m.prompts.find(id)) return slot;
	}
	return error::raise(error::INVALID_STATE, error::Domain.INTERNAL, 0, "unknown or expired token: %s", token)~;
}

// A string parameter that is optional: "" when it is absent or not a string (dankgo's StringOpt).
fn String opt_string(Object* params, String key) @private
{
	if (try value = json::read::get_string(params, key)) return value;
	return "";
}

// A `secrets` entry of a pairing answer: "" when absent (dankgo's StringMapOpt).
fn String secret_of(Object* params, String key) @private
{
	if (try secrets = json::read::get_object(params, "secrets"))
	{
		if (try value = json::read::get_string(secrets, key)) return value;
	}
	return "";
}

// The device a request names: a BlueZ object path (what DMS takes), or an address. The path's device address is read from it.
fn String? device_address_param(Object* params) @private
{
	String device = params::param_string(params, "device")!;
	if (!device.starts_with("/")) return device;
	if (try address = bluetooth::address_of_device_path(device, tmem)) return address;
	return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "invalid device path: %s", device)~;
}

// The adapter a request names: the one with that address, or the first controller when `address` is "" (DMS resolveAdapter).
fn bluetooth::Adapter*? find_adapter(bluetooth::State* state, String address) @private
{
	if (state.adapters.len == 0) return error::raise(
		error::UNAVAILABLE,
		error::Domain.INTERNAL,
		0,
		"no bluetooth adapter found"
	)~;
	foreach (&adapter : state.adapters)
	{
		if (address.len == 0 || adapter.address == address) return adapter;
	}
	return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "unknown adapter: %s", address)~;
}

// The power state a toggle asks for: the opposite of the adapter's live state (manager.go TogglePowered).
fn bool? power_target(BluetoothModule* m, String address) @private
{
	observe::Snapshot{bluetooth::State}* snapshot = m.service.latest()!;
	defer snapshot.release();
	bluetooth::Adapter* adapter = find_adapter(&snapshot.value, address)!;
	if (!adapter.powered.has_value)
	{
		return error::raise(
			error::UNAVAILABLE,
			error::Domain.INTERNAL,
			0,
			"the power state of the adapter is not known"
		)~;
	}
	return !adapter.powered.value;
}

// The text of a failed operation: what the worker recorded, else a plain fallback.
fn String operation_text(bluetooth::Task* task) @private
{
	error::Detail* detail = task.detail();
	return detail.len > 0 ? detail.message() : "the request failed";
}

// The success line of a reply, in temporary memory.
fn String? success_line(Reply* reply) @private
{
	if (reply.reports_power) return bluetooth_wire::powered_result(tmem, reply.powered);
	return wire::success_result(tmem, reply.message);
}

// DMS trusts and connects a device it has just paired (manager.go handleDevicePropertiesChanged). Best effort, as there.
fn void auto_trust_and_connect(BluetoothModule* m, String device) @private
{
	if (try trust = m.service.set_trusted(device, true))
	{
		trust.release();
	}
	else
	{
		contract::note(
			"bluetooth: %s not trusted after pairing: %s",
			device,
			contract::failure_text("no reason given")
		);
	}
	if (try connect = m.service.connect(device))
	{
		connect.release();
	}
	else
	{
		contract::note(
			"bluetooth: %s not connected after pairing: %s",
			device,
			contract::failure_text("no reason given")
		);
	}
}

// Completion of a request's operation, on the thread that completed it: answer the client once, then drop the request.
fn void on_done(void* context, bluetooth::Task* task)
{
	Reply* reply = (Reply*)context;
	@pool()
	{
		if (catch task.wait(time::DURATION_ZERO))
		{
			reply.deferred.respond_error(operation_text(task));
		}
		else
		{
			if (try line = success_line(reply))
			{
				reply.deferred.respond_raw(line);
			}
			else
			{
				reply.deferred.respond_error(contract::failure_text("cannot render the reply"));
			}
			if (reply.pair_device.len > 0) auto_trust_and_connect(reply.owner, reply.pair_device);
		}
	};
	if (reply.pair_device.len > 0) alloc::free(reply.allocator, reply.pair_device.ptr);
	alloc::free(reply.allocator, reply);
}

<*
 Answer `call` when `task` completes. The request stays open until then, so no handler
 thread is held. Must be called on the handler thread, and nothing may touch `call` afterwards.
*>
fn void? BluetoothModule.answer_when_done(&self, ipc::Call* call, bluetooth::Task* task, Reply draft)
{
	Reply* reply = alloc::new(self.allocator, Reply);
	*reply = draft;
	reply.allocator = self.allocator;
	reply.owner = self;
	reply.deferred = call.defer_reply();
	reply.pair_device = draft.pair_device.len > 0 ? draft.pair_device.copy(self.allocator) : "";
	task.then(&on_done, (void*)reply)!!;
	// The operation keeps its own reference until the worker completes it, so the completion runs.
	task.release();
}

// The `bluetooth.getState` reply: the newest state, or DMS's zero state when none exists yet.
fn String BluetoothModule.reply_state(&self, Allocator allocator)
{
	if (try snapshot = self.service.latest())
	{
		defer snapshot.release();
		if (try line = bluetooth_wire::render_state(allocator, &snapshot.value)) return line;
	}
	return EMPTY_STATE;
}

// Run one device verb on the device named by the `device` parameter.
fn void? device_verb(BluetoothModule* m, ipc::Call* call, DeviceVerb verb) @private
{
	String device         = device_address_param(call.params)!;
	bluetooth::Task* task = null;
	switch (verb)
	{
		case DeviceVerb.PAIR: task = m.service.pair(device)!;
		case DeviceVerb.CONNECT: task = m.service.connect(device)!;
		case DeviceVerb.DISCONNECT: task = m.service.disconnect(device)!;
		case DeviceVerb.REMOVE: task = m.service.remove(device)!;
		case DeviceVerb.TRUST: task = m.service.set_trusted(device, true)!;
		case DeviceVerb.UNTRUST: task = m.service.set_trusted(device, false)!;
	}
	String message = verb_message(verb);
	Reply draft    = { .message = message, .pair_device = verb == DeviceVerb.PAIR ? device : "" };
	m.answer_when_done(call, task, draft)!;
}

// The DMS success text of each device verb (handlers.go).
fn String verb_message(DeviceVerb verb) @private
{
	switch (verb)
	{
		case DeviceVerb.PAIR: return "pairing initiated";
		case DeviceVerb.CONNECT: return "connecting";
		case DeviceVerb.DISCONNECT: return "disconnected";
		case DeviceVerb.REMOVE: return "device removed";
		case DeviceVerb.TRUST: return "device trusted";
		case DeviceVerb.UNTRUST: return "device untrusted";
	}
}

// `startDiscovery` and `stopDiscovery` {adapter}.
fn void? discovery(BluetoothModule* m, ipc::Call* call, bool scanning) @private
{
	String adapter        = opt_string(call.params, "adapter");
	bluetooth::Task* task = null;
	if (scanning)
	{
		task = m.service.start_discovery(adapter)!;
	}
	else
	{
		task = m.service.stop_discovery(adapter)!;
	}
	Reply draft = { .message = scanning ? "discovery started" : "discovery stopped" };
	m.answer_when_done(call, task, draft)!;
}

// `setPowered` {powered, adapter}: the power state the adapter is asked for.
fn void? set_power(BluetoothModule* m, ipc::Call* call) @private
{
	bool powered          = params::param_bool(call.params, "powered")!;
	String adapter        = opt_string(call.params, "adapter");
	bluetooth::Task* task = m.service.set_powered(adapter, powered)!;
	Reply draft           = { .message = "powered state updated" };
	m.answer_when_done(call, task, draft)!;
}

// `togglePowered` {adapter}: the opposite of the live state, reported as `PoweredResult`.
fn void? toggle_power(BluetoothModule* m, ipc::Call* call) @private
{
	String adapter        = opt_string(call.params, "adapter");
	bool target           = power_target(m, adapter)!;
	bluetooth::Task* task = m.service.set_powered(adapter, target)!;
	Reply draft           = { .reports_power = true, .powered = target };
	m.answer_when_done(call, task, draft)!;
}

// `pairing.submit` {token, secrets, accept}: answer the prompt as the shell's answer says (DMS: SubmitPairing).
fn void? submit_pairing(BluetoothModule* m, ipc::Call* call) @private
{
	String token    = params::param_string(call.params, "token")!;
	bool accept     = params::opt_bool(call.params, "accept", false);
	PromptSlot slot = find_prompt(m, token)!;
	String secret   = "";
	bool approved   = accept;
	switch (slot.kind)
	{
		case bluetooth::PromptKind.PIN:
			secret = secret_of(call.params, "pin");
		case bluetooth::PromptKind.PASSKEY_ENTRY:
			secret = secret_of(call.params, "passkey");
		case bluetooth::PromptKind.CONFIRM:
			approved = accept && decided(call.params);
		case bluetooth::PromptKind.AUTHORIZE:
			approved = accept && decided(call.params);
		case bluetooth::PromptKind.PASSKEY_DISPLAY:
			// A displayed code is never stored (its id is 0), so no token can name one.
			return error::raise(
				error::INVALID_STATE,
				error::Domain.INTERNAL,
				0,
				"unknown or expired token: %s",
				token
			)~;
	}
	bluetooth::Task* answer = m.service.reply_pairing(slot.id, approved, secret)!;
	m.prompts.forget(slot.id);
	Reply draft = { .message = "pairing response submitted" };
	m.answer_when_done(call, answer, draft)!;
}

// A confirmation or authorisation is given when `secrets.decision` says yes or accept (agent.go RequestConfirmation).
fn bool decided(Object* params) @private
{
	String decision = secret_of(params, "decision");
	return decision == "yes" || decision == "accept";
}

// `pairing.cancel` {token}: refuse the prompt. Bleu's agent answers BlueZ with Rejected, where DMS sends Canceled.
fn void? cancel_pairing(BluetoothModule* m, ipc::Call* call) @private
{
	String token            = params::param_string(call.params, "token")!;
	PromptSlot slot         = find_prompt(m, token)!;
	bluetooth::Task* answer = m.service.reply_pairing(slot.id, false)!;
	m.prompts.forget(slot.id);
	Reply draft = { .message = "pairing cancelled" };
	m.answer_when_done(call, answer, draft)!;
}

// Publish a prompt to the `bluetooth.pairing` stream, and keep it answerable if it has an id.
fn void BluetoothModule.publish_prompt(&self, bluetooth::Event* event)
{
	ulong id = event.request.id;
	if (id != 0 && !self.prompts.add(id, event.request.kind))
	{
		contract::warn("bluetooth: more prompts wait than the table holds; prompt %d cannot be answered", (long)id);
	}
	@pool()
	{
		String token = token_of(id);
		if (try snapshot = self.service.latest())
		{
			defer snapshot.release();
			publish_rendered(self, token, event, &snapshot.value);
		}
		else
		{
			bluetooth::State none;
			publish_rendered(self, token, event, &none);
		}
	};
}

// Render one prompt against `state` and send it (nobody listening is not an error).
fn void publish_rendered(BluetoothModule* m, String token, bluetooth::Event* event, bluetooth::State* state) @private
{
	if (try line = bluetooth_wire::render_prompt(tmem, token, event, state))
	{
		if (catch m.prompt_topic.publish_event(line)) contract::note("bluetooth.pairing: not sent");
	}
	else
	{
		contract::note("bluetooth.pairing: prompt not rendered");
	}
}

// Handle one event from the service: a prompt is published, and a prompt that ended is forgotten.
fn void BluetoothModule.handle_event(&self, bluetooth::Event* event)
{
	if (event.kind == bluetooth::EventKind.PAIRING_REQUEST) self.publish_prompt(event);
	if (event.kind == bluetooth::EventKind.PAIRING_ENDED) self.prompts.forget(event.request.id);
}

// The events thread's loop: read events until stopped. A timeout is normal; a closed stream ends the loop.
fn void BluetoothModule.run_events(&self)
{
	while (!self.stop_events.load())
	{
		stream::Packet{bluetooth::Event}*? next = self.events.next(EVENT_POLL);
		if (try packet = next)
		{
			defer packet.release();
			self.handle_event(&packet.value);
			continue;
		}
		if (catch err = next)
		{
			if (err != TIMEOUT)
			{
				contract::warn("bluetooth: events stopped; no pairing prompts are published");
				return;
			}
		}
	}
}

// The events thread's entry point. The temporary allocator is set up first (see bleu::rt::foreign).
fn int events_main(void* arg) @private
{
	BluetoothModule* m = (BluetoothModule*)arg;
	foreign::@foreign_entry()
	{
		m.run_events();
	};
	return 0;
}

// Encodes the newest state for the `bluetooth` topic.
fn String? encode_state(void* context, Allocator allocator)
{
	BluetoothModule* m                            = (BluetoothModule*)context;
	observe::Snapshot{bluetooth::State}* snapshot = m.service.latest()!;
	defer snapshot.release();
	return bluetooth_wire::render_state(allocator, &snapshot.value);
}

// Listener: runs on the service's thread. It only marks the pump dirty.
fn void on_state(void* context, observe::Snapshot{bluetooth::State}* snapshot)
{
	contract::StatePump* pump = (contract::StatePump*)context;
	pump.notify();
}

// The system bus address: DBUS_SYSTEM_BUS_ADDRESS when it is set, else the default system bus.
fn String system_bus_address() @private
{
	if (try address = env::tget_var("DBUS_SYSTEM_BUS_ADDRESS")) return address;
	return "";
}

// Open the Bluetooth service. Null when no backend works here: the reason is printed.
fn bluetooth::Bluetooth* open_service(contract::Context* context) @private
{
	bluetooth::Bluetooth* service = null;
	@pool()
	{
		// DMS's bluetooth module is BlueZ's (bluez/): the other backends are not used, as their capabilities are partial.
		bluetooth::Options options = {
			.backend = bluetooth::Backend.BLUEZ,
			.bus_address = system_bus_address(),
			.root = context.options.fake_root,
		};
		if (try opened = bluetooth::open(context.allocator, options))
		{
			service = opened;
		}
		else
		{
			contract::warn(
				"bluetooth: not started: %s",
				contract::failure_text("no Bluetooth service (org.bluez on the system bus)")
			);
		}
	};
	return service;
}

// Register the methods, before the server starts.
fn void register_methods(contract::Context* context, BluetoothModule* m) @private
{
	ipc::Server* server = context.server;
	server.register_method("bluetooth.getState", &handle_get_state, m)!!;
	server.register_method("bluetooth.startDiscovery", &handle_start_discovery, m)!!;
	server.register_method("bluetooth.stopDiscovery", &handle_stop_discovery, m)!!;
	server.register_method("bluetooth.setPowered", &handle_set_powered, m)!!;
	server.register_method("bluetooth.togglePowered", &handle_toggle_powered, m)!!;
	server.register_method("bluetooth.pair", &handle_pair, m)!!;
	server.register_method("bluetooth.connect", &handle_connect, m)!!;
	server.register_method("bluetooth.disconnect", &handle_disconnect, m)!!;
	server.register_method("bluetooth.remove", &handle_remove, m)!!;
	server.register_method("bluetooth.trust", &handle_trust, m)!!;
	server.register_method("bluetooth.untrust", &handle_untrust, m)!!;
	server.register_method("bluetooth.pairing.submit", &handle_pairing_submit, m)!!;
	server.register_method("bluetooth.pairing.cancel", &handle_pairing_cancel, m)!!;
	server.register_method("bluetooth.mpris.publish", &handle_unsupported, m)!!;
	server.register_method("bluetooth.subscribe", &handle_unsupported, m)!!;
}

<* Start the bluetooth module, or report why not and return false. *>
fn bool start(contract::Context* context, contract::Module* self)
{
	bluetooth::Bluetooth* service = open_service(context);
	if (service == null) return false;
	stream::Reader{bluetooth::Event}* events = null;
	if (try reader = service.subscribe())
	{
		events = reader;
	}
	else
	{
		contract::warn("bluetooth: not started: %s", contract::failure_text("no event stream"));
		service.close();
		return false;
	}
	BluetoothModule* m = alloc::new(context.allocator, BluetoothModule);
	m.allocator = context.allocator;
	m.service = service;
	m.events = events;
	m.prompts.mutex.init()!!;
	m.stop_events.store(false);
	ipc::Topic* state_topic = context.server.register_topic("bluetooth")!!;
	m.prompt_topic = context.server.register_topic("bluetooth.pairing")!!;
	register_methods(context, m);
	m.state_pump.start("bluetooth", state_topic, &encode_state, m)!!;
	m.events_thread.create(&events_main, m)!!;
	m.watch_id = service.watch(&on_state, &m.state_pump);
	self.state = m;
	return true;
}

<*
 Stop the module: the state listener and the events thread first, then the pump, then the
 service. Closing the service completes the requests still queued, which answer their clients
 (refused, the server being stopped already).
*>
fn void stop(contract::Context* context, contract::Module* self)
{
	BluetoothModule* m = (BluetoothModule*)self.state;
	m.service.unwatch(m.watch_id)!!;
	m.stop_events.store(true);
	m.events_thread.join()!!;
	m.events.release();
	m.state_pump.stop();
	m.state_pump.free();
	m.service.close();
	m.prompts.mutex.destroy();
	alloc::free(context.allocator, m);
}

<* The module's descriptor for `main`. A global constant, so its slices point at static data. *>
const contract::Module DESCRIPTOR = {
	.name = "bluetooth",
	.start = &start,
	.stop = &stop,
	.topics = TOPICS[..],
	.capabilities = CAPABILITIES[..]
};

fn contract::Module descriptor() => DESCRIPTOR;

fn void handle_get_state(void* context, ipc::Call* call)
{
	BluetoothModule* m = (BluetoothModule*)context;
	@pool()
	{
		call.respond_raw(m.reply_state(tmem));
	};
}

fn void handle_start_discovery(void* context, ipc::Call* call)
{
	BluetoothModule* m = (BluetoothModule*)context;
	@pool()
	{
		if (catch discovery(m, call, true)) call.respond_error(contract::failure_text("failed to start discovery"));
	};
}

fn void handle_stop_discovery(void* context, ipc::Call* call)
{
	BluetoothModule* m = (BluetoothModule*)context;
	@pool()
	{
		if (catch discovery(m, call, false)) call.respond_error(contract::failure_text("failed to stop discovery"));
	};
}

fn void handle_set_powered(void* context, ipc::Call* call)
{
	BluetoothModule* m = (BluetoothModule*)context;
	@pool()
	{
		if (catch set_power(m, call)) call.respond_error(contract::failure_text("failed to set power state"));
	};
}

fn void handle_toggle_powered(void* context, ipc::Call* call)
{
	BluetoothModule* m = (BluetoothModule*)context;
	@pool()
	{
		if (catch toggle_power(m, call)) call.respond_error(contract::failure_text("failed to toggle power state"));
	};
}

// Run a device verb for a handler: a failure is answered with `fallback` unless the service has a text for it.
fn void run_verb(void* context, ipc::Call* call, DeviceVerb verb, String fallback) @private
{
	BluetoothModule* m = (BluetoothModule*)context;
	@pool()
	{
		if (catch device_verb(m, call, verb)) call.respond_error(contract::failure_text(fallback));
	};
}

fn void handle_pair(void* context, ipc::Call* call)
{
	run_verb(context, call, DeviceVerb.PAIR, "failed to pair");
}

fn void handle_connect(void* context, ipc::Call* call)
{
	run_verb(context, call, DeviceVerb.CONNECT, "failed to connect");
}

fn void handle_disconnect(void* context, ipc::Call* call)
{
	run_verb(context, call, DeviceVerb.DISCONNECT, "failed to disconnect");
}

fn void handle_remove(void* context, ipc::Call* call)
{
	run_verb(context, call, DeviceVerb.REMOVE, "failed to remove device");
}

fn void handle_trust(void* context, ipc::Call* call)
{
	run_verb(context, call, DeviceVerb.TRUST, "failed to trust device");
}

fn void handle_untrust(void* context, ipc::Call* call)
{
	run_verb(context, call, DeviceVerb.UNTRUST, "failed to untrust device");
}

fn void handle_pairing_submit(void* context, ipc::Call* call)
{
	BluetoothModule* m = (BluetoothModule*)context;
	@pool()
	{
		if (catch submit_pairing(
			m,
			call
		)) call.respond_error(contract::failure_text("failed to submit pairing response"));
	};
}

fn void handle_pairing_cancel(void* context, ipc::Call* call)
{
	BluetoothModule* m = (BluetoothModule*)context;
	@pool()
	{
		if (catch cancel_pairing(m, call)) call.respond_error(contract::failure_text("failed to cancel pairing"));
	};
}

// The reply text for a method Bleu cannot serve.
fn String unsupported_reason(String method) @private
{
	if (method == "bluetooth.mpris.publish") return NOT_SUPPORTED_MPRIS;
	return NOT_SUPPORTED_SUBSCRIBE;
}

fn void handle_unsupported(void* context, ipc::Call* call)
{
	call.respond_error(unsupported_reason(call.method));
}