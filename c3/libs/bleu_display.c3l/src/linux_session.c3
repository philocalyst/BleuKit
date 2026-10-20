<*
 The Linux Wayland session: the connection to the compositor, one record per output, and the
 published state built from those records. The records are filled by the listeners in
 `linux_outputs.c3` (wl_output with xdg-output: the read-only route) and `linux_wlr.c3` (heads of
 wlr-output-management: the route that can change the layout).
*>
module bleu::display::linux_wayland @feat(LINUX);
import bleu::display, bleu::display::wayland_convert, bleu::error, bleu::observe, bleu::stream, bleu::equal, bleu::ddc::edid, bleu::rt::fs;
import bleu::wl, bleu::wl::proto::wayland, bleu::wl::proto::xdg_output, bleu::wl::proto::wlr_output_management;
import std::collections::list, std::collections::maybe, std::core::string, std::io::path;


<* One advertised mode of an output. `object` is the wlr mode object; null for wl_output modes. *>
struct ModeRecord
{
	OutputRecord* owner;
	uint width;
	uint height;
	display::RefreshMilliHz refresh;
	bool preferred;
	bool current;
	wlr_output_management::ZwlrOutputModeV1* object;
}

<*
 Everything known about one output, filled from its events. Strings are owned by the record and
 copied into each published state, so a snapshot never points into a record.
*>
struct OutputRecord
{
	Session* session;
	Allocator allocator;
	uint global; // registry name of the wl_output; 0 for a wlr head
	wayland::WlOutput* wl_output;
	xdg_output::ZxdgOutputV1* xdg;
	wlr_output_management::ZwlrOutputHeadV1* head;
	String name;
	String description;
	String make;
	String model;
	String serial;
	int physical_width;
	int physical_height;
	int x;
	int y;
	bool enabled;
	display::Transform transform;
	double scale; // 0 when unknown
	bool has_adaptive;
	bool adaptive;
	bool has_logical_size;
	uint logical_width;
	uint logical_height;
	Maybe{ulong} fingerprint;
	List{ModeRecord*} modes;
}

<* The Linux session. Owns the client connection and every record; freed by `close`. *>
struct Session
{
	Allocator allocator;
	wl::Client* client;
	wl::ClientListener listener;
	String root;
	bool wlr;
	bool manager_gone; // the compositor finished the manager: no further configuration is possible
	wlr_output_management::ZwlrOutputManagerV1* manager;
	xdg_output::ZxdgOutputManagerV1* xdg_manager;
	List{OutputRecord*} outputs;
	uint serial;
	bool dirty;
	display::DisplayHub* hub;
	Pending* pending;
	display::RevertGuard guard;
	display::ApplyOp* guard_op;
	display::Config guard_config;
}

<*
 Connect the session to an initialised client: learn the globals, bind what the route needs, and
 wait until the compositor has sent its first state. The session takes ownership of the client and
 frees it in `close`.

 @param root : "Prefix for /sys, for tests; \"\" on a real system"
 @return? error::PROTOCOL, error::DISCONNECTED, error::BACKEND_FAILURE : "The compositor did not answer the initial requests"
*>
fn Session*? attach(Allocator allocator, wl::Client* client, String root)
{
	Session* s = alloc::new(allocator, Session);
	s.allocator = allocator;
	s.client = client;
	s.root = root.copy(allocator);
	s.outputs.init(allocator);
	s.listener = { .global_added = &on_global_added, .global_removed = &on_global_removed };
	if (catch err = bind_initial(s))
	{
		s.close();
		return err~;
	}
	return s;
}

