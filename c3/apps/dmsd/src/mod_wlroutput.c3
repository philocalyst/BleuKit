<*
 The `wlroutput` module: the outputs (monitors) of the Wayland compositor and their layout, on
 `bleu::display`.

 Methods: `wlroutput.getState`, `applyConfiguration`, `testConfiguration`. Refused:
 `wlroutput.subscribe` (a streaming form). Topic: `wlroutput` (DMS's `wlroutput.State`).

 Source of every shape and rule: `core/internal/server/wlroutput/` (types.go, handlers.go,
 manager.go) at DMS master 8be08999, routed by `router.go:190-195`.

 DMS's `HeadConfig` names one head and changes only what it sets; bleu_display takes a full layout
 (one entry per output). So each request starts from the newest state and changes the named heads.
 Ids: DMS's head and mode ids are Wayland object ids, which bleu_display does not have. dmsd makes
 them: a head's id is the FNV-1a hash of its connector name, and a mode's id is its 1-based
 position in the head's `modes` list (`modeId` is read against the head the request names).
 Deviations are listed in docs/DMSD.md.
*>
module dmsd::wlroutput_mod;
import std::thread, std::time, std::collections::object, bleu::display, bleu::error, bleu::ipc, bleu::json, bleu::observe, dmsd::contract, dmsd::wire, dmsd::replies;

const String[1] TOPICS       = { "wlroutput" };
const String[1] CAPABILITIES = { "wlroutput" };

// How long a request waits for the compositor to test or apply (DMS waits one second; the Wayland round trip here is longer).
const Duration CONFIG_TIMEOUT        = (Duration)5_000_000;
// The reply to `wlroutput.getState` before the first reading: DMS's empty state.
const String EMPTY_STATE             = "{\"outputs\":[],\"serial\":0}";
// The highest `transform` value (wl_output.transform: 0 normal, 1-3 rotations, 4-7 flipped rotations).
const long MAX_TRANSFORM             = 7;
// The reply text of the refused method (replies.c3).
const String NOT_SUPPORTED_SUBSCRIBE = "not supported: a streaming method cannot reply in this protocol; subscribe with services [\"wlroutput\"] instead";
// The reply text when a request sets adaptive sync: bleu_display's change has no field for it.
const String NOT_SUPPORTED_ADAPTIVE  = "not supported: bleu_display does not write adaptive sync (a layout change has no field for it)";
// The FNV-1a 32-bit parameters (the offset basis and the prime).
const uint FNV_OFFSET                = 2166136261;
const uint FNV_PRIME                 = 16777619;

const replies::Refusal[1] REFUSED = {
	{ .method = "wlroutput.subscribe", .text = NOT_SUPPORTED_SUBSCRIBE },
};

<*
 The module's runtime state. Allocated in `start`, freed in `stop`. `command` serialises the requests that change the
 layout.
*>
struct WlrModule
{
	display::Display* service;
	contract::StatePump state_pump;
	observe::WatchId{display::State} watch_id;
	Mutex command;
}

<*
 A stable 32-bit id for a connector name: FNV-1a over its bytes. DMS's head ids are Wayland object
 ids, which bleu_display does not expose, so this one is dmsd's own (docs/DMSD.md).
*>
fn uint head_id(String name)
{
	uint hash = FNV_OFFSET;
	foreach (c : name)
	{
		hash ^= (uint)c;
		hash *= FNV_PRIME;
	}
	return hash;
}

// Whether two modes are the same mode: the size and the refresh rate (DMS compares the mode objects; these are the values they carry).
fn bool same_mode(display::Mode a, display::Mode b) @inline
{
	return a.width == b.width && a.height == b.height && a.refresh == b.refresh;
}

// The 1-based position of `mode` in `output.modes`, or 0 when the output does not list it.
fn long mode_id_of(display::Output* output, display::Mode mode)
{
	foreach (i, &candidate : output.modes)
	{
		if (same_mode(*candidate, mode)) return (long)i + 1;
	}
	return 0;
}

// One DMS `Output` object (types.go:19-37), with its `modes` (types.go:11-17). Keys in Go's order.
fn void? write_output(wire::Line* line, display::Output* output)
{
	line.writer.begin_object()!;
	wire::key_string(&line.writer, "name", output.id)!;
	wire::key_string(&line.writer, "description", output.description)!;
	wire::key_string(&line.writer, "make", output.make)!;
	wire::key_string(&line.writer, "model", output.model)!;
	wire::key_string(&line.writer, "serialNumber", output.serial)!;
	wire::key_int(&line.writer, "physicalWidth", output.width_mm.has_value ? (long)output.width_mm.value : 0)!;
	wire::key_int(&line.writer, "physicalHeight", output.height_mm.has_value ? (long)output.height_mm.value : 0)!;
	wire::key_bool(&line.writer, "enabled", output.enabled)!;
	wire::key_int(&line.writer, "x", output.x)!;
	wire::key_int(&line.writer, "y", output.y)!;
	wire::key_int(&line.writer, "transform", (long)output.transform.ordinal)!;
	wire::key_double(&line.writer, "scale", output.scale.has_value ? output.scale.value : 0.0)!;
	line.writer.key("currentMode")!;
	if (output.current.has_value)
	{
		write_mode(&line.writer, output, output.current.value)!;
	}
	else
	{
		line.writer.put_null()!;
	}
	line.writer.key("modes")!;
	line.writer.begin_array()!;
	foreach (&mode : output.modes) write_mode(&line.writer, output, *mode)!;
	line.writer.end_array()!;
	wire::key_int(&line.writer, "adaptiveSync", output.adaptive_sync.has_value && output.adaptive_sync.value ? 1 : 0)!;
	wire::key_bool(&line.writer, "adaptiveSyncSupported", output.adaptive_sync.has_value)!;
	wire::key_uint(&line.writer, "id", head_id(output.id))!;
	line.writer.end_object()!;
}

// One DMS `OutputMode` (types.go:11-17): the mode's size and refresh, its preferred flag and its id.
fn void? write_mode(json::JsonWriter* writer, display::Output* output, display::Mode mode)
{
	writer.begin_object()!;
	wire::key_int(writer, "width", mode.width)!;
	wire::key_int(writer, "height", mode.height)!;
	wire::key_int(writer, "refresh", mode.refresh)!;
	wire::key_bool(writer, "preferred", mode.preferred)!;
	wire::key_int(writer, "id", mode_id_of(output, mode))!;
	writer.end_object()!;
}

// The DMS state of one snapshot: `{"outputs":[...],"serial":N}` (types.go:39-42).
fn String? render_state(Allocator allocator, display::State* state)
{
	wire::Line line;
	line.begin(allocator);
	line.writer.begin_object()!;
	line.writer.key("outputs")!;
	line.writer.begin_array()!;
	foreach (&output : state.outputs) write_output(&line, output)!;
	line.writer.end_array()!;
	wire::key_uint(&line.writer, "serial", state.serial)!;
	line.writer.end_object()!;
	return line.finish();
}

// The pump's encoder: the newest state, in temporary memory.
fn String? encode_state(void* context, Allocator allocator)
{
	WlrModule* m = (WlrModule*)context;
	if (try snapshot = m.service.latest())
	{
		defer snapshot.release();
		return render_state(allocator, &snapshot.value);
	}
	return EMPTY_STATE;
}

// Listener: runs on the display worker's thread. It only marks the pump dirty.
fn void on_state(void* context, observe::Snapshot{display::State}* snapshot)
{
	contract::StatePump* pump = (contract::StatePump*)context;
	pump.notify();
}

// The index of the output of `state` named `name`, or NOT_FOUND ("head not found", handlers.go:180-185).
fn sz? find_output(display::State* state, String name)
{
	for (sz i = 0; i < state.outputs.len; i++)
	{
		if (state.outputs[i].id == name) return i;
	}
	return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "head not found: %s", name)~;
}

