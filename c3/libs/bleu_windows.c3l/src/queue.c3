<*
 Helpers every backend's worker uses for its command queue, independent of the OS.
*>
module bleu::windows;
import bleu::error, bleu::operation, bleu::rt::worker;

<*
 Completes one command that never reaches the platform: its request fails with
 `CANCELLED` and the queue's reference to it is released. The hub calls this for every
 command still queued when a worker returns, whether the service is closing or the
 worker bailed out on an error, so no caller waits on an operation forever. Runs on
 the worker thread. A refresh has no request and is skipped.

 @param backend : "Unused: the windows backends keep their state elsewhere"
*>
fn void cancel_command(void* backend, Command* command)
{
	if (command.kind == CommandKind.REFRESH) return;
	Operation{bool}* request = command.request;
	request.fail(error::raise(error::CANCELLED, error::Domain.INTERNAL, 0, "the windows worker stopped first"));
	request.release();
}