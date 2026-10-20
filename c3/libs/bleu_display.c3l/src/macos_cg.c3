<*
 The macOS backend: CoreGraphics. Displays and their modes are read with public calls. A layout
 change is one CoreGraphics transaction: begin, configure each display, then complete it for the
 session or permanently, or cancel it for a test. Changes CoreGraphics cannot make publicly (rotation,
 disabling a display) are refused with UNSUPPORTED, not ignored.

 Compiled and type-checked for macOS; not run (there is no Mac in the environment this was built in).
*>
module bleu::display::coregraphics @feat(DARWIN);
import bleu::display, bleu::display::macos_native, bleu::cf, bleu::error, bleu::availability, bleu::observe, bleu::operation, bleu::rt::poller, bleu::rt::worker, bleu::rt::mailbox;
import std::time, std::time::clock, std::math, std::core::string, std::collections::maybe;

<* How many displays one read may list. Further displays are not reported. *>
const sz MAX_DISPLAYS = 32;

<* Two scales are the same when they differ by less than this (a mode's scale is a ratio of integers). *>
const double SCALE_TOLERANCE = 0.01;

const Driver DRIVER = {
	.info = { "coregraphics", "CoreGraphics display list and configuration transactions", 20 },
	.id = COREGRAPHICS,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

// The backend's state: the mailbox the reconfiguration callback posts to, and the rollback point.
struct Backend
{
	Allocator allocator;
	DisplayHub* hub;
	Mailbox{Command}* mailbox;
	bool dirty;
	RevertGuard guard;
	ApplyOp* guard_op;
	Config guard_config;
}

// CoreGraphics is part of every macOS session; the real check is that a display is attached (in `create`).
fn bool probe(Options* options) => true;

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	DirectDisplayId[MAX_DISPLAYS] displays;
	if (active_displays(displays[..]) == 0) return error::raise(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "no display is active")~;
	fill_capabilities(capabilities);
	return alloc::new(allocator, Backend, { .allocator = allocator });
}

fn void destroy(Allocator allocator, void* state)
{
	Backend* backend = (Backend*)state;
	if (backend.guard_op) backend.guard_op.release();
	alloc::free(allocator, backend);
}

// What this backend can and cannot do; DEGRADED says what the caveat is.
fn void fill_capabilities(Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	capabilities.set(SET_SCALE, { .reason = availability::Reason.DEGRADED, .note = "the scale follows the mode: a scale is accepted only when a mode with it exists" });
	capabilities.set(TEST_ONLY, { .reason = availability::Reason.DEGRADED, .note = "CoreGraphics checks each configure call as it is made; the whole layout is not tested before it is completed" });
	capabilities.set(SET_TRANSFORM, availability::no(availability::Reason.UNSUPPORTED_BACKEND, "rotation needs a private CoreGraphics call; not in this version"));
	capabilities.set(SET_ENABLED, availability::no(availability::Reason.UNSUPPORTED_BACKEND, "disabling a display needs a private CoreGraphics call; not in this version"));
	capabilities.set(SET_MIRROR, availability::no(availability::Reason.UNSUPPORTED_BACKEND, "mirroring is read but not written in this version"));
	capabilities.set(SET_HDR, availability::no(availability::Reason.UNSUPPORTED_BACKEND, "HDR is not read or written on macOS in this version"));
	capabilities.set(SET_COLOUR_DEPTH, availability::no(availability::Reason.UNSUPPORTED_BACKEND, "colour depth is not read or written on macOS in this version"));
	capabilities.set(SET_ADAPTIVE_SYNC, availability::no(availability::Reason.UNSUPPORTED_BACKEND, "adaptive sync is not read or written on macOS in this version"));
}

// The active displays, into `buffer`. Returns how many there are.
fn sz active_displays(DirectDisplayId[] buffer)
{
	uint count = 0;
	CgError code = cg_active_displays((uint)buffer.len, buffer.ptr, &count);
	if (code != CG_SUCCESS) return 0;
	return (sz)count;
}

// A display number as text, in `allocator`.
fn String number_text(uint value, Allocator allocator)
{
	String text;
	@pool()
	{
		text = string::tformat("%d", (int)value).copy(allocator);
	};
	return text;
}

// The display number an output id names. Output ids are display numbers.
fn DirectDisplayId? parse_display(String id)
{
	if (id.len == 0) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "empty output id")~;
	DirectDisplayId value = 0;
	for (sz i = 0; i < id.len; i++) {
		char c = id[i];
		if (c < '0' || c > '9') return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "output id %s is not a display number", id)~;
		value = value * 10 + (uint)(c - '0');
	}
	return value;
}

