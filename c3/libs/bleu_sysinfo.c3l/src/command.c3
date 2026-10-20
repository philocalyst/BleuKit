<*
 Executing the worker's commands. The worker owns each command's operation
 reference and completes the operation exactly once, whatever the outcome.
*>
module bleu::sysinfo;
import std::time, bleu::error, bleu::operation;

<* Run one command on the worker thread and complete its operation. *>
fn void run_command(Command* command)
{
	Operation{KillReceipt}* operation = command.operation;
	operation.start();
	if (catch err = signal_checked(command))
	{
		(void)operation.fail(err);
	}
	else
	{
		(void)operation.succeed({ .pid = command.pid, .mode = command.mode });
	}
	operation.release();
}

<*
 Fail a command that was still queued when the worker stopped, so its waiter is
 released instead of hanging. The worker's reference is released here.
*>
fn void abandon_command(void* backend, Command* command)
{
	Operation{KillReceipt}* operation = command.operation;
	(void)operation.fail(error::DISCONNECTED);
	operation.release();
}

<*
 Re-check the target on the worker, then signal it: nothing reaches the system
 call without passing `check_kill_target`.
*>
fn void? signal_checked(Command* command) @local
{
	check_kill_target(command.pid, command.mode, own_process_id())!;
	return send_signal(command.pid, command.mode);
}
