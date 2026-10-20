<*
 The `brightness` module: DMS's brightness methods and streams over
 `bleu::brightness`.

 Methods: `brightness.getState`, `setBrightness`, `increment`, `decrement`,
 `rescan`. Topics: `brightness` (the state, `{"devices":[...]}`) and
 `brightness.update` (one device, after a request changed it).

 Source of every shape and rule: `core/internal/server/brightness/`
 (types.go, handlers.go, manager.go, sysfs.go, ddc.go) at DMS master 8be08999.
 The arithmetic is in `brightness_math.c3`. Deviations are listed in docs/DMSD.md.
*>
module dmsd::brightness_mod;
import std::collections::list, std::time, bleu::brightness, bleu::error, bleu::ipc, bleu::json, bleu::observe, bleu::unit, dmsd::contract, dmsd::wire, dmsd::brightness_math;

const String[2] TOPICS = { "brightness", "brightness.update" };
const String[1] CAPABILITIES = { "brightness" };

// Bus address used when a fake sysfs root is given: logind is then unreachable and writes go to the fake files.
const String NO_LOGIND = "unix:path=/nonexistent/dmsd-no-logind";
// How long a request waits for its write to finish (the DDC/CI writes take a while).
const Duration WRITE_TIMEOUT = (Duration)5_000_000;
// How long a request waits for the state to show its write before it answers with the newest state.
const Duration SETTLE_TIMEOUT = (Duration)500_000;
// Reply when there is no state yet: DMS's empty list.
const String EMPTY_STATE = "{\"devices\":[]}";
// Reply text when a request names the subscribe form of a stream.
const String SUBSCRIBE_UNSUPPORTED = "not supported: a streaming method cannot reply in this protocol; subscribe with services [\"brightness\"] instead";

<* The module's runtime state. Allocated in `start`, freed in `stop`. *>
struct BrightnessModule
{
	brightness::Brightness* service;
	contract::StatePump state_pump;
	ipc::Topic* update_topic;
	observe::WatchId{brightness::State} watch_id;
}

<*
 One device as DMS shows it, read from one snapshot. `id` and the class-derived
 strings are in temporary memory; `device` and `control` point into the snapshot.
*>
struct Shown
{
	brightness_math::DmsClass cls;
	String id;
	String name;
	brightness::Device* device;
	brightness::Control* control;
	long current;
	long max;
	long percent;
}

<*
 Build the DMS view of `device`, or return false when DMS does not list it: a
 device with no hardware control, a native panel (no DMS class is known for it),
 or a sysfs device DMS suppresses.
*>
fn bool to_shown(brightness::Device* device, Shown* out)
{
	brightness::Control* control = display_control(device);
	if (!control) return false;
	brightness_math::DmsClass cls;
	switch (control.mechanism)
	{
		case brightness::Mechanism.BACKLIGHT: cls = BACKLIGHT;
		case brightness::Mechanism.KEYBOARD_LED: cls = LEDS;
		case brightness::Mechanism.DDC: cls = DDC;
		case brightness::Mechanism.NATIVE: return false;
		case brightness::Mechanism.GAMMA: return false;
		case brightness::Mechanism.OVERLAY: return false;
	}
	if (cls != DDC && brightness_math::suppressed(device.id)) return false;
	long raw = control.raw.has_value ? control.raw.value : 0;
	out.cls = cls;
	out.device = device;
	out.control = control;
	out.current = raw;
	out.max = control.raw_max;
	// DMS names a sysfs device by its entry name, and a monitor by its adapter's name.
	out.name = cls == DDC ? device.name : device.id;
	out.id = cls == DDC ? string::tformat("ddc:%s", device.id) : string::tformat("%s:%s", cls.wire_name(), device.id);
	out.percent = cls == DDC
		? brightness_math::ddc_percent(raw, control.raw_max)
		: brightness_math::sysfs_percent(raw, cls.min_value(), control.raw_max);
	return true;
}

<*
 The control DMS reads and writes: a writable hardware control if there is one,
 else the first hardware control. Software controls (gamma, overlay) are never
 shown. Null when the device has none.