// A refresh rate in millihertz from CoreGraphics' hertz; 0 when CoreGraphics does not know it.
fn display::RefreshMilliHz refresh_of(double hertz) @inline => hertz > 0.0 ? (display::RefreshMilliHz)math::round(hertz * 1000.0) : 0;

// The mode a CoreGraphics mode object describes, at pixel size.
fn display::Mode mode_of(void* mode)
{
	return {
		.width = (uint)cg_mode_pixel_width(mode),
		.height = (uint)cg_mode_pixel_height(mode),
		.refresh = refresh_of(cg_mode_refresh_rate(mode)),
	};
}

// The scale a mode implies: pixels over points.
fn double scale_of(void* mode)
{
	usz points = cg_mode_width(mode);
	if (points == 0) return 0.0;
	return (double)cg_mode_pixel_width(mode) / (double)points;
}

// Every mode of a display, duplicates of the same pixel size and refresh left out, in `allocator`.
fn display::Mode[] modes_of(DirectDisplayId display, Allocator allocator)
{
	void* options = duplicate_mode_options();
	defer cf_release(options);
	void* all = cg_display_copy_all_modes(display, options);
	if (!all) return { };
	defer cf_release(all);
	display::Mode[] modes = alloc::new_array(allocator, display::Mode, cf_array_count(all));
	sz count = 0;
	for (sz i = 0; i < cf_array_count(all); i++) {
		display::Mode mode = mode_of(cf_array_value_at(all, i));
		bool seen = false;
		for (sz j = 0; j < count; j++) {
			if (modes[j].width == mode.width && modes[j].height == mode.height && modes[j].refresh == mode.refresh) seen = true;
		}
		if (!seen) modes[count++] = mode;
	}
	return modes[0:count];
}

// One display as an output: where it sits, its current mode, the modes it offers, and what it mirrors.
fn display::Output describe(DirectDisplayId display, DirectDisplayId main, Allocator allocator)
{
	display::Output out = {
		.id = number_text(display, allocator),
		.name = string::tformat("Display %d", (int)display).copy(allocator),
		.enabled = true,
	};
	CgRect bounds = cg_display_bounds(display);
	out.x = (int)math::round(bounds.origin.x);
	out.y = (int)math::round(bounds.origin.y);
	out.primary.set(display == main);
	CgSize millimetres = cg_display_screen_size(display);
	if (millimetres.width > 0.0) out.width_mm.set((display::Millimetre)math::round(millimetres.width));
	if (millimetres.height > 0.0) out.height_mm.set((display::Millimetre)math::round(millimetres.height));
	out.transform = transform_of(cg_display_rotation(display));
	out.modes = modes_of(display, allocator);
	void* current = cg_display_copy_mode(display);
	if (current) {
		out.current.set(mode_of(current));
		double scale = scale_of(current);
		if (scale > 0.0) out.scale.set(scale);
		cf_release(current);
	}
	DirectDisplayId master = cg_display_mirrors(display);
	if (master != 0) out.mirror_of.set(number_text(master, allocator));
	return out;
}

// The rotation in degrees, as one of the four quarter turns; anything else is the nearest.
fn display::Transform transform_of(double degrees)
{
	int quarter = ((int)math::round(degrees) / 90) % 4;
	if (quarter < 0) quarter += 4;
	return (display::Transform)(quarter);
}

// The state of every active display, allocated in `allocator`.
fn display::State read_state(Allocator allocator)
{
	DirectDisplayId[MAX_DISPLAYS] displays;
	sz count = active_displays(displays[..]);
	DirectDisplayId main = cg_main_display();
	display::Output[] outputs = alloc::new_array(allocator, display::Output, count);
	for (sz i = 0; i < count; i++) outputs[i] = describe(displays[i], main, allocator);
	return { .outputs = outputs };
}

// Read the state and publish it, with events for what changed.
fn void publish(Backend* b)
{
	Snapshot{display::State}* snapshot = b.hub.begin();
	display::State? state = read_state(snapshot.allocator());
	if (catch err = state) {
		snapshot.value = { };
	} else {
		snapshot.value = state;
	}
	display::publish_snapshot(b.hub, snapshot);
}

