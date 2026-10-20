<*
 Carrying out a configuration on the wlr route: validate it against the current state, test it,
 apply it, and roll it back when a confirmation does not arrive in time. Everything here runs on
 the worker thread; the compositor's answers arrive through the listeners of `linux_wlr.c3`.
*>
module bleu::display::linux_wayland @feat(LINUX);
import bleu::display, bleu::display::wayland_convert, bleu::error, bleu::wl::wire, bleu::wl::proto::wayland, bleu::wl::proto::wlr_output_management;
import bleu::observe, bleu::operation, std::time, std::time::clock, std::collections::maybe, std::core::string;

<* The monotonic instant `timeout` after `now`. *>
fn Clock clock_after(Clock now, Duration timeout) @inline => (Clock)((ulong)now + (ulong)timeout * 1000);

<*
 Start a command on the wlr route. The command's reference to `op` moves into the request, which
 completes it exactly once.
*>
fn void begin_apply(Session* s, Command command, Clock now)
{
	display::ApplyOp* op = command.op;
	op.start();
	if (!s.wlr) {
		reject(op, error::raise(error::UNSUPPORTED, error::Domain.WAYLAND, 0, "the compositor offers no wlr-output-management"));
		return;
	}
	if (s.manager_gone) {
		reject(op, error::raise(error::DISCONNECTED, error::Domain.WAYLAND, 0, "the compositor ended wlr-output-management"));
		return;
	}
	if (s.pending != null) {
		reject(op, error::raise(error::BUSY, error::Domain.WAYLAND, 0, "another configuration is still being applied"));
		return;
	}
	bool changed = false;
	if (catch err = check_request(s, command.config, &changed)) {
		reject(op, err);
		return;
	}
	if (!changed) {
		op.succeed({ .mode = command.mode, .live = command.mode != TEST_ONLY, .revert_armed = false });
		op.release();
		return;
	}
	Pending* p = alloc::new(s.allocator, Pending);
	p.session = s;
	p.op = op;
	p.config = command.config;
	p.mode = command.mode;
	p.revert_after = command.revert_after;
	p.testing = true;
	p.result = PENDING;
	if (command.mode == APPLY_WITH_REVERT) {
		p.revert_op = operation::begin(s.allocator);
		p.revert_config = previous_config(s, p.revert_op.allocator());
	}
	s.pending = p;
	if (catch err = start_attempt(p)) finish_failed(p, err);
}

// Complete a command that never started.
fn void reject(display::ApplyOp* op, fault failure)
{
	op.fail(failure);
	op.release();
}

<*
 Validate `config` against the current state, and report whether it changes anything. The state
 is built in temporary memory and dropped before returning.
*>
fn void? check_request(Session* s, display::Config config, bool* changed)
{
	@pool()
	{
		display::State state = build_state(s, tmem);
		display::validate_config(state.outputs, config)!;
		*changed = display::config_changes(state, config);
	};
}

// The layout as it is now, in `allocator`: the point a rollback returns to.
fn display::Config previous_config(Session* s, Allocator allocator)
{
	display::Config result;
	@pool()
	{
		display::State state = build_state(s, tmem);
		result = display::config_from_state(state, allocator);
	};
	return result;
}

// Make one attempt: a configuration object with the desired state of every head, then test or apply.
fn void? start_attempt(Pending* p)
{
	Session* s = p.session;
	p.serial = s.serial;
	p.result = PENDING;
	p.waiting_serial = false;
	p.object = s.manager.create_configuration(p.serial)!;
	p.object.set_listener(&CONFIG_LISTENER, p);
	for (sz i = 0; i < s.outputs.len(); i++) {
		configure_head(p, s.outputs.get(i))!;
	}
	if (p.testing) {
		p.object.test()!;
	} else {
		p.object.apply()!;
	}
	p.deadline = clock_after(clock::now(), CONFIG_TIMEOUT);
}

// Describe one head in the attempt: disabled, or enabled with its mode, place, transform and scale.
fn void? configure_head(Pending* p, OutputRecord* rec)
{
	sz index = change_index(p.config, rec);
	display::OutputChange change = p.config.outputs[index];
	if (!change.enabled) {
		p.object.disable_head(rec.head)!;
		return;
	}
	wlr_output_management::ZwlrOutputConfigurationHeadV1* head = p.object.enable_head(rec.head)!;
	set_head_mode(head, rec, change.mode)!;
	head.set_position(change.x, change.y)!;
	head.set_transform((wayland::WlOutputTransform)wayland_convert::transform_to_wire(change.transform))!;
	if (change.scale.has_value) head.set_scale(wire::fixed_from_double(change.scale.value))!;
}

// The index of the change for this record's output. The validation guarantees it exists.
fn sz change_index(display::Config config, OutputRecord* rec)
{
	sz found = 0;
	@pool()
	{
		String id = record_id(rec, tmem);
		for (sz i = 0; i < config.outputs.len; i++) {
			if (config.outputs[i].output_id == id) {
				found = i;
				break;
			}
		}
	};
	return found;
}

