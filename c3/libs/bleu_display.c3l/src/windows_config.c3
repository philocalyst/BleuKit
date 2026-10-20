<*
 The Windows backend: QueryDisplayConfig to read the topology, EnumDisplaySettingsExW to list the
 modes of each display, and SetDisplayConfig to change it: the configuration is validated first,
 then applied, both in one call each, with SDC_SAVE_TO_DATABASE for a persistent change. Windows has
 no revert, so `APPLY_WITH_REVERT` is the shared flow's rollback: the previous topology is applied
 again when no confirmation arrives.

 Display changes arrive as WM_DISPLAYCHANGE through the message loop of the worker. Compiled and
 type-checked for Windows; not run (no Windows machine was available to build this on).
*>
module bleu::display::windows_config @feat(WIN32);
import bleu::display, bleu::display::win_native, bleu::display::win_convert, bleu::error, bleu::availability, bleu::observe, bleu::operation, bleu::rt::poller, bleu::rt::worker, bleu::rt::mailbox, bleu::win::message_loop, bleu::win::text;
import std::os::win32, std::time, std::time::clock, std::math, std::collections::maybe, std::collections::list, std::core::string;

const Driver DRIVER = {
	.info = { "windows", "QueryDisplayConfig and SetDisplayConfig (validate, then apply)", 20 },
	.id = WINDOWS,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

<* Topology queries are made with every path, so inactive outputs are listed too. *>
const uint QUERY_FLAGS = QDC_ALL_PATHS;

<* The backend's state: the mailbox, the synchronous flow, and what the message loop has seen. *>
struct Backend
{
	Allocator allocator;
	DisplayHub* hub;
	Mailbox{Command}* mailbox;
	bool dirty;
	SyncNative native;
	Rollback rollback;
}

// Every Windows session has a display configuration; `create` checks that it can be read.
fn bool probe(Options* options) => true;

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	@pool()
	{
		query_topology(tmem, QUERY_FLAGS)!;
	};
	fill_capabilities(capabilities);
	Backend* backend = alloc::new(allocator, Backend);
	backend.allocator = allocator;
	backend.native = { .backend = backend, .allocator = allocator, .read = &read_native, .commit = &commit_native, .can_rotate = true, .can_toggle = true };
	return backend;
}

fn void destroy(Allocator allocator, void* state)
{
	Backend* backend = (Backend*)state;
	if (backend.rollback.op) backend.rollback.op.release();
	alloc::free(allocator, backend);
}

// What Windows can do here. Scale and advanced colour are not written by this backend.
fn void fill_capabilities(Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	capabilities.set(SET_SCALE, availability::no(availability::Reason.UNSUPPORTED_BACKEND, "scale is changed in Windows Settings; no public call is bound here"));
	capabilities.set(SET_ENABLED, { .reason = availability::Reason.DEGRADED, .note = "an active output can be switched off; switching on an inactive output is not in this version" });
	capabilities.set(SET_MIRROR, availability::no(availability::Reason.UNSUPPORTED_BACKEND, "mirroring (the clone topology) is not written in this version"));
	capabilities.set(SET_HDR, availability::no(availability::Reason.UNSUPPORTED_BACKEND, "advanced colour is not read or written in this version"));
	capabilities.set(SET_COLOUR_DEPTH, availability::no(availability::Reason.UNSUPPORTED_BACKEND, "advanced colour is not read or written in this version"));
	capabilities.set(SET_ADAPTIVE_SYNC, availability::no(availability::Reason.UNSUPPORTED_BACKEND, "adaptive sync is not read or written in this version"));
}

// A topology as Windows returned it: the paths and the modes they index, in `tmp`.
struct Topology
{
	PathInfo[] paths;
	ModeInfo[] modes;
}