fn void run(void* state, DisplayHub* hub, Host{Command}* host)
{
	Backend* b = (Backend*)state;
	b.hub = hub;
	b.mailbox = host.mailbox();
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 0)) return;
	defer poller.free();
	if (cg_register_reconfiguration(&on_reconfigure, b) != CG_SUCCESS) return;
	defer unregister(b);
	publish(b);
	Command[8] commands;
	while (!host.stopping()) {
		if (catch poller.wait(b.guard.remaining(clock::now()))) {
			// TIMEOUT is the rollback falling due, or nothing happening.
		}
		usz count = host.mailbox().take_all(commands[..]);
		for (usz i = 0; i < count; i++) handle(b, commands[i], clock::now());
		if (b.guard.due(clock::now())) revert(b, clock::now());
		if (b.dirty) {
			b.dirty = false;
			publish(b);
		}
	}
	shutdown(b, host);
}

// CoreGraphics reports a change at its start (flagged) and at its end: only the end is worth a read.
fn void on_reconfigure(DirectDisplayId display, uint flags, void* user)
{
	if ((flags & CG_BEGIN_CONFIGURATION_FLAG) != 0) return;
	Backend* b = (Backend*)user;
	if (catch b.mailbox.post(REFRESH)) {
		// The mailbox is closed when the service stops; there is nothing left to tell.
	}
}

fn void unregister(Backend* b)
{
	cg_remove_reconfiguration(&on_reconfigure, b);
}

fn void handle(Backend* b, Command command, Clock now)
{
	switch (command.kind) {
		case REFRESH: b.dirty = true;
		case CONFIRM: confirm(b, now);
		case APPLY: apply_now(b, command, now);
	}
}

// Keep the change waiting for confirmation: forget the rollback point.
fn void confirm(Backend* b, Clock now)
{
	if (b.guard.confirm(now)) {
		if (b.guard_op) b.guard_op.release();
		b.guard_op = null;
	}
}

// Complete a command with an error.
fn void reject(ApplyOp* op, fault failure)
{
	op.fail(failure);
	op.release();
}

// Check the config against the state: no disabling, no rotation, and it must name every display.
// `changed` says whether anything differs.
fn void? check_request(Backend* b, Config config, bool* changed)
{
	@pool()
	{
		display::State state = read_state(tmem);
		display::validate_config(state.outputs, config)!;
		for (sz i = 0; i < config.outputs.len; i++) {
			display::Maybe{sz} index = display::index_of_output(state.outputs, config.outputs[i].output_id);
			display::OutputDelta delta = display::delta_of(state.outputs[index.value], config.outputs[i]);
			if (delta.enabled) return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "enabling or disabling a display is not in this macOS version")~;
			if (config.outputs[i].transform != state.outputs[index.value].transform) {
				return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "rotating a display is not in this macOS version")~;
			}
		}
		*changed = display::config_changes(state, config);
	};
}

// The layout as it is now, copied into `allocator`: the point a rollback returns to.
fn display::Config previous_config(Backend* b, Allocator allocator)
{
	display::Config result;
	@pool()
	{
		result = display::config_from_state(read_state(tmem), allocator);
	};
	return result;
}

// Carry out one apply: the transaction, then the rollback point when it is asked for.
fn void apply_now(Backend* b, Command command, Clock now)
{
	ApplyOp* op = command.op;
	op.start();
	bool changed = false;
	if (catch err = check_request(b, command.config, &changed)) {
		reject(op, err);
		return;
	}
	if (!changed) {
		op.succeed({ .mode = command.mode, .live = command.mode != TEST_ONLY, .revert_armed = false });
		op.release();
		return;
	}
	ApplyOp* holder = null;
	display::Config previous;
	if (command.mode == APPLY_WITH_REVERT) {
		holder = operation::begin(b.allocator);
		previous = previous_config(b, holder.allocator());
	}
	if (catch err = run_transaction(command.config, command.mode == TEST_ONLY, command.config.persistent)) {
		if (holder) holder.release();
		reject(op, err);
		return;
	}
	if (command.mode == APPLY_WITH_REVERT) {
		if (b.guard_op) b.guard_op.release();
		b.guard_op = holder;
		b.guard_config = previous;
		b.guard.arm(now, command.revert_after);
	} else if (command.mode == APPLY) {
		b.guard.disarm();
		if (b.guard_op) b.guard_op.release();
		b.guard_op = null;
	}
	op.succeed({ .mode = command.mode, .live = command.mode != TEST_ONLY, .revert_armed = command.mode == APPLY_WITH_REVERT });
	op.release();
	b.dirty = true;
}