// Use the advertised mode that matches `wanted`; a mode the head does not advertise is set as custom.
fn void? set_head_mode(wlr_output_management::ZwlrOutputConfigurationHeadV1* head, OutputRecord* rec, display::Mode wanted)
{
	sz found = -1;
	@pool()
	{
		display::Mode[] advertised = alloc::new_array(tmem, display::Mode, rec.modes.len());
		for (sz i = 0; i < rec.modes.len(); i++) {
			ModeRecord* mode = rec.modes.get(i);
			advertised[i] = { .width = mode.width, .height = mode.height, .refresh = mode.refresh, .preferred = mode.preferred };
		}
		Maybe{sz} hit = display::find_mode(advertised, wanted, display::DEFAULT_REFRESH_TOLERANCE);
		if (hit.has_value) found = hit.value;
	};
	if (found >= 0) {
		head.set_mode(rec.modes.get(found).object)!;
		return;
	}
	head.set_custom_mode((int)wanted.width, (int)wanted.height, (int)wanted.refresh)!;
}

// The compositor answered; decide what the answer means for the request and act on it.
fn void advance(Session* s, Clock now)
{
	Pending* p = s.pending;
	if (p == null) {
		if (s.guard.due(now)) start_revert(s, now);
		return;
	}
	if (p.result == PENDING) {
		if (p.waiting_serial && s.serial != p.serial) {
			if (catch err = start_attempt(p)) finish_failed(p, err);
		} else if (now > p.deadline) {
			finish_failed(p, TIMEOUT);
		}
		return;
	}
	ConfigResult result = p.result;
	p.result = PENDING;
	if (p.object) {
		if (catch p.object.destroy()) {}
		p.object = null;
	}
	switch (result) {
		case PENDING: return;
		case SUCCEEDED: on_succeeded(p, now);
		case FAILED: finish_failed(p, error::raise(error::INVALID_ARGUMENT, error::Domain.WAYLAND, 0, "the compositor refused the layout"));
		case CANCELLED: on_cancelled(p, now);
	}
}

// A test or an apply was accepted.
fn void on_succeeded(Pending* p, Clock now)
{
	if (p.testing) {
		if (p.mode == TEST_ONLY) {
			finish_applied(p, now, false);
			return;
		}
		p.testing = false;
		if (catch err = start_attempt(p)) finish_failed(p, err);
		return;
	}
	finish_applied(p, now, true);
}

// The layout moved under the attempt. Retry with the new serial, or wait for it, or give up.
fn void on_cancelled(Pending* p, Clock now)
{
	Session* s = p.session;
	switch (wayland_convert::after_cancel(p.retried, p.serial, s.serial)) {
		case RETRY_NOW:
			p.retried = true;
			if (catch err = start_attempt(p)) finish_failed(p, err);
		case WAIT_FOR_SERIAL:
			p.retried = true;
			p.waiting_serial = true;
		case GIVE_UP:
			finish_failed(p, error::raise(
				error::INVALID_STATE,
				error::Domain.WAYLAND,
				0,
				"the outputs changed while the layout was applied: read the state and apply again"
			));
	}
}

// Complete the request. `live` says whether the layout is in effect now (an apply, not a test).
fn void finish_applied(Pending* p, Clock now, bool live)
{
	Session* s = p.session;
	if (p.is_revert) {
		emit(s.hub, display::EventKind.REVERTED, "");
		p.op.succeed({ .mode = APPLY, .live = true, .revert_armed = false });
	} else if (p.mode == APPLY_WITH_REVERT && live) {
		if (s.guard_op) s.guard_op.release();
		s.guard_op = p.revert_op;
		s.guard_config = p.revert_config;
		p.revert_op = null;
		s.guard.arm(now, p.revert_after);
		p.op.succeed({ .mode = p.mode, .live = true, .revert_armed = true });
	} else {
		if (live) {
			s.guard.disarm();
			if (s.guard_op) s.guard_op.release();
			s.guard_op = null;
		}
		p.op.succeed({ .mode = p.mode, .live = live, .revert_armed = false });
	}
	s.dirty = true;
	release_pending(p);
}

// Complete the request with an error; the change, if any, was not made.
fn void finish_failed(Pending* p, fault failure)
{
	p.op.fail(failure);
	release_pending(p);
}

// Forget the request and drop what it held.
fn void release_pending(Pending* p)
{
	Session* s = p.session;
	s.pending = null;
	if (p.revert_op) p.revert_op.release();
	if (p.arena_owner) p.arena_owner.release();
	p.op.release();
	alloc::free(s.allocator, p);
}

// The rollback: the guard fell due, so apply the layout that was current before the change.
fn void start_revert(Session* s, Clock now)
{
	s.guard.disarm();
	Pending* p = alloc::new(s.allocator, Pending);
	p.session = s;
	p.op = operation::begin(s.allocator);
	p.op.start();
	p.arena_owner = s.guard_op;
	s.guard_op = null;
	p.config = s.guard_config;
	p.mode = APPLY;
	p.is_revert = true;
	p.result = PENDING;
	s.pending = p;
	if (catch err = start_attempt(p)) finish_failed(p, err);
}

<* The next time the worker must wake on its own: a deadline, or the rollback. FOREVER when none. *>
fn Duration next_wake(Session* s, Clock now)
{
	Duration wait = s.guard.remaining(now);
	if (s.pending != null) {
		Duration request = now > s.pending.deadline ? time::DURATION_ZERO : (Duration)(((ulong)s.pending.deadline - (ulong)now) / 1000);
		if (request < wait) wait = request;
	}
	return wait;
}

<* Confirm the pending change in time: keep it, and forget the rollback point. *>
fn void confirm(Session* s, Clock now)
{
	if (s.guard.confirm(now)) {
		if (s.guard_op) s.guard_op.release();
		s.guard_op = null;
	}
	s.dirty = true;
}
