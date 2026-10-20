<*
 Executing the worker's commands. The worker owns each command's operation
 reference and completes the operation exactly once, whatever the outcome.
*>
module bleu::sysinfo;
import std::time, bleu::operation;

<* Run one command on the worker thread and complete its operation. *>
fn void run_command(Command* command)
{
	Operation{KillReceipt}* operation = command.operation;
	operation.start();
	if (catch err = send_signal(command.pid, command.mode))
	{
		(void)operation.fail(err);
	}
	else
	{
		(void)operation.succeed({ .pid = command.pid, .mode = command.mode });
	}
	operation.release();
}
