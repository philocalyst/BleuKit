module bleu::operation_test;
import bleu::operation, bleu::error, std::core::test, std::thread, std::time;

alias Phase = operation::Phase{int};

// What a completion callback recorded: how often it ran and in what phase it saw the operation.
struct Completed
{
	int calls;
	Phase phase;
}

fn void on_completed(void* context, operation::Operation{int}* op)
{
	Completed* done = (Completed*)context;
	done.calls++;
	done.phase = op.phase();
}

fn void success_is_exactly_once() @test
{
	operation::Operation{int}* op = operation::begin{int}(mem);
	defer op.release();
	test::@check(op.succeed(5), "the first completion takes effect");
	test::@check(!op.succeed(6), "a second success is refused");
	test::@check(!op.fail(error::BUSY), "a failure after success is refused");
	test::eq(5, op.wait()!!);
	test::eq(Phase.SUCCEEDED, op.phase());
}

fn void failure_is_reported_by_wait() @test
{
	operation::Operation{int}* op = operation::begin{int}(mem);
	defer op.release();
	op.start();
	test::eq(Phase.RUNNING, op.phase());
	test::@check(op.fail(error::BUSY), "the first failure takes effect");
	test::@check(!op.succeed(1), "a success after failure is refused");
	test::@error(op.wait(), error::BUSY);
	test::eq(Phase.FAILED, op.phase());
}

fn void cancel_sets_the_flag_and_cancelled_ends_the_operation() @test
{
	operation::Operation{int}* op = operation::begin{int}(mem);
	defer op.release();
	test::@check(!op.cancel_requested(), "a new operation is not cancelled");
	op.cancel();
	test::@check(op.cancel_requested(), "cancel sets the flag");
	op.fail(error::CANCELLED);
	test::eq(Phase.CANCELLED, op.phase());
	test::@error(op.wait(), error::CANCELLED);
}

fn void start_is_ignored_once_terminal() @test
{
	operation::Operation{int}* op = operation::begin{int}(mem);
	defer op.release();
	op.succeed(3);
	op.start();
	test::eq(Phase.SUCCEEDED, op.phase());
}

fn void a_callback_runs_on_completion_and_then_fires_once() @test
{
	operation::Operation{int}* op = operation::begin{int}(mem);
	defer op.release();
	Completed done;
	op.then(&on_completed, &done)!!;
	test::eq(0, done.calls);
	op.succeed(9);
	test::eq(1, done.calls);
	test::eq(Phase.SUCCEEDED, done.phase);
	op.succeed(10);
	test::eq(1, done.calls);
}

fn void a_callback_attached_after_completion_runs_at_once() @test
{
	operation::Operation{int}* op = operation::begin{int}(mem);
	defer op.release();
	op.fail(error::BUSY);
	Completed done;
	op.then(&on_completed, &done)!!;
	test::eq(1, done.calls);
	test::eq(Phase.FAILED, done.phase);
}

fn void a_second_callback_is_refused_and_the_first_is_kept() @test
{
	operation::Operation{int}* op = operation::begin{int}(mem);
	defer op.release();
	Completed first;
	Completed second;
	op.then(&on_completed, &first)!!;
	test::@error(op.then(&on_completed, &second), error::INVALID_STATE);
	op.succeed(1);
	test::eq(1, first.calls);
	test::eq(0, second.calls);
}

fn void wait_times_out_while_pending_and_completes_later() @test
{
	operation::Operation{int}* op = operation::begin{int}(mem);
	defer op.release();
	test::@error(op.wait(time::ms(2)), TIMEOUT);
	// The operation itself is unaffected by the timeout.
	test::eq(Phase.PENDING, op.phase());
	op.succeed(4);
	test::eq(4, op.wait(time::ms(2))!!);
}

fn void detail_of_an_unrecorded_failure_has_no_text() @test
{
	error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "stale detail from an unrelated call");
	operation::Operation{int}* op = operation::begin{int}(mem);
	defer op.release();
	op.fail(error::BUSY);
	test::eq(error::Status.BUSY, op.detail().status);
	test::eq((sz)0, op.detail().len);
}

fn void detail_recorded_on_the_completing_thread_is_kept() @test
{
	operation::Operation{int}* op = operation::begin{int}(mem);
	defer op.release();
	error::raise(error::BUSY, error::Domain.ERRNO, 11, "resource busy");
	op.fail(error::BUSY);
	test::eq(error::Status.BUSY, op.detail().status);
	test::eq(error::Domain.ERRNO, op.detail().domain);
	test::eq(11, op.detail().code);
	test::@check(op.detail().message() == "resource busy", "the recorded text is kept");
}

fn void detail_of_a_success_is_empty_ok() @test
{
	operation::Operation{int}* op = operation::begin{int}(mem);
	defer op.release();
	error::raise(error::BUSY, error::Domain.INTERNAL, 0, "left over");
	op.succeed(1);
	test::eq(error::Status.OK, op.detail().status);
	test::eq((sz)0, op.detail().len);
}

// Completes an operation from another thread after a short delay.
fn int complete_later(void* context)
{
	operation::Operation{int}* op = (operation::Operation{int}*)context;
	thread::sleep(time::ms(2))!!;
	op.succeed(7);
	return 0;
}

// A completion that races a deadline must end in exactly one of two states:
// the value, or TIMEOUT followed by the value on a later wait. It must never hang.
fn void completion_racing_the_deadline_is_never_lost() @test
{
	for (int round = 0; round < 25; round++)
	{
		operation::Operation{int}* op = operation::begin{int}(mem);
		defer op.release();
		Thread completer;
		completer.create(&complete_later, op)!!;
		if (try value = op.wait(time::ms(2)))
		{
			test::eq(7, value);
		}
		else
		{
			test::eq(7, op.wait()!!);
		}
		completer.join()!!;
	}
}