<* The paths and modes of the current display configuration, in `tmp`. *>
fn Topology? query_topology(Allocator tmp, uint flags)
{
	uint path_count = 0;
	uint mode_count = 0;
	if (get_display_config_buffer_sizes(flags, &path_count, &mode_count) != 0) {
		return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, 0, "GetDisplayConfigBufferSizes failed")~;
	}
	PathInfo[] paths = alloc::new_array(tmp, PathInfo, path_count);
	ModeInfo[] modes = alloc::new_array(tmp, ModeInfo, mode_count);
	if (query_display_config(flags, &path_count, paths.ptr, &mode_count, modes.ptr, null) != 0) {
		return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, 0, "QueryDisplayConfig failed")~;
	}
	return { .paths = paths[0:path_count], .modes = modes[0:mode_count] };
}

// The index a path's mode-info field names for its source (high half) or target (high half too).
fn uint mode_index(uint mode_info) @inline => (mode_info >> 16) & MODE_INDEX_INVALID;

// The number of characters before the terminating NUL of a wide string.
fn sz wide_length(Char16[] units)
{
	for (sz i = 0; i < units.len; i++) {
		if (units[i] == 0) return i;
	}
	return units.len;
}

// A wide string from a fixed buffer, copied into `allocator`.
fn String? wide_text(Char16[] units, Allocator allocator)
{
	return text::from_wide_units(allocator, units[0:wide_length(units)]);
}

// The monitor device path of a path's target: the stable output id.
fn String? device_path(PathInfo path, Allocator allocator)
{
	TargetDeviceName name;
	name.header.info_type = DEVICE_INFO_TARGET_NAME;
	name.header.size = (uint)@sizeof(name);
	name.header.adapter = path.target.adapter;
	name.header.id = path.target.id;
	if (display_config_get_device_info((DeviceInfoHeader*)&name) != 0) {
		return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, 0, "DisplayConfigGetDeviceInfo (target) failed")~;
	}
	return wide_text(name.device_path[..], allocator);
}

// The friendly monitor name of a path's target, for people to read.
fn String? friendly_name(PathInfo path, Allocator allocator)
{
	TargetDeviceName name;
	name.header.info_type = DEVICE_INFO_TARGET_NAME;
	name.header.size = (uint)@sizeof(name);
	name.header.adapter = path.target.adapter;
	name.header.id = path.target.id;
	if (display_config_get_device_info((DeviceInfoHeader*)&name) != 0) {
		return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, 0, "DisplayConfigGetDeviceInfo (target) failed")~;
	}
	return wide_text(name.friendly_name[..], allocator);
}

// The GDI device name of a path's source, such as \\.\DISPLAY1, which EnumDisplaySettingsExW takes.
fn Char16[CCH_DEVICE_NAME]? gdi_name_of(PathInfo path)
{
	SourceDeviceName name;
	name.header.info_type = DEVICE_INFO_SOURCE_NAME;
	name.header.size = (uint)@sizeof(name);
	name.header.adapter = path.source.adapter;
	name.header.id = path.source.id;
	if (display_config_get_device_info((DeviceInfoHeader*)&name) != 0) {
		return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, 0, "DisplayConfigGetDeviceInfo (source) failed")~;
	}
	return name.gdi_name;
}

<*
 The modes EnumDisplaySettingsExW lists for a GDI device name, in `allocator`. Its frequency is a
 whole number of hertz, so 59.94 Hz is listed as 60 Hz; the current rate is exact (see `describe`).
*>
fn display::Mode[] modes_of(Char16[CCH_DEVICE_NAME] gdi_name, Allocator allocator)
{
	List{display::Mode} found;
	found.init(allocator);
	defer found.free();
	Win32_DEVMODEW devmode;
	for (uint index = 0; ; index++) {
		devmode.dmSize = (ushort)@sizeof(devmode);
		if (enum_display_settings_ex(&gdi_name[0], index, &devmode, 0) == 0) break;
		display::Mode mode = {
			.width = devmode.dmPelsWidth,
			.height = devmode.dmPelsHeight,
			.refresh = devmode.dmDisplayFrequency * 1000,
		};
		if (!contains_mode(found.array_view(), mode)) found.push(mode);
	}
	return found.to_aligned_array(allocator);
}