// The mode a head gets when it is enabled with none named and has none current: its preferred
// mode, else the first one (bleu_display needs a mode for an enabled output).
fn display::Mode default_mode(display::Output* output)
{
	for (sz i = 0; i < output.modes.len; i++)
	{
		if (output.modes[i].preferred) return output.modes[i];
	}
	display::Mode none;
	return output.modes.len > 0 ? output.modes[0] : none;
}

// The mode with DMS id `id` in `output` (handlers.go:203-216): the 1-based position in its list.
fn display::Mode? mode_by_id(display::Output* output, long id)
{
	if (id < 1 || id > (long)output.modes.len)
	{
		return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "mode not found: %d", id)~;
	}
	return output.modes[id - 1];
}

// The `customMode` object as a mode (handlers.go:217-226): width, height and refresh, not preferred.
fn display::Mode custom_mode(Object* custom)
{
	return {
		.width = (uint)(json::read::get_int(custom, "width") ?? 0),
		.height = (uint)(json::read::get_int(custom, "height") ?? 0),
		.refresh = (uint)(json::read::get_int(custom, "refresh") ?? 0),
		.preferred = false,
	};
}

// `enabled` as Go reads it: absent is false (handlers.go:71-75 decodes the struct; a missing bool is false).
fn bool? optional_bool(Object* obj, String key) @private
{
	if (!obj.has_key(key)) return false;
	return json::read::get_bool(obj, key);
}