*>
fn brightness::Control* display_control(brightness::Device* device)
{
	brightness::Control* first = null;
	foreach (&control : device.controls)
	{
		if (control.mechanism.is_software()) continue;
		if (control.writable) return control;
		if (!first) first = control;
	}
	return first;
}

// Byte-wise order of two strings, as Go compares them.
fn bool less_text(String a, String b) @private
{
	usz common = a.len < b.len ? (usz)a.len : (usz)b.len;
	for (usz i = 0; i < common; i++)
	{
		if (a[i] != b[i]) return a[i] < b[i];
	}
	return a.len < b.len;
}

// DMS order: by class rank, then by name (manager.go sortDevices).
fn bool before(Shown* a, Shown* b) @private
{
	if (a.cls.rank() != b.cls.rank()) return a.cls.rank() < b.cls.rank();
	return less_text(a.name, b.name);
}

// Insertion sort: the list is short and the order must match DMS exactly.
fn void sort_shown(Shown[] items) @private
{
	for (sz i = 1; i < items.len; i++)
	{
		Shown item = items[i];
		sz j = i;
		while (j > 0 && before(&item, &items[j - 1]))
		{
			items[j] = items[j - 1];
			j--;
		}
		items[j] = item;
	}
}

// One device as a DMS `Device` object (brightness/types.go:21-28).
fn void? write_shown(json::JsonWriter* writer, Shown* shown)
{
	writer.begin_object()!;
	wire::key_string(writer, "class", shown.cls.wire_name())!;
	wire::key_string(writer, "id", shown.id)!;
	wire::key_string(writer, "name", shown.name)!;
	wire::key_int(writer, "current", shown.current)!;
	wire::key_int(writer, "max", shown.max)!;
	wire::key_int(writer, "currentPercent", shown.percent)!;
	wire::key_string(writer, "backend", shown.cls.backend())!;
	writer.end_object()!;
}

// The DMS device list of one snapshot: `{"devices":[...]}` (brightness/types.go:31-33).
fn String? render_state(Allocator allocator, brightness::State* state)
{
	List{Shown} listed;
	listed.init(allocator);
	foreach (&device : state.devices)
	{
		Shown shown;
		if (to_shown(device, &shown)) listed.push(shown);
	}
	Shown[] items = listed.array_view();
	sort_shown(items);
	wire::Line line;
	line.begin(allocator);
	line.writer.begin_object()!;
	line.writer.key("devices")!;
	line.writer.begin_array()!;
	foreach (&shown : items) write_shown(&line.writer, shown)!;
	line.writer.end_array()!;
	line.writer.end_object()!;
	return line.finish();
}

// `{"device":{...}}`: the payload of `brightness.update` (brightness/types.go:35-37).
fn String? render_update(Allocator allocator, Shown* shown)
{
	wire::Line line;
	line.begin(allocator);
	line.writer.begin_object()!;
	line.writer.key("device")!;
	write_shown(&line.writer, shown)!;
	line.writer.end_object()!;
	return line.finish();
}

// The shown device whose DMS id is `id`, or NOT_FOUND ("device not found: <id>", manager.go).
fn Shown? find_shown(brightness::State* state, String id) @private
{
	foreach (&device : state.devices)
	{
		Shown shown;
		if (!to_shown(device, &shown)) continue;
		if (shown.id == id) return shown;
	}
	return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "device not found: %s", id)~;
}

// The state newer than `seen` when one arrives in time, else the newest state.
fn observe::Snapshot{brightness::State}*? settle(brightness::Brightness* service, ulong seen)
{
	if (try newer = service.wait_after(seen, SETTLE_TIMEOUT)) return newer;
	return service.latest();
}

<*
 Set `id` to `percent` (manager.go SetBrightnessWithExponent). The raw value is
 the DMS curve's value for the device, and the request writes it as a level of the
 device's own range, so the backend writes exactly that raw value.

 @return "The state to answer with: the one after the write, in `allocator`"
 @return? error::INVALID_ARGUMENT : "percent is negative"
 @return? error::NOT_FOUND : "device not found"
 @return? error::BACKEND_FAILURE : "the write failed or timed out"