// True when the list already holds this size and refresh.
fn bool contains_mode(display::Mode[] modes, display::Mode mode) @private
{
	foreach (known : modes) {
		if (known.width == mode.width && known.height == mode.height && known.refresh == mode.refresh) return true;
	}
	return false;
}

// The output a path describes: where it sits, its current mode and rotation, and the modes it offers.
fn display::Output? describe(PathInfo path, Topology topo, Allocator allocator)
{
	display::Output out;
	out.id = device_path(path, allocator)!;
	out.name = friendly_name(path, allocator)!;
	Char16[CCH_DEVICE_NAME] gdi = gdi_name_of(path)!;
	out.modes = modes_of(gdi, allocator);
	out.enabled = (path.flags & DISPLAYCONFIG_PATH_ACTIVE) != 0;
	out.transform = win_convert::transform_from_rotation(path.target.rotation);
	if (!out.enabled) return out;
	uint source_index = mode_index(path.source.mode_info);
	if (source_index < topo.modes.len) {
		SourceMode* source = (SourceMode*)&topo.modes[source_index].payload[0];
		out.x = source.position_x;
		out.y = source.position_y;
		out.current.set({
			.width = source.width,
			.height = source.height,
			.refresh = win_convert::refresh_from_fraction(path.target.refresh_rate.numerator, path.target.refresh_rate.denominator),
		});
	}
	out.primary.set(out.x == 0 && out.y == 0);
	return out;
}

// Whether this path is the first of its target: a target shared by clone paths is listed once.
fn bool first_path_of_target(PathInfo[] paths, sz index) @private
{
	for (sz j = 0; j < index; j++) {
		if (paths[j].target.id == paths[index].target.id && paths[j].target.adapter.low_part == paths[index].target.adapter.low_part) return false;
	}
	return true;
}

// The state of every target, allocated in `allocator`.
fn display::State? read_native_state(Allocator allocator)
{
	display::State state;
	@pool()
	{
		Topology topo = query_topology(tmem, QUERY_FLAGS)!;
		display::Output[] outputs = alloc::new_array(allocator, display::Output, topo.paths.len);
		sz count = 0;
		for (sz i = 0; i < topo.paths.len; i++) {
			if (!first_path_of_target(topo.paths, i)) continue;
			outputs[count++] = describe(topo.paths[i], topo, allocator)!;
		}
		state.outputs = outputs[0:count];
	};
	return state;
}

// The read the synchronous flow uses.
fn State? read_native(void* backend, Allocator allocator)
{
	return read_native_state(allocator);
}

// The commit the synchronous flow uses: validate the topology, then apply it unless only testing.
fn void? commit_native(void* backend, Config config, bool test_only, bool persistent)
{
	@pool()
	{
		Topology topo = query_topology(tmem, QUERY_FLAGS)!;
		PathInfo[] kept = alloc::new_array(tmem, PathInfo, topo.paths.len);
		sz count = 0;
		for (sz i = 0; i < topo.paths.len; i++) {
			PathInfo path = topo.paths[i];
			String id = device_path(path, tmem)!;
			Maybe{sz} change = change_for(config, id);
			if (change.has_value) path = change_path(path, topo.modes, config.outputs[change.value])!;
			if ((path.flags & DISPLAYCONFIG_PATH_ACTIVE) != 0) kept[count++] = path;
		}
		uint validate = SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_VALIDATE;
		if (set_display_config((uint)count, kept.ptr, (uint)topo.modes.len, topo.modes.ptr, validate) != 0) {
			return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "Windows refuses the configuration (SetDisplayConfig validate)")~;
		}
		if (test_only) return;
		uint apply = SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_APPLY | SDC_ALLOW_CHANGES;
		if (persistent) apply |= SDC_SAVE_TO_DATABASE;
		if (set_display_config((uint)count, kept.ptr, (uint)topo.modes.len, topo.modes.ptr, apply) != 0) {
			return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, 0, "SetDisplayConfig (apply) failed")~;
		}
	};
}