// The mode an enabled head gets. `modeId` names one of its modes and `customMode` gives one. With
// neither, the head keeps its current mode, or takes default_mode when it has none.
fn display::Mode? requested_mode(Object* head, display::Output* output, display::Mode current) @private
{
	if (try mode_id = json::read::get_double(head, "modeId")) return mode_by_id(output, (long)mode_id);
	if (try custom = json::read::present(head, "customMode"))
	{
		if (custom != null) return custom_mode(custom);
	}
	if (current.width == 0) return default_mode(output);
	return current;
}

// Change `config`'s entry for the head named by `head` as the request says (handlers.go:111-177).
// `state` is the newest state, which `config` was made from.
fn void? apply_head(display::Config* config, display::State* state, Object* head) @private
{
	if (!head.is_map())
	{
		return error::raise(
			error::INVALID_ARGUMENT,
			error::Domain.INTERNAL,
			0,
			"invalid heads configuration: a head is not an object"
		)~;
	}
	String name                   = json::read::get_string(head, "name") ?? "";
	sz index                      = find_output(state, name)!;
	display::OutputChange* change = &config.outputs[index];
	bool enabled                  = optional_bool(head, "enabled")!;
	change.enabled = enabled;
	if (!enabled) return;
	change.mode = requested_mode(head, &state.outputs[index], change.mode)!;
	if (try position = json::read::present(head, "position"))
	{
		if (position != null)
		{
			change.x = (int)(json::read::get_int(position, "x") ?? 0);
			change.y = (int)(json::read::get_int(position, "y") ?? 0);
		}
	}
	if (try transform = json::read::get_int(head, "transform"))
	{
		if (transform < 0 || transform > MAX_TRANSFORM)
		{
			return error::raise(
				error::INVALID_ARGUMENT,
				error::Domain.INTERNAL,
				0,
				"invalid transform: %d",
				transform
			)~;
		}
		change.transform = (display::Transform)transform;
	}
	if (try scale = json::read::get_double(head, "scale"))
	{
		change.scale.set(scale);
	}
	if (try adaptive = json::read::present(head, "adaptiveSync"))
	{
		if (adaptive != null) return error::raise(
			error::UNSUPPORTED,
			error::Domain.INTERNAL,
			0,
			"%s",
			NOT_SUPPORTED_ADAPTIVE
		)~;
	}
}

// The request's `heads` array, which must be present and an array (handlers.go:59-75).
fn Object*? heads_of(Object* params) @private
{
	Object* heads = json::read::present(params, "heads")!;
	if (heads == null) return error::raise(
		error::INVALID_ARGUMENT,
		error::Domain.INTERNAL,
		0,
		"missing 'heads' parameter"
	)~;
	if (!heads.is_array()) return error::raise(
		error::INVALID_ARGUMENT,
		error::Domain.INTERNAL,
		0,
		"invalid 'heads' parameter format"
	)~;
	return heads;
}