// Learn the globals, bind the manager (wlr) or every output (wl_output), then wait for the first state.
fn void? bind_initial(Session* s)
{
	s.client.roundtrip()!;
	wl::Global[] globals = s.client.globals_view();
	sz wlr_index = -1;
	for (sz i = 0; i < globals.len; i++) {
		if (globals[i].interface_name == wlr_output_management::ZWLR_OUTPUT_MANAGER_V1.name) wlr_index = i;
	}
	for (sz i = 0; i < globals.len; i++) {
		if (globals[i].interface_name == xdg_output::ZXDG_OUTPUT_MANAGER_V1.name) {
			s.xdg_manager = (xdg_output::ZxdgOutputManagerV1*)s.client.bind(globals[i], xdg_output::ZXDG_OUTPUT_MANAGER_V1)!;
		}
	}
	if (wlr_index >= 0) {
		s.wlr = true;
		s.manager = (wlr_output_management::ZwlrOutputManagerV1*)s.client.bind(globals[wlr_index], wlr_output_management::ZWLR_OUTPUT_MANAGER_V1)!;
		s.manager.set_listener(&MANAGER_LISTENER, s);
	} else {
		for (sz i = 0; i < globals.len; i++) {
			if (globals[i].interface_name == wayland::WL_OUTPUT.name) add_output(s, globals[i])!;
		}
	}
	s.client.set_listener(&s.listener, s);
	s.client.roundtrip()!;
}

<* Release every object and free every record, then close the connection. *>
fn void Session.close(&self)
{
	while (self.outputs.len() > 0) remove_record(self, self.outputs.get(0));
	self.outputs.free();
	if (self.manager) self.manager.destroy();
	if (self.xdg_manager) {
		// The connection may already be gone; there is then nothing to destroy.
		if (catch self.xdg_manager.destroy()) {}
	}
	if (self.guard_op) self.guard_op.release();
	self.client.close();
	alloc::free(self.allocator, self.client);
	free_text(self.allocator, self.root);
	alloc::free(self.allocator, self);
}

// A global appeared after the first state: a new output on the wl_output route. Other globals do not matter here.
fn void on_global_added(void* context, wl::Global global)
{
	Session* s = (Session*)context;
	if (s.wlr || global.interface_name != wayland::WL_OUTPUT.name) return;
	if (catch add_output(s, global)) {
		// The output stays unknown until the compositor sends it again; nothing else can be done here.
	}
	s.dirty = true;
}

// A global went away: drop the output that was bound to it.
fn void on_global_removed(void* context, uint name)
{
	Session* s = (Session*)context;
	for (sz i = 0; i < s.outputs.len(); i++) {
		OutputRecord* rec = s.outputs.get(i);
		if (rec.global == name) {
			remove_record(s, rec);
			s.dirty = true;
			return;
		}
	}
}

// Bind one wl_output (and its xdg-output, when the compositor has the manager) and start tracking it.
fn void? add_output(Session* s, wl::Global global)
{
	OutputRecord* rec = new_record(s);
	rec.global = global.name;
	s.outputs.push(rec);
	rec.wl_output = (wayland::WlOutput*)s.client.bind(global, wayland::WL_OUTPUT)!;
	rec.wl_output.set_listener(&WL_OUTPUT_LISTENER, rec);
	if (s.xdg_manager) {
		rec.xdg = s.xdg_manager.get_xdg_output(rec.wl_output)!;
		rec.xdg.set_listener(&XDG_OUTPUT_LISTENER, rec);
	}
}

// A record with empty fields, owned by the session and not yet in its list.
fn OutputRecord* new_record(Session* s)
{
	OutputRecord* rec = alloc::new(s.allocator, OutputRecord);
	rec.session = s;
	rec.allocator = s.allocator;
	rec.modes.init(s.allocator);
	return rec;
}

// Drop a record: release its objects, free its modes and text, and take it out of the session.
fn void remove_record(Session* s, OutputRecord* rec)
{
	for (sz i = 0; i < s.outputs.len(); i++) {
		if (s.outputs.get(i) == rec) {
			s.outputs.remove_at(i);
			break;
		}
	}
	if (rec.wl_output) {
		if (catch rec.wl_output.release()) {}
	}
	if (rec.xdg) {
		if (catch rec.xdg.destroy()) {}
	}
	if (rec.head) {
		if (catch rec.head.release()) {}
	}
	for (sz i = 0; i < rec.modes.len(); i++) {
		ModeRecord* mode = rec.modes.get(i);
		if (mode.object) {
			if (catch mode.object.release()) {}
		}
		alloc::free(s.allocator, mode);
	}
	rec.modes.free();
	free_text(s.allocator, rec.name);
	free_text(s.allocator, rec.description);
	free_text(s.allocator, rec.make);
	free_text(s.allocator, rec.model);
	free_text(s.allocator, rec.serial);
	alloc::free(s.allocator, rec);
}

