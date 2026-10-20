<*
 Helpers every backend's worker uses for its command queue, independent of the OS.
*>
module bleu::windows;
import bleu::error, bleu::operation, bleu::rt::worker;

<*
 Completes the requests still queued when the service closes. They never reach the
 platform, so each one fails with `CANCELLED`. Called by a worker after its loop ends.
*>
fn void fail_queued(Host{Command}* host, Command[] batch)
{
	usz count = host.mailbox().take_all(batch);
	while (count > 0)
	{
		for (usz i = 0; i < count; i++)
		{
			if (batch[i].kind == CommandKind.REFRESH) continue;
			Operation{bool}* request = batch[i].request;
			request.fail(error::raise(error::CANCELLED, error::Domain.INTERNAL, 0, "the windows service was closed"));
			request.release();
		}
		count = host.mailbox().take_all(batch);
	}
}