// Test or apply the heads of the request, and answer. The reply is DMS's SuccessResult.
fn void? configure(WlrModule* m, ipc::Call* call, display::ApplyMode mode) @private
{
	Object* heads = heads_of(call.params)!;
	m.command.lock()!!;
	defer m.command.unlock();
	observe::Snapshot{display::State}* latest = m.service.latest()!;
	defer latest.release();
	// The full layout of the newest state; the named heads are changed below (DMS changes only the heads it names).
	display::Config config = display::config_from_state(latest.value, tmem);
	for (sz i = 0; i < heads.get_len(); i++)
	{
		apply_head(&config, &latest.value, heads.get_at(i))!;
	}
	display::ApplyOp* op = m.service.apply(config, mode)!;
	defer op.release();
	if (catch err = op.wait(CONFIG_TIMEOUT))
	{
		String what = mode == display::ApplyMode.TEST_ONLY ? "test" : "apply";
		return error::raise(err, error::Domain.INTERNAL, 0, "failed to %s configuration: %s", what, op.detail()
			.message())~;
	}
	wire::respond_success(
		call,
		mode == display::ApplyMode.TEST_ONLY ? "configuration test succeeded" : "configuration applied"
	)!;
}

fn void handle_get_state(void* context, ipc::Call* call)
{
	WlrModule* m = (WlrModule*)context;
	@pool()
	{
		if (try line = encode_state(m, tmem))
		{
			call.respond_raw(line);
		}
		else
		{
			call.respond_error(contract::failure_text("failed to read the outputs"));
		}
	};
}

fn void handle_apply(void* context, ipc::Call* call)
{
	WlrModule* m = (WlrModule*)context;
	@pool()
	{
		if (catch configure(
			m,
			call,
			display::ApplyMode.APPLY
		)) call.respond_error(contract::failure_text("failed to apply configuration"));
	};
}

fn void handle_test(void* context, ipc::Call* call)
{
	WlrModule* m = (WlrModule*)context;
	@pool()
	{
		if (catch configure(
			m,
			call,
			display::ApplyMode.TEST_ONLY
		)) call.respond_error(contract::failure_text("failed to test configuration"));
	};
}

// Answers the refused methods (replies.c3).
fn void handle_refused(void* context, ipc::Call* call)
{
	replies::answer(REFUSED[..], call);
}

<* Start the module, or report why not and return false: no compositor with outputs, or no output management. *>
fn bool start(contract::Context* context, contract::Module* self)
{
	display::Options options = { .backend = display::Backend.AUTO, .root = context.options.fake_root };
	display::Display* service;
	if (try opened = display::open(context.allocator, options))
	{
		service = opened;
	}
	else
	{
		contract::warn("wlroutput: not started: %s", contract::failure_text("no backend"));
		return false;
	}
	WlrModule* m = alloc::new(context.allocator, WlrModule);
	m.service = service;
	m.command.init()!!;
	ipc::Topic* topic = context.server.register_topic("wlroutput")!!;
	context.server.register_method("wlroutput.getState", &handle_get_state, m)!!;
	context.server.register_method("wlroutput.applyConfiguration", &handle_apply, m)!!;
	context.server.register_method("wlroutput.testConfiguration", &handle_test, m)!!;
	replies::register_all(context.server, REFUSED[..], &handle_refused)!!;
	m.state_pump.start("wlroutput", topic, &encode_state, m)!!;
	m.watch_id = service.watch(&on_state, &m.state_pump);
	m.state_pump.notify();
	self.state = m;
	return true;
}

<* Stop the module: no more publications, then the service is closed. The server has stopped already. *>
fn void stop(contract::Context* context, contract::Module* self)
{
	WlrModule* m = (WlrModule*)self.state;
	m.service.unwatch(m.watch_id)!!;
	m.state_pump.stop();
	m.state_pump.free();
	m.service.close();
	m.command.destroy();
	alloc::free(context.allocator, m);
}

<* The module's descriptor for `main`. A global constant, so its slices point at static data. *>
const contract::Module DESCRIPTOR = {
	.name = "wlroutput",
	.start = &start,
	.stop = &stop,
	.topics = TOPICS[..],
	.capabilities = CAPABILITIES[..],
};

fn contract::Module descriptor() => DESCRIPTOR;