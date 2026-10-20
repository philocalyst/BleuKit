<*
 The wlr-output-management route: the compositor announces one head per output and one mode per
 supported mode; a configuration is tested, then applied, with the serial rule the protocol sets.
 The revert of a change nobody confirmed is done here, by re-applying the layout that was current
 before the change (the protocol has no revert of its own).
*>
module bleu::display::linux_wayland @feat(LINUX);
import bleu::display, bleu::display::wayland_convert, bleu::error, bleu::wl::wire, bleu::wl::proto::wayland, bleu::wl::proto::wlr_output_management;
import std::time, std::time::clock, std::collections::maybe, bleu::observe, bleu::operation;

<* How long the compositor may take to answer one test or apply. *>
const Duration CONFIG_TIMEOUT = (Duration)5_000_000;

const wlr_output_management::ZwlrOutputManagerV1Listener MANAGER_LISTENER = {
	.head = &on_head,
	.done = &on_manager_done,
	.finished = &on_manager_finished,
};

const wlr_output_management::ZwlrOutputHeadV1Listener HEAD_LISTENER = {
	.name = &on_head_name,
	.description = &on_head_description,
	.physical_size = &on_head_physical_size,
	.mode = &on_head_mode,
	.enabled = &on_head_enabled,
	.current_mode = &on_head_current_mode,
	.position = &on_head_position,
	.transform = &on_head_transform,
	.scale = &on_head_scale,
	.finished = &on_head_finished,
	.make = &on_head_make,
	.model = &on_head_model,
	.serial_number = &on_head_serial,
	.adaptive_sync = &on_head_adaptive_sync,
};

const wlr_output_management::ZwlrOutputModeV1Listener MODE_LISTENER = {
	.size = &on_mode_size,
	.refresh = &on_mode_refresh,
	.preferred = &on_mode_preferred,
	.finished = &on_mode_finished,
};

const wlr_output_management::ZwlrOutputConfigurationV1Listener CONFIG_LISTENER = {
	.succeeded = &on_config_succeeded,
	.failed = &on_config_failed,
	.cancelled = &on_config_cancelled,
};

// How a configuration object ended: its one event, or PENDING while it is still in flight.
enum ConfigResult : char
{
	PENDING,
	SUCCEEDED,
	FAILED,
	CANCELLED,
}

<*
 One request in flight on the wlr route: a test, then (unless only testing) an apply. A cancelled
 attempt is retried with the newer serial; the compositor's answer arrives through the listeners
 and `advance` acts on it.
*>
struct Pending
{
	Session* session;
	display::ApplyOp* op; // completed by this request; this request holds one reference
	display::ApplyOp* arena_owner; // keeps `config` alive for a revert; null when `op` owns it
	display::Config config;
	ApplyMode mode;
	Duration revert_after;
	bool is_revert;
	bool testing;
	uint serial; // the serial the current attempt was created with
	bool retried;
	bool waiting_serial;
	Clock deadline;
	ConfigResult result;
	wlr_output_management::ZwlrOutputConfigurationV1* object;
	display::ApplyOp* revert_op; // holds the previous layout when this request arms a revert
	display::Config revert_config;
}

// The head events: each updates its record. The manager's `done` ends a batch.

fn void on_head(void* context, wlr_output_management::ZwlrOutputManagerV1* target, wlr_output_management::ZwlrOutputHeadV1* head)
{
	Session* s = (Session*)context;
	OutputRecord* rec = new_record(s);
	rec.head = head;
	s.outputs.push(rec);
	head.set_listener(&HEAD_LISTENER, rec);
}

fn void on_manager_done(void* context, wlr_output_management::ZwlrOutputManagerV1* target, uint serial)
{
	Session* s = (Session*)context;
	s.serial = serial;
	s.dirty = true;
}

fn void on_manager_finished(void* context, wlr_output_management::ZwlrOutputManagerV1* target)
{
	Session* s = (Session*)context;
	s.manager_gone = true;
	s.dirty = true;
}

fn void on_head_name(void* context, wlr_output_management::ZwlrOutputHeadV1* target, String name)
{
	OutputRecord* rec = (OutputRecord*)context;
	set_text(rec, &rec.name, name);
	refresh_fingerprint(rec);
}

fn void on_head_description(void* context, wlr_output_management::ZwlrOutputHeadV1* target, String description)
{
	OutputRecord* rec = (OutputRecord*)context;
	set_text(rec, &rec.description, description);
}

fn void on_head_physical_size(void* context, wlr_output_management::ZwlrOutputHeadV1* target, int width, int height)
{
	OutputRecord* rec = (OutputRecord*)context;
	rec.physical_width = width;
	rec.physical_height = height;
}

fn void on_head_make(void* context, wlr_output_management::ZwlrOutputHeadV1* target, String make)
{
	OutputRecord* rec = (OutputRecord*)context;
	set_text(rec, &rec.make, make);
}

fn void on_head_model(void* context, wlr_output_management::ZwlrOutputHeadV1* target, String model)
{
	OutputRecord* rec = (OutputRecord*)context;
	set_text(rec, &rec.model, model);
}