*>
fn String? BrightnessModule.apply_percent(&self, Allocator allocator, String id, long percent, bool exponential, double exponent)
{
	if (percent < 0)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "percent out of range: %d", percent)~;
	}
	observe::Snapshot{brightness::State}* before = self.service.latest()!;
	defer before.release();
	Shown shown = find_shown(&before.value, id)!;
	brightness::Control* control = shown.control;
	long span = control.raw_max - control.raw_min;
	if (span <= 0)
	{
		return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, 0, "device '%s' has no brightness range", id)~;
	}
	long target = brightness_math::target_value(shown.cls, percent, control.raw_max, exponential, exponent);
	double fraction = (double)(target - control.raw_min) / (double)span;
	brightness::SetOperation* op = self.service.set_level(shown.device.id, unit::level((float)fraction))!;
	defer op.release();
	if (catch err = op.wait(WRITE_TIMEOUT))
	{
		return error::raise(err, error::Domain.INTERNAL, 0, "failed to set brightness: %s", op.detail().message())~;
	}
	observe::Snapshot{brightness::State}* after = settle(self.service, before.generation)!;
	defer after.release();
	if (try updated = find_shown(&after.value, id))
	{
		self.publish_update(allocator, &updated);
	}
	return render_state(allocator, &after.value);
}

// Publish `brightness.update` for `shown`. Nobody listening is not an error.
fn void BrightnessModule.publish_update(&self, Allocator allocator, Shown* shown) @private
{
	if (try update = render_update(allocator, shown))
	{
		if (catch self.update_topic.publish_event(update)) contract::note("brightness.update not sent");
	}
}

<*
 Move `id` by `step` percent, clamped to 0..100 (manager.go IncrementBrightnessWithExponent):
 the step is applied to the percent the state shows now.
*>
fn String? BrightnessModule.step_percent(&self, Allocator allocator, String id, long step, bool exponential, double exponent)
{
	observe::Snapshot{brightness::State}* now = self.service.latest()!;
	defer now.release();
	Shown shown = find_shown(&now.value, id)!;
	return self.apply_percent(allocator, id, brightness_math::clamp_percent(shown.percent + step), exponential, exponent);
}

// The newest state as a reply: the empty list when none has been published yet.
fn String BrightnessModule.reply_state(&self, Allocator allocator)
{
	if (try snapshot = self.service.latest())
	{
		defer snapshot.release();
		if (try line = render_state(allocator, &snapshot.value)) return line;
	}
	return EMPTY_STATE;
}

// Encodes the newest state for the `brightness` topic.
fn String? encode_state(void* context, Allocator allocator)
{
	BrightnessModule* m = (BrightnessModule*)context;
	observe::Snapshot{brightness::State}* snapshot = m.service.latest()!;
	defer snapshot.release();
	return render_state(allocator, &snapshot.value);
}

// Listener: runs on the service's thread. It only marks the pump dirty.
fn void on_state(void* context, observe::Snapshot{brightness::State}* snapshot)
{
	contract::StatePump* pump = (contract::StatePump*)context;
	pump.notify();
}

<* Start the brightness module, or report why not and return false. *>
fn bool start(contract::Context* context, contract::Module* self)
{
	brightness::Options options = { .root = context.options.fake_root };
	if (context.options.fake_root.len > 0) options.bus_address = NO_LOGIND;
	brightness::Brightness* service;
	if (try opened = brightness::open(context.allocator, options))
	{
		service = opened;
	}
	else
	{
		contract::warn("brightness: not started: %s", contract::failure_text("no backend"));
		return false;
	}
	BrightnessModule* m = alloc::new(context.allocator, BrightnessModule);
	m.service = service;
	ipc::Topic* state_topic = context.server.register_topic("brightness")!!;
	m.update_topic = context.server.register_topic("brightness.update")!!;
	context.server.register_method("brightness.getState", &handle_get_state, m)!!;
	context.server.register_method("brightness.setBrightness", &handle_set_brightness, m)!!;
	context.server.register_method("brightness.increment", &handle_increment, m)!!;
	context.server.register_method("brightness.decrement", &handle_decrement, m)!!;
	context.server.register_method("brightness.rescan", &handle_rescan, m)!!;
	context.server.register_method("brightness.subscribe", &handle_subscribe, m)!!;
	m.state_pump.start("brightness", state_topic, &encode_state, m)!!;
	m.watch_id = service.watch(&on_state, &m.state_pump);
	self.state = m;
	return true;
}