// The index of the change for this output id.
fn Maybe{sz} change_for(Config config, String id)
{
	for (sz i = 0; i < config.outputs.len; i++) {
		if (config.outputs[i].output_id == id) return maybe::value(i);
	}
	return { };
}

<*
 A path with its change applied: off (dropped from the topology), or on with the mode, place,
 refresh and rotation the change names. The mode it edits is shared through `modes`.
*>
fn PathInfo? change_path(PathInfo path, ModeInfo[] modes, display::OutputChange change)
{
	if (!change.enabled) {
		path.flags &= ~DISPLAYCONFIG_PATH_ACTIVE;
		return path;
	}
	if ((path.flags & DISPLAYCONFIG_PATH_ACTIVE) == 0) {
		return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "switching on an inactive output is not in this version")~;
	}
	uint source_index = mode_index(path.source.mode_info);
	if (source_index >= modes.len) return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, 0, "the path names no source mode")~;
	SourceMode* source = (SourceMode*)&modes[source_index].payload[0];
	source.width = change.mode.width;
	source.height = change.mode.height;
	source.position_x = change.x;
	source.position_y = change.y;
	if (change.mode.refresh != 0) {
		Fraction fraction = win_convert::fraction_from_refresh(change.mode.refresh);
		path.target.refresh_rate = { .numerator = fraction.numerator, .denominator = fraction.denominator };
	}
	uint rotation = 0;
	if (!win_convert::rotation_of(change.transform, &rotation)) {
		return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "Windows cannot rotate an output with a flip")~;
	}
	path.target.rotation = rotation;
	return path;
}

fn void run(void* state, DisplayHub* hub, Host{Command}* host)
{
	Backend* b = (Backend*)state;
	b.hub = hub;
	b.mailbox = host.mailbox();
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 1, true)) return;
	defer poller.free();
	Loop* loop = message_loop::open(mem, &on_message, b)!!;
	defer loop.close();
	publish(b);
	Command[8] commands;
	while (!host.stopping()) {
		if (catch poller.wait(b.rollback.guard.remaining(clock::now()))) {
			// TIMEOUT: nothing happened in the wait, or the rollback is due.
		}
		message_loop::dispatch_pending();
		usz count = host.mailbox().take_all(commands[..]);
		for (usz i = 0; i < count; i++) handle(b, commands[i], clock::now());
		if (b.rollback.guard.due(clock::now())) {
			revert_sync(&b.native, &b.rollback, b.hub);
			b.dirty = true;
		}
		if (b.dirty) {
			b.dirty = false;
			publish(b);
		}
	}
	shutdown(b, host);
}

// Window messages: a display change (monitor added or removed, resolution changed) is worth a read.
fn void on_message(void* context, message_loop::Event* event)
{
	Backend* b = (Backend*)context;
	if (event.kind == message_loop::EventKind.DISPLAY_CHANGE) b.dirty = true;
}

fn void publish(Backend* b)
{
	Snapshot{display::State}* snapshot = b.hub.begin();
	display::State? state = read_native_state(snapshot.allocator());
	if (catch err = state) {
		snapshot.value = { };
	} else {
		snapshot.value = state;
	}
	display::publish_snapshot(b.hub, snapshot);
}

fn void handle(Backend* b, Command command, Clock now)
{
	switch (command.kind) {
		case REFRESH: b.dirty = true;
		case CONFIRM: confirm_sync(&b.rollback, now);
		case APPLY: apply_sync(&b.native, &b.rollback, command, now);
	}
}

// Stop: a rollback still armed is applied now; queued commands are refused.
fn void shutdown(Backend* b, Host{Command}* host)
{
	if (b.rollback.guard.armed) revert_sync(&b.native, &b.rollback, b.hub);
	Command[8] commands;
	usz count = host.mailbox().take_all(commands[..]);
	while (count > 0) {
		for (usz i = 0; i < count; i++) {
			if (commands[i].kind == APPLY) display::reject(commands[i].op, error::raise(error::DISCONNECTED, error::Domain.INTERNAL, 0, "the display service stopped"));
		}
		count = host.mailbox().take_all(commands[..]);
	}
}