// Free a string the allocator handed out. A copy of an empty string is still an allocation.
fn void free_text(Allocator allocator, String text)
{
	if (text.ptr) alloc::free(allocator, text.ptr);
}

// Replace a record's string with a copy of `value`. Events give strings that are valid only during the call.
fn void set_text(OutputRecord* rec, String* field, String value)
{
	free_text(rec.allocator, *field);
	*field = value.copy(rec.allocator);
}

// The stable id of an output: its name when it has one, else the wl_output global it came from.
fn String record_id(OutputRecord* rec, Allocator allocator)
{
	if (rec.name.len > 0) return rec.name.copy(allocator);
	return string::tformat("wl-%d", (int)rec.global).copy(allocator);
}

<*
 Read the EDID of the connector called `name` from `<root>/sys/class/drm` and keep its fingerprint.
 Connector directories are named `cardN-<connector>`; the first matching EDID that parses wins.
 Nothing is kept when no EDID is readable, which is the normal case for virtual outputs.
*>
fn void refresh_fingerprint(OutputRecord* rec)
{
	rec.fingerprint = { };
	if (rec.name.len == 0) return;
	@pool()
	{
		String drm = string::tformat("%s/sys/class/drm", rec.session.root);
		if (try entries = fs::list_dir(tmem, drm)) {
			foreach (entry : entries) {
				String dir_name = (String)entry;
				if (!dir_name.ends_with(string::tformat("-%s", rec.name))) continue;
				String bytes = fs::read_file(tmem, string::tformat("%s/%s/edid", drm, dir_name)) ?? "";
				if (bytes.len == 0) continue;
				if (try identity = edid::parse((char[])bytes, tmem)) {
					rec.fingerprint.set(identity.fingerprint());
					return;
				}
			}
		}
	};
}

// The published state of the session, allocated in `allocator`.
fn display::State build_state(Session* s, Allocator allocator)
{
	display::Output[] outputs = alloc::new_array(allocator, display::Output, s.outputs.len());
	for (sz i = 0; i < s.outputs.len(); i++) {
		outputs[i] = describe(s.outputs.get(i), allocator);
	}
	return { .outputs = outputs, .serial = s.serial };
}

// One record as an output, copying every string into `allocator`.
fn display::Output describe(OutputRecord* rec, Allocator allocator)
{
	display::Output out = {
		.id = record_id(rec, allocator),
		.name = rec.name.copy(allocator),
		.make = rec.make.copy(allocator),
		.model = rec.model.copy(allocator),
		.serial = rec.serial.copy(allocator),
		.description = rec.description.copy(allocator),
		.enabled = rec.enabled,
		.x = rec.x,
		.y = rec.y,
		.transform = rec.transform,
	};
	if (rec.physical_width > 0) out.width_mm.set((display::Millimetre)rec.physical_width);
	if (rec.physical_height > 0) out.height_mm.set((display::Millimetre)rec.physical_height);
	out.modes = alloc::new_array(allocator, display::Mode, rec.modes.len());
	for (sz i = 0; i < rec.modes.len(); i++) {
		ModeRecord* mode = rec.modes.get(i);
		out.modes[i] = { .width = mode.width, .height = mode.height, .refresh = mode.refresh, .preferred = mode.preferred };
		if (mode.current && rec.enabled) out.current.set(out.modes[i]);
	}
	double scale = rec.scale;
	if (out.current.has_value && rec.has_logical_size) {
		double derived = display::scale_from_logical_width(out.current.value, rec.transform, rec.logical_width);
		if (derived > 0.0) scale = derived;
	}
	if (scale > 0.0) out.scale.set(scale);
	if (rec.has_adaptive) out.adaptive_sync.set(rec.adaptive);
	if (rec.fingerprint.has_value) out.edid_fingerprint.set(rec.fingerprint.value);
	return out;
}

// The published state of the session: a snapshot built from the records, then published with its events.
fn void publish(Session* s)
{
	Snapshot{display::State}* snapshot = s.hub.begin();
	snapshot.value = build_state(s, snapshot.allocator());
	display::publish_snapshot(s.hub, snapshot);
}