<* Stop the module: no more publications, then the service is closed. The server has stopped already. *>
fn void stop(contract::Context* context, contract::Module* self)
{
	BrightnessModule* m = (BrightnessModule*)self.state;
	m.service.unwatch(m.watch_id);
	m.state_pump.stop();
	m.state_pump.free();
	m.service.close();
	alloc::free(context.allocator, m);
}

<* The module's descriptor for `main`. *>
fn contract::Module descriptor()
{
	return { .name = "brightness", .start = &start, .stop = &stop, .topics = TOPICS[..], .capabilities = CAPABILITIES[..] };
}

fn void handle_get_state(void* context, ipc::Call* call)
{
	BrightnessModule* m = (BrightnessModule*)context;
	@pool()
	{
		call.respond_raw(m.reply_state(tmem));
	};
}

fn void handle_set_brightness(void* context, ipc::Call* call)
{
	BrightnessModule* m = (BrightnessModule*)context;
	@pool()
	{
		if (catch set_brightness(m, call))
		{
			call.respond_error(contract::failure_text("failed to set brightness"));
		}
	};
}

// Parse, apply, reply. Any error is returned and answered by the caller.
fn void? set_brightness(BrightnessModule* m, ipc::Call* call) @private
{
	String device = wire::param_string(call.params, "device")!;
	long percent = wire::param_int(call.params, "percent")!;
	bool exponential = wire::opt_bool(call.params, "exponential", false);
	double exponent = wire::opt_float(call.params, "exponent", brightness_math::DEFAULT_EXPONENT);
	String line = m.apply_percent(tmem, device, percent, exponential, exponent)!;
	call.respond_raw(line);
}

fn void handle_increment(void* context, ipc::Call* call)
{
	BrightnessModule* m = (BrightnessModule*)context;
	@pool()
	{
		if (catch step_by(m, call, 1))
		{
			call.respond_error(contract::failure_text("failed to change brightness"));
		}
	};
}

fn void handle_decrement(void* context, ipc::Call* call)
{
	BrightnessModule* m = (BrightnessModule*)context;
	@pool()
	{
		if (catch step_by(m, call, -1))
		{
			call.respond_error(contract::failure_text("failed to change brightness"));
		}
	};
}

// `increment` (direction 1) and `decrement` (direction -1): step defaults to 10 (handlers.go).
fn void? step_by(BrightnessModule* m, ipc::Call* call, long direction) @private
{
	String device = wire::param_string(call.params, "device")!;
	long step = wire::opt_int(call.params, "step", 10);
	bool exponential = wire::opt_bool(call.params, "exponential", false);
	double exponent = wire::opt_float(call.params, "exponent", brightness_math::DEFAULT_EXPONENT);
	String line = m.step_percent(tmem, device, direction * step, exponential, exponent)!;
	call.respond_raw(line);
}

fn void handle_rescan(void* context, ipc::Call* call)
{
	BrightnessModule* m = (BrightnessModule*)context;
	@pool()
	{
		if (catch m.service.refresh())
		{
			call.respond_error(contract::failure_text("failed to rescan brightness devices"));
		}
		else
		{
			call.respond_raw(m.reply_state(tmem));
		}
	};
}

// DMS streams from this method; the protocol here answers once, so it refuses.
fn void handle_subscribe(void* context, ipc::Call* call)
{
	call.respond_error(SUBSCRIBE_UNSUPPORTED);
}
