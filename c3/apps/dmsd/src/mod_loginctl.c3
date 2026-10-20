<*
 The `loginctl` module: the session's state and the session actions DMS offers,
 over `bleu::session` and `bleu::power`.

 Methods: `loginctl.getState`, `lock`, `unlock`, `terminate`, `lockerReady`,
 `setLockBeforeSuspend`, `setSleepInhibitorEnabled`; `activate`, `setIdleHint`,
 `setLockedHint` and the streaming `subscribe` answer `not supported: ...`.
 Topic: `loginctl` (the session state, `SessionState` in DMS).

 Sleep: when `setSleepInhibitorEnabled` is true, dmsd holds a delay inhibitor
 (`Inhibit("sleep", "DankMaterialShell", "Lock before suspend", "delay")` in DMS,
 `core/internal/server/loginctl/manager.go`). On each `PrepareForSleep`, with
 lock-before-suspend on, the session is locked and dmsd waits for `lockerReady`
 (up to `LOCKER_READY_TIMEOUT`, DMS's fallback), then releases the sleep barrier.

 Source of the shapes and texts: `core/internal/server/loginctl/` at DMS master
 8be08999 (types.go, handlers.go, actions.go, manager.go). Deviations: docs/DMSD.md.
*>
module dmsd::loginctl_mod;
import std::atomic, std::thread, std::time, bleu::session, bleu::power, bleu::stream, bleu::observe, bleu::deadline, bleu::error, bleu::ipc, bleu::json, dmsd::contract, dmsd::wire;

const String[1] TOPICS = { "loginctl" };
const String[1] CAPABILITIES = { "loginctl" };

// How long a lock, unlock or terminate request may take before the reply says so.
const Duration OPERATION_TIMEOUT = (Duration)5_000_000;
// How long a sleep barrier waits for `lockerReady` after the lock request (DMS falls back on a delay too).
const Duration LOCKER_READY_TIMEOUT = (Duration)5_000_000;
// How often the barrier thread checks for its stop request while no event arrives.
const Duration POWER_POLL = (Duration)200_000;
// The inhibitor's name and reason, as DMS takes them (manager.go, acquireSleepInhibitor).
const String INHIBITOR_WHO = "DankMaterialShell";
const String INHIBITOR_WHY = "Lock before suspend";
// Replies for the methods Bleu has no equivalent of (docs/DMSD.md, coverage table).
const String NOT_SUPPORTED_ACTIVATE = "not supported: bleu_session cannot activate a session";
const String NOT_SUPPORTED_IDLE_HINT = "not supported: bleu_session reads the idle hint and cannot write it";
const String NOT_SUPPORTED_LOCKED_HINT = "not supported: bleu_session reads the locked hint and cannot write it";
const String NOT_SUPPORTED_SUBSCRIBE = "not supported: a streaming method cannot reply in this protocol; subscribe with services [\"loginctl\"] instead";

<* The module's runtime state. Allocated in `start`, freed in `stop`. *>
struct LoginctlModule
{
	session::Session* login_service;
	observe::WatchId{session::State} watch_id;
	contract::StatePump state_pump;
	Mutex state_mutex;          // guards `locker_ready` and `lock_before_suspend`
	ConditionVariable locker_cond;
	bool locker_ready;
	bool lock_before_suspend;
	Mutex inhibit_mutex;        // guards `inhibitor` and `inhibiting`; held across power calls
	bool inhibiting;
	power::Inhibitor inhibitor;
	power::Power* power_service; // null when power is absent; `power_reason` says why
	String power_reason;
	stream::Reader{power::Event}* events;
	Thread barrier;
	bool barrier_started;
	Atomic{bool} stop_barrier;
}

// Name for `session::SessionType` as logind spells it (`Type`); "" when the platform did not report it.
fn String session_type_name(session::SessionType kind)
{
	switch (kind)
	{
		case session::SessionType.UNKNOWN: return "";
		case session::SessionType.UNSPECIFIED: return "unspecified";
		case session::SessionType.TTY: return "tty";
		case session::SessionType.X11: return "x11";
		case session::SessionType.WAYLAND: return "wayland";
		case session::SessionType.MIR: return "mir";
	}
}

<*
 The DMS `SessionState` object (loginctl/types.go:13-33), field by field, in the
 Go order. Fields Bleu does not report are written empty or zero: `sessionPath`,
 `sessionClass`, `remoteHost`, `service`, `tty`, `display`, `idleSinceHint`, `vtnr`.
*>
fn String? render_state(Allocator allocator, session::State* state)
{
	bool locked = state.locked.has_value ? state.locked.value : false;
	bool active = state.current.active.has_value ? state.current.active.value : false;
	bool idle = state.idle_hint.has_value ? state.idle_hint.value : false;
	bool remote = state.current.remote.has_value ? state.current.remote.value : false;
	ulong uid = state.current.uid.has_value ? (ulong)state.current.uid.value : 0;
	wire::Line line;
	line.begin(allocator);
	json::JsonWriter* w = &line.writer;
	w.begin_object()!;
	wire::key_string(w, "sessionId", state.current.id)!;
	wire::key_string(w, "sessionPath", "")!;
	wire::key_bool(w, "locked", locked)!;
	wire::key_bool(w, "active", active)!;
	wire::key_bool(w, "idleHint", idle)!;
	wire::key_uint(w, "idleSinceHint", 0)!;
	wire::key_bool(w, "lockedHint", locked)!;
	wire::key_string(w, "sessionType", session_type_name(state.current.type))!;
	wire::key_string(w, "sessionClass", "")!;
	wire::key_uint(w, "user", uid)!;
	wire::key_string(w, "userName", state.current.user)!;
	wire::key_string(w, "remoteHost", "")!;
	wire::key_string(w, "service", "")!;
	wire::key_string(w, "tty", "")!;
	wire::key_string(w, "display", "")!;
	wire::key_bool(w, "remote", remote)!;
	wire::key_string(w, "seat", state.current.seat)!;
	wire::key_uint(w, "vtnr", 0)!;
	wire::key_bool(w, "preparingForSleep", state.sleeping)!;
	w.end_object()!;
	return line.finish();
}

// The newest state as a reply: the zero state when none has been published yet.
fn String LoginctlModule.reply_state(&self, Allocator allocator)
{
	session::State none = { };
	if (try snapshot = self.login_service.latest())
	{
		defer snapshot.release();
		if (try line = render_state(allocator, &snapshot.value)) return line;
	}
	return render_state(allocator, &none) ?? "{}";
}

// Encodes the newest state for the `loginctl` topic.
fn String? encode_state(void* context, Allocator allocator)
{
	LoginctlModule* m = (LoginctlModule*)context;
	observe::Snapshot{session::State}* snapshot = m.login_service.latest()!;
	defer snapshot.release();
	return render_state(allocator, &snapshot.value);
}

// Listener: runs on the service's thread. It only marks the pump dirty.
fn void on_state(void* context, observe::Snapshot{session::State}* snapshot)
{
	contract::StatePump* pump = (contract::StatePump*)context;
	pump.notify();
}

// Wait for an operation, or fail with "failed to <verb> session: <Bleu's message>".
fn void? await(session::SessionOperation* op, String verb) @private
{
	if (catch err = op.wait(OPERATION_TIMEOUT))
	{
		return error::raise(err, error::Domain.INTERNAL, 0, "failed to %s session: %s", verb, op.detail().message())~;
	}
}

// Lock, unlock: the session operation, awaited, then the DMS success result.
fn void? run_session_action(ipc::Call* call, LoginctlModule* m, bool lock)
{
	session::SessionOperation* op = lock ? m.login_service.lock()! : m.login_service.unlock()!;
	defer op.release();
	await(op, lock ? "lock" : "unlock")!;
	wire::respond_success(call, lock ? "locked" : "unlocked")!;
}

// Terminate the session this process runs in. Fails when there is none.
fn void? terminate_current(LoginctlModule* m, ipc::Call* call) @private
{
	observe::Snapshot{session::State}* snapshot = m.login_service.latest()!;
	defer snapshot.release();
	String id = snapshot.value.current.id;
	if (id.len == 0)
	{
		return error::raise(error::INVALID_STATE, error::Domain.INTERNAL, 0, "failed to terminate session: this process has no session")~;
	}
	session::SessionOperation* op = m.login_service.terminate_session(id)!;
	defer op.release();
	await(op, "terminate")!;
	wire::respond_success(call, "terminated")!;
}

// Acquire (`enabled`) or release the sleep delay inhibitor.
fn void? LoginctlModule.set_sleep_inhibitor(&self, bool enabled)
{
	self.inhibit_mutex.lock()!!;
	defer self.inhibit_mutex.unlock();
	if (!enabled)
	{
		self.release_inhibitor();
		return;
	}
	if (self.inhibiting) return;
	if (!self.power_service)
	{
		return error::raise(UNSUPPORTED, error::Domain.INTERNAL, 0, "not supported: no power service: %s", self.power_reason)~;
	}
	power::InhibitOperation* op = self.power_service.inhibit(power::InhibitKind.SLEEP_DELAY, INHIBITOR_WHO, INHIBITOR_WHY)!;
	defer op.release();
	if (catch err = op.wait(OPERATION_TIMEOUT))
	{
		return error::raise(err, error::Domain.INTERNAL, 0, "failed to inhibit sleep: %s", op.detail().message())~;
	}
	self.inhibitor = op.value;
	self.inhibiting = true;
}

// Release the inhibitor if held. Caller holds `inhibit_mutex`.
fn void LoginctlModule.release_inhibitor(&self) @private
{
	if (!self.inhibiting) return;
	// A queued release cannot fail here: closing the service releases the inhibitor anyway.
	if (catch self.inhibitor.release()) {}
	self.inhibiting = false;
}

// Remember the lock-before-suspend flag.
fn void LoginctlModule.set_lock_before_suspend(&self, bool enabled)
{
	self.state_mutex.lock()!!;
	defer self.state_mutex.unlock();
	self.lock_before_suspend = enabled;
}

// Mark the locker ready: the sleep barrier that waits for it may go on.
fn void LoginctlModule.mark_locker_ready(&self)
{
	self.state_mutex.lock()!!;
	defer self.state_mutex.unlock();
	self.locker_ready = true;
	self.locker_cond.broadcast()!!;
}

// Answer one `PREPARE_SLEEP` barrier: lock first when asked to, then release the barrier.
fn void LoginctlModule.answer_sleep(&self, uint ticket) @private
{
	self.state_mutex.lock()!!;
	bool lock_first = self.lock_before_suspend;
	self.locker_ready = false;
	self.state_mutex.unlock();
	if (lock_first)
	{
		if (try op = self.login_service.lock())
		{
			op.release();
		}
		else
		{
			contract::warn("loginctl: lock before suspend refused: %s", contract::failure_text("no reason given"));
		}
		self.wait_for_locker();
	}
	if (catch self.power_service.ack(ticket)) contract::warn("loginctl: could not release the sleep barrier");
}

// Wait until `lockerReady` arrives, or the timeout passes, or the module stops.
fn void LoginctlModule.wait_for_locker(&self) @private
{
	Deadline wait_until = deadline::after(LOCKER_READY_TIMEOUT);
	self.state_mutex.lock()!!;
	defer self.state_mutex.unlock();
	while (!self.locker_ready && !self.stop_barrier.load())
	{
		if (!wait_until.wait(&self.locker_cond, &self.state_mutex)) return;
	}
}

// The barrier thread: reads power events until stopped, answering each `PREPARE_SLEEP` that carries a ticket.
fn int barrier_main(void* arg) @private
{
	LoginctlModule* m = (LoginctlModule*)arg;
	foreign::@foreign_entry()
	{
		m.run_barrier();
	};
	return 0;
}

fn void LoginctlModule.run_barrier(&self) @private
{
	while (!self.stop_barrier.load())
	{
		stream::Packet{power::Event}*? next = self.events.next(POWER_POLL);
		if (try packet = next)
		{
			defer packet.release();
			if (packet.value.kind == power::EventKind.PREPARE_SLEEP && packet.value.ticket != 0)
			{
				self.answer_sleep(packet.value.ticket);
			}
			continue;
		}
		// A timeout is normal (poll the stop flag again); anything else means the stream is gone.
		if (catch err = next)
		{
			if (err != TIMEOUT) return;
		}
	}
}

// Open the power service for the inhibitor and the sleep barrier. Absence is not fatal.
fn void LoginctlModule.open_power(&self, Allocator allocator)
{
	power::Options options = { .sleep_barrier = true };
	if (try opened = power::open(allocator, options))
	{
		self.power_service = opened;
	}
	else
	{
		self.power_reason = contract::failure_text("no power service").copy(allocator);
		return;
	}
	if (try reader = self.power_service.subscribe())
	{
		self.events = reader;
		self.barrier.create(&barrier_main, self)!!;
		self.barrier_started = true;
	}
	else
	{
		self.power_reason = contract::failure_text("no event stream").copy(allocator);
		self.power_service.close();
		self.power_service = null;
	}
}

<* Start the loginctl module, or report why not and return false. *>
fn bool start(contract::Context* context, contract::Module* self)
{
	session::Options options = { };
	session::Session* service;
	if (try opened = session::open(context.allocator, options))
	{
		service = opened;
	}
	else
	{
		contract::warn("loginctl: not started: %s", contract::failure_text("no session service"));
		return false;
	}
	LoginctlModule* m = alloc::new(context.allocator, LoginctlModule);
	m.login_service = service;
	m.state_mutex.init()!!;
	m.locker_cond.init()!!;
	m.inhibit_mutex.init()!!;
	m.stop_barrier.store(false);
	m.open_power(context.allocator);
	ipc::Topic* topic = context.server.register_topic("loginctl")!!;
	context.server.register_method("loginctl.getState", &handle_get_state, m)!!;
	context.server.register_method("loginctl.lock", &handle_lock, m)!!;
	context.server.register_method("loginctl.unlock", &handle_unlock, m)!!;
	context.server.register_method("loginctl.terminate", &handle_terminate, m)!!;
	context.server.register_method("loginctl.lockerReady", &handle_locker_ready, m)!!;
	context.server.register_method("loginctl.setLockBeforeSuspend", &handle_set_lock_before_suspend, m)!!;
	context.server.register_method("loginctl.setSleepInhibitorEnabled", &handle_set_sleep_inhibitor, m)!!;
	context.server.register_method("loginctl.activate", &handle_unsupported, m)!!;
	context.server.register_method("loginctl.setIdleHint", &handle_unsupported, m)!!;
	context.server.register_method("loginctl.setLockedHint", &handle_unsupported, m)!!;
	context.server.register_method("loginctl.subscribe", &handle_unsupported, m)!!;
	m.state_pump.start("loginctl", topic, &encode_state, m)!!;
	m.watch_id = service.watch(&on_state, &m.state_pump);
	self.state = m;
	return true;
}

<*
 Stop the module: the barrier thread first (it uses both services), then the
 inhibitor, the power service, the session pump and the session service.
*>
fn void stop(contract::Context* context, contract::Module* self)
{
	LoginctlModule* m = (LoginctlModule*)self.state;
	m.login_service.unwatch(m.watch_id);
	m.stop_barrier.store(true);
	m.state_mutex.lock()!!;
	m.locker_cond.broadcast()!!;
	m.state_mutex.unlock();
	if (m.barrier_started) m.barrier.join()!!;
	m.inhibit_mutex.lock()!!;
	m.release_inhibitor();
	m.inhibit_mutex.unlock();
	if (m.events) m.events.release();
	if (m.power_service) m.power_service.close();
	m.state_pump.stop();
	m.state_pump.free();
	m.login_service.close();
	m.state_mutex.destroy();
	m.locker_cond.destroy()!!;
	m.inhibit_mutex.destroy();
	alloc::free(context.allocator, m);
}

<* The module's descriptor for `main`. *>
fn contract::Module descriptor()
{
	return { .name = "loginctl", .start = &start, .stop = &stop, .topics = TOPICS[..], .capabilities = CAPABILITIES[..] };
}

fn void handle_get_state(void* context, ipc::Call* call)
{
	LoginctlModule* m = (LoginctlModule*)context;
	@pool()
	{
		call.respond_raw(m.reply_state(tmem));
	};
}

fn void handle_lock(void* context, ipc::Call* call)
{
	LoginctlModule* m = (LoginctlModule*)context;
	@pool()
	{
		if (catch run_session_action(call, m, true)) call.respond_error(contract::failure_text("failed to lock session"));
	};
}

fn void handle_unlock(void* context, ipc::Call* call)
{
	LoginctlModule* m = (LoginctlModule*)context;
	@pool()
	{
		if (catch run_session_action(call, m, false)) call.respond_error(contract::failure_text("failed to unlock session"));
	};
}

fn void handle_terminate(void* context, ipc::Call* call)
{
	LoginctlModule* m = (LoginctlModule*)context;
	@pool()
	{
		if (catch terminate_current(m, call)) call.respond_error(contract::failure_text("failed to terminate session"));
	};
}

fn void handle_locker_ready(void* context, ipc::Call* call)
{
	LoginctlModule* m = (LoginctlModule*)context;
	m.mark_locker_ready();
	@pool()
	{
		if (catch wire::respond_success(call, "ok")) call.respond_error(contract::failure_text("failed to answer lockerReady"));
	};
}

fn void handle_set_lock_before_suspend(void* context, ipc::Call* call)
{
	LoginctlModule* m = (LoginctlModule*)context;
	@pool()
	{
		if (catch set_flag(m, call))
		{
			call.respond_error(contract::failure_text("failed to set lock before suspend"));
		}
	};
}

// `setLockBeforeSuspend` {enabled}: the flag, then the DMS success result.
fn void? set_flag(LoginctlModule* m, ipc::Call* call) @private
{
	bool enabled = wire::param_bool(call.params, "enabled")!;
	m.set_lock_before_suspend(enabled);
	wire::respond_success(call, "lock before suspend set")!;
}

fn void handle_set_sleep_inhibitor(void* context, ipc::Call* call)
{
	LoginctlModule* m = (LoginctlModule*)context;
	@pool()
	{
		if (catch set_inhibitor(m, call))
		{
			call.respond_error(contract::failure_text("failed to set sleep inhibitor"));
		}
	};
}

// `setSleepInhibitorEnabled` {enabled}: take or drop the delay inhibitor, then the DMS success result.
fn void? set_inhibitor(LoginctlModule* m, ipc::Call* call) @private
{
	bool enabled = wire::param_bool(call.params, "enabled")!;
	m.set_sleep_inhibitor(enabled)!;
	wire::respond_success(call, "sleep inhibitor setting updated")!;
}

// The reply text for a method Bleu cannot serve.
fn String unsupported_reason(String method) @private
{
	if (method == "loginctl.activate") return NOT_SUPPORTED_ACTIVATE;
	if (method == "loginctl.setIdleHint") return NOT_SUPPORTED_IDLE_HINT;
	if (method == "loginctl.setLockedHint") return NOT_SUPPORTED_LOCKED_HINT;
	return NOT_SUPPORTED_SUBSCRIBE;
}

fn void handle_unsupported(void* context, ipc::Call* call)
{
	call.respond_error(unsupported_reason(call.method));
}
