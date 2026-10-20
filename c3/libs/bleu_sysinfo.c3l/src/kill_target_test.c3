// The kill gate is pure: these tests name every dangerous id but signal nothing.
module bleu::sysinfo::kill_target_test;
import std::core::test, std::time, bleu::error, bleu::operation, bleu::sysinfo;

fn void pid_zero_is_never_a_target() @test
{
	test::@error(sysinfo::check_kill_target(0, TERMINATE, 4242), error::INVALID_ARGUMENT);
	test::@error(sysinfo::check_kill_target(0, FORCE, 4242), error::INVALID_ARGUMENT);
}

fn void ids_at_or_above_2_pow_31_are_refused() @test
{
	// As a pid_t these would be negative: kill(-1) signals everything the user may signal.
	test::@error(sysinfo::check_kill_target(0x8000_0000, FORCE, 4242), error::INVALID_ARGUMENT);
	test::@error(sysinfo::check_kill_target(0xFFFF_FFFF, TERMINATE, 4242), error::INVALID_ARGUMENT);
	sysinfo::check_kill_target(sysinfo::MAX_TARGET_PID, TERMINATE, 4242)!!;
}

fn void init_needs_force() @test
{
	test::@error(sysinfo::check_kill_target(1, TERMINATE, 4242), error::INVALID_ARGUMENT);
	sysinfo::check_kill_target(1, FORCE, 4242)!!;
}

fn void this_process_is_never_a_target() @test
{
	test::@error(sysinfo::check_kill_target(4242, TERMINATE, 4242), error::INVALID_ARGUMENT);
	test::@error(sysinfo::check_kill_target(4242, FORCE, 4242), error::INVALID_ARGUMENT);
	sysinfo::check_kill_target(4243, TERMINATE, 4242)!!;
}

// A kill still queued when the worker stops must fail, not hang its waiter (the hub hands it here).
fn void abandoned_kill_fails_with_disconnected() @test
{
	@pool()
	{
		Operation{KillReceipt}* operation = operation::begin{KillReceipt}(mem);
		operation.retain();
		Command command = { .pid = 4242, .mode = TERMINATE, .operation = operation };
		sysinfo::abandon_command(null, &command);
		test::@error(operation.wait(time::sec(1)), error::DISCONNECTED);
		operation.release();
	};
}
