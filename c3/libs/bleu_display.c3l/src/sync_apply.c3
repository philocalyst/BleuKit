<*
 The apply flow of the synchronous platforms (macOS CoreGraphics, Windows display configuration):
 a change is checked against the current state, then carried out in one call of the platform, and
 a change made with APPLY_WITH_REVERT keeps the layout it replaced until it is confirmed or its
 deadline passes. Everything here runs on the worker thread; the platform answers at once.

 Pure with respect to the platform: the backend supplies the read and the commit.
*>
module bleu::display;
import bleu::error, bleu::observe, bleu::operation, std::time, std::time::clock, std::collections::maybe;

<* Read the current state of the platform, allocated in `allocator`. *>
alias StateReadFn = fn State?(void* backend, Allocator allocator);

<*
 Carry out a configuration in one platform call: validate it and, unless `test_only`, make it live.
 A failure leaves the platform as it was.
*>
alias CommitFn = fn void?(void* backend, Config config, bool test_only, bool persistent);

<*
 The platform's side of the flow. `can_rotate` and `can_toggle` say whether the platform can change
 a rotation and switch a display on or off; a change that needs one it cannot make is refused.
*>
struct SyncNative
{
	void* backend;
	Allocator allocator;
	StateReadFn read;
	CommitFn commit;
	bool can_rotate;
	bool can_toggle;
}

<* The layout a rollback returns to: the config (its strings live in `op`'s arena) and the deadline. *>
struct Rollback
{
	RevertGuard guard;
	ApplyOp* op;
	Config config;
}

// Complete a command with an error.
fn void reject(ApplyOp* op, fault failure)
{
	op.fail(failure);
	op.release();
}

<*
 Check a configuration against the current state. `changed` says whether anything differs.

 @return? error::INVALID_ARGUMENT : "The config does not name the outputs exactly, or does not form a valid desktop"
 @return? error::UNSUPPORTED : "The change needs something the platform cannot do here"
*>
fn void? check_request(SyncNative* native, Config config, bool* changed)
{
	@pool()
	{
		State state = native.read(native.backend, tmem)!;
		validate_config(state.outputs, config)!;
		for (sz i = 0; i < config.outputs.len; i++) {
			Maybe{sz} index = index_of_output(state.outputs, config.outputs[i].output_id);
			OutputDelta delta = delta_of(state.outputs[index.value], config.outputs[i]);
			if (delta.enabled && !native.can_toggle) {
				return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "this platform cannot switch an output on or off here")~;
			}
			if (config.outputs[i].transform != state.outputs[index.value].transform && !native.can_rotate) {
				return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "this platform cannot rotate an output here")~;
			}
		}
		*changed = config_changes(state, config);
	};
}

// The layout as it is now, copied into `allocator`: the point a rollback returns to.
fn Config previous_config(SyncNative* native, Allocator allocator)
{
	Config result;
	@pool()
	{
		State state = native.read(native.backend, tmem)!!;
		result = config_from_state(state, allocator);
	};
	return result;
}

<*
 Carry out one apply command. A change made with APPLY_WITH_REVERT replaces the rollback point
 (the layout before this change), and a plain APPLY forgets the earlier one: the newest layout is
 the one a later rollback would return to.
*>
fn void apply_sync(SyncNative* native, Rollback* rollback, Command command, Clock now)
{
	ApplyOp* op = command.op;
	op.start();
	bool changed = false;
	if (catch err = check_request(native, command.config, &changed)) {
		reject(op, err);
		return;
	}
	if (!changed) {
		op.succeed({ .mode = command.mode, .live = command.mode != TEST_ONLY, .revert_armed = false });
		op.release();
		return;
	}
	ApplyOp* holder = null;
	Config previous;
	if (command.mode == APPLY_WITH_REVERT) {
		holder = operation::begin(native.allocator);
		previous = previous_config(native, holder.allocator());
	}
	if (catch err = native.commit(native.backend, command.config, command.mode == TEST_ONLY, command.config.persistent)) {
		if (holder) holder.release();
		reject(op, err);
		return;
	}
	if (command.mode == APPLY_WITH_REVERT) {
		if (rollback.op) rollback.op.release();
		rollback.op = holder;
		rollback.config = previous;
		rollback.guard.arm(now, command.revert_after);
	} else if (command.mode == APPLY) {
		rollback.guard.disarm();
		if (rollback.op) rollback.op.release();
		rollback.op = null;
	}
	op.succeed({ .mode = command.mode, .live = command.mode != TEST_ONLY, .revert_armed = command.mode == APPLY_WITH_REVERT });
	op.release();
}

// Keep the pending change: its rollback point is forgotten.
fn void confirm_sync(Rollback* rollback, Clock now)
{
	if (rollback.guard.confirm(now)) {
		if (rollback.op) rollback.op.release();
		rollback.op = null;
	}
}

<*
 Roll back the change nobody confirmed: apply the layout that was current before it. The outcome
 is reported as a REVERTED event; a rollback the platform refuses leaves the change in place, and the
 publish that follows says what the system now has.
*>
fn void revert_sync(SyncNative* native, Rollback* rollback, DisplayHub* hub)
{
	rollback.guard.disarm();
	ApplyOp* holder = rollback.op;
	Config previous = rollback.config;
	rollback.op = null;
	if (catch err = native.commit(native.backend, previous, false, false)) {
		// Nothing more can be done: the change stays, and the publish after this reports it.
	}
	if (holder) holder.release();
	emit(hub, REVERTED, "");
}
