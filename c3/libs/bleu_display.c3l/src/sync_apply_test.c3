// The synchronous apply flow against a fake platform: one output at x, with reads that can be made to
// fail. Nothing outside this file is touched; the platform is a struct the test owns.
module bleu::display;
import bleu::error, bleu::operation, std::core::test, std::time, std::time::clock, std::collections::maybe;

struct FakePlatform
{
	int x; // where the one output is
	int reads_left; // reads that succeed before every read fails; a negative count never fails
	bool refuses; // the next commits are refused
}

fn State? fake_read(void* backend, Allocator allocator)
{
	FakePlatform* platform = (FakePlatform*)backend;
	if (platform.reads_left == 0) return error::raise(
		error::BACKEND_FAILURE,
		error::Domain.INTERNAL,
		0,
		"read refused"
	)~;
	platform.reads_left--;
	Output[] outputs = alloc::new_array(allocator, Output, 1);
	Mode mode        = { .width = 1920, .height = 1080, .refresh = 60000 };
	outputs[0] = { .id = "A".copy(allocator), .enabled = true, .current = maybe::value(mode), .x = platform.x, .y = 0 };
	return { .outputs = outputs };
}

fn void? fake_commit(void* backend, Config config, bool test_only, bool persistent)
{
	FakePlatform* platform = (FakePlatform*)backend;
	if (platform.refuses) return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, 0, "commit refused")~;
	if (!test_only) platform.x = config.outputs[0].x;
}

// A configuration that moves the output to `x`, copied into the operation's arena as `apply` does.
fn Config moved_to(ApplyOp* op, int x)
{
	OutputChange[] changes = alloc::new_array(op.allocator(), OutputChange, 1);
	changes[0] = {
		.output_id = "A".copy(op.allocator()),
		.enabled = true,
		.mode = { .width = 1920, .height = 1080, .refresh = 60000 },
		.x = x,
		.y = 0,
	};
	return { .outputs = changes };
}

// Run one command through the sync flow, the way the worker does, and return its operation.
fn ApplyOp* run_sync(SyncNative* native, Rollback* rollback, int x, ApplyMode mode, Clock now)
{
	ApplyOp* op = operation::begin(mem);
	op.retain();
	apply_sync(
		native,
		rollback,
		{ .kind = APPLY, .op = op, .config = moved_to(op, x), .mode = mode, .revert_after = (Duration)15_000_000 },
		now
	);
	return op;
}

fn void a_failed_read_while_capturing_the_rollback_rejects_the_change() @test
{
	// The first read (the check) succeeds, the second (the rollback point) fails: nothing may be changed or aborted.
	FakePlatform platform = { .x = 0, .reads_left = 1 };
	SyncNative native     = { .backend = &platform, .allocator = mem, .read = &fake_read, .commit = &fake_commit };
	Rollback rollback;
	ApplyOp* op           = run_sync(&native, &rollback, 100, APPLY_WITH_REVERT, clock::now());
	test::@error(op.wait(time::sec(1)), error::BACKEND_FAILURE);
	op.release();
	assert(platform.x == 0 && !rollback.guard.armed);
}

fn void a_plain_apply_that_changes_nothing_forgets_the_pending_rollback() @test
{
	FakePlatform platform = { .x = 0, .reads_left = -1 };
	SyncNative native     = { .backend = &platform, .allocator = mem, .read = &fake_read, .commit = &fake_commit };
	Rollback rollback;
	Clock now             = clock::now();
	run_sync(&native, &rollback, 100, APPLY_WITH_REVERT, now).release();
	assert(rollback.guard.armed && platform.x == 100);
	// The caller accepts the layout that is live: nothing to change, and the rollback must not undo it.
	ApplyOp* accepted  = run_sync(&native, &rollback, 100, APPLY, now);
	ApplyResult result = accepted.wait(time::sec(1))!!;
	accepted.release();
	assert(result.live && !result.revert_armed);
	assert(!rollback.guard.armed && rollback.op == null);
	assert(!rollback.guard.due(now + (Clock)20_000_000_000));
	assert(platform.x == 100);
}

fn void a_second_unconfirmed_change_keeps_the_last_confirmed_layout() @test
{
	FakePlatform platform = { .x = 0, .reads_left = -1 };
	SyncNative native     = { .backend = &platform, .allocator = mem, .read = &fake_read, .commit = &fake_commit };
	Rollback rollback;
	Clock now             = clock::now();
	run_sync(&native, &rollback, 100, APPLY_WITH_REVERT, now).release();
	run_sync(&native, &rollback, 200, APPLY_WITH_REVERT, now).release();
	assert(platform.x == 200 && rollback.guard.armed);
	// A rollback returns to the layout nobody has confirmed away from: x = 0, not the intermediate x = 100.
	assert(rollback.config.outputs[0].x == 0);
	forget_rollback(&rollback);
}

fn void a_refused_rollback_reports_failure_and_keeps_the_change() @test
{
	FakePlatform platform = { .x = 0, .reads_left = -1 };
	SyncNative native     = { .backend = &platform, .allocator = mem, .read = &fake_read, .commit = &fake_commit };
	Rollback rollback;
	run_sync(&native, &rollback, 100, APPLY_WITH_REVERT, clock::now()).release();
	platform.refuses = true;
	assert(!revert_sync(&native, &rollback));
	assert(platform.x == 100 && !rollback.guard.armed);
}