<*
 One CoreGraphics transaction: begin, configure every display, then complete it (for the session, or
 permanently) or cancel it (a test). A failure at any step cancels the whole transaction.
*>
fn void? run_transaction(Config config, bool test_only, bool persistent)
{
	ConfigRef transaction = null;
	if (cg_begin_configuration(&transaction) != CG_SUCCESS) {
		return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, 0, "CGBeginDisplayConfiguration failed")~;
	}
	if (catch err = configure_all(transaction, config)) {
		cg_cancel_configuration(transaction);
		return err~;
	}
	if (test_only) {
		cg_cancel_configuration(transaction);
		return;
	}
	uint option = persistent ? CONFIGURE_PERMANENTLY : CONFIGURE_FOR_SESSION;
	if (cg_complete_configuration(transaction, option) != CG_SUCCESS) {
		return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, 0, "CGCompleteDisplayConfiguration failed")~;
	}
}

// Configure every display of the config inside the transaction.
fn void? configure_all(ConfigRef transaction, Config config)
{
	for (sz i = 0; i < config.outputs.len; i++) {
		display::OutputChange change = config.outputs[i];
		DirectDisplayId display = parse_display(change.output_id)!;
		configure_display(transaction, display, change)!;
	}
}

// The mode that matches the change (the scale too, when the change names one), then the origin.
fn void? configure_display(ConfigRef transaction, DirectDisplayId display, display::OutputChange change)
{
	void* options = duplicate_mode_options();
	defer cf_release(options);
	void* all = cg_display_copy_all_modes(display, options);
	if (!all) return error::raise(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "display %d lists no modes", (int)display)~;
	defer cf_release(all);
	void* found = null;
	for (sz i = 0; i < cf_array_count(all) && !found; i++) {
		void* candidate = cf_array_value_at(all, i);
		display::Mode mode = mode_of(candidate);
		if (mode.width != change.mode.width || mode.height != change.mode.height) continue;
		if (change.mode.refresh != 0 && !display::refresh_matches(mode.refresh, change.mode.refresh, display::DEFAULT_REFRESH_TOLERANCE)) continue;
		if (change.scale.has_value && math::abs(scale_of(candidate) - change.scale.value) >= SCALE_TOLERANCE) continue;
		found = candidate;
	}
	if (!found) {
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "display %d has no mode %dx%d that matches", (int)display, (int)change.mode.width, (int)change.mode.height)~;
	}
	if (cg_configure_mode(transaction, display, found, null) != CG_SUCCESS) {
		return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, 0, "CGConfigureDisplayWithDisplayMode refused display %d", (int)display)~;
	}
	if (cg_configure_origin(transaction, display, change.x, change.y) != CG_SUCCESS) {
		return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, 0, "CGConfigureDisplayOrigin refused display %d", (int)display)~;
	}
}

// Roll back the change nobody confirmed: apply the layout that was current before it.
fn void revert(Backend* b, Clock now)
{
	b.guard.disarm();
	ApplyOp* holder = b.guard_op;
	display::Config previous = b.guard_config;
	b.guard_op = null;
	if (catch err = run_transaction(previous, false, false)) {
		// The displays keep the change; the publish below reports what the system now has.
	}
	if (holder) holder.release();
	display::emit(b.hub, display::EventKind.REVERTED, "");
	b.dirty = true;
}

// Stop: a rollback still armed is applied now (the shell is going away); queued commands are refused.
fn void shutdown(Backend* b, Host{Command}* host)
{
	if (b.guard.armed) revert(b, clock::now());
	Command[8] commands;
	usz count = host.mailbox().take_all(commands[..]);
	while (count > 0) {
		for (usz i = 0; i < count; i++) {
			if (commands[i].kind == APPLY) reject(commands[i].op, error::raise(error::DISCONNECTED, error::Domain.INTERNAL, 0, "the display service stopped"));
		}
		count = host.mailbox().take_all(commands[..]);
	}
}