fn void on_head_serial(void* context, wlr_output_management::ZwlrOutputHeadV1* target, String serial_number)
{
	OutputRecord* rec = (OutputRecord*)context;
	set_text(rec, &rec.serial, serial_number);
}

// A new mode of this head: a record for it, listening for its size and refresh.
fn void on_head_mode(void* context, wlr_output_management::ZwlrOutputHeadV1* target, wlr_output_management::ZwlrOutputModeV1* mode)
{
	OutputRecord* rec = (OutputRecord*)context;
	ModeRecord* record = new_mode(rec);
	record.object = mode;
	mode.set_listener(&MODE_LISTENER, record);
}

fn void on_head_enabled(void* context, wlr_output_management::ZwlrOutputHeadV1* target, int enabled)
{
	OutputRecord* rec = (OutputRecord*)context;
	rec.enabled = enabled != 0;
	if (!rec.enabled) clear_current(rec);
}

fn void on_head_current_mode(void* context, wlr_output_management::ZwlrOutputHeadV1* target, wlr_output_management::ZwlrOutputModeV1* mode)
{
	OutputRecord* rec = (OutputRecord*)context;
	clear_current(rec);
	for (sz i = 0; i < rec.modes.len(); i++) {
		ModeRecord* record = rec.modes.get(i);
		if (record.object == mode) record.current = true;
	}
}

fn void on_head_position(void* context, wlr_output_management::ZwlrOutputHeadV1* target, int x, int y)
{
	OutputRecord* rec = (OutputRecord*)context;
	rec.x = x;
	rec.y = y;
}

fn void on_head_transform(void* context, wlr_output_management::ZwlrOutputHeadV1* target, wayland::WlOutputTransform transform)
{
	OutputRecord* rec = (OutputRecord*)context;
	rec.transform = wayland_convert::transform_from_wire((uint)transform);
}

fn void on_head_scale(void* context, wlr_output_management::ZwlrOutputHeadV1* target, wire::Fixed scale)
{
	OutputRecord* rec = (OutputRecord*)context;
	rec.scale = scale.to_double();
}

fn void on_head_adaptive_sync(void* context, wlr_output_management::ZwlrOutputHeadV1* target, wlr_output_management::ZwlrOutputHeadV1AdaptiveSyncState state)
{
	OutputRecord* rec = (OutputRecord*)context;
	rec.has_adaptive = true;
	rec.adaptive = state == wlr_output_management::ZwlrOutputHeadV1AdaptiveSyncState.ENABLED;
}

// The head is gone: release it and everything it owned.
fn void on_head_finished(void* context, wlr_output_management::ZwlrOutputHeadV1* target)
{
	OutputRecord* rec = (OutputRecord*)context;
	Session* s = rec.session;
	remove_record(s, rec); // releases the head object, as the protocol asks after `finished`
	s.dirty = true;
}

fn void on_mode_size(void* context, wlr_output_management::ZwlrOutputModeV1* target, int width, int height)
{
	ModeRecord* mode = (ModeRecord*)context;
	mode.width = (uint)width;
	mode.height = (uint)height;
}

fn void on_mode_refresh(void* context, wlr_output_management::ZwlrOutputModeV1* target, int refresh)
{
	ModeRecord* mode = (ModeRecord*)context;
	mode.refresh = wayland_convert::refresh_from_wire(refresh);
}

fn void on_mode_preferred(void* context, wlr_output_management::ZwlrOutputModeV1* target)
{
	ModeRecord* mode = (ModeRecord*)context;
	mode.preferred = true;
}

// The mode is gone: take it out of its head and release it.
fn void on_mode_finished(void* context, wlr_output_management::ZwlrOutputModeV1* target)
{
	ModeRecord* mode = (ModeRecord*)context;
	OutputRecord* rec = mode.owner;
	for (sz i = 0; i < rec.modes.len(); i++) {
		if (rec.modes.get(i) == mode) {
			rec.modes.remove_at(i);
			break;
		}
	}
	if (mode.object) {
		if (catch mode.object.release()) {}
	}
	alloc::free(rec.allocator, mode);
	rec.session.dirty = true;
}

// The configuration object reports its one outcome; `advance` acts on it on the worker.
fn void on_config_succeeded(void* context, wlr_output_management::ZwlrOutputConfigurationV1* target)
{
	Pending* p = (Pending*)context;
	p.result = SUCCEEDED;
}

fn void on_config_failed(void* context, wlr_output_management::ZwlrOutputConfigurationV1* target)
{
	Pending* p = (Pending*)context;
	p.result = FAILED;
}

fn void on_config_cancelled(void* context, wlr_output_management::ZwlrOutputConfigurationV1* target)
{
	Pending* p = (Pending*)context;
	p.result = CANCELLED;
}

// Clear the current flag of every mode of a record.
fn void clear_current(OutputRecord* rec)
{
	for (sz i = 0; i < rec.modes.len(); i++) rec.modes.get(i).current = false;
}
