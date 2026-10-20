module bleu::windows;
import bleu::error, bleu::operation, bleu::rt::poller, bleu::rt::worker, std::core::test, std::time;

// A run function that waits until a command is posted, then returns without taking it:
// the way a backend bails out on an error. Nothing else in it touches the mailbox.
fn void return_once_posted(void* backend, WindowsHub* hub, Host{Command}* host) @private
{
	Poller poller;
	if (catch err = poller.init(mem, host.wakeup(), 1)) return;
	defer poller.free();
	poller::Ready[]? ready = poller.wait(time::FOREVER);
	if (catch err = ready) return;
}

// The shutdown rule (docs/SERVICE_TEMPLATE.md): a command queued when the run function
// returns is answered, so its waiter does not hang. Before the hub drained the queue
// with `abandon`, this wait timed out.
fn void a_command_queued_when_the_worker_returns_is_cancelled() @test
{
	WindowsHub hub;
	hub.start(mem, "test", "test", &return_once_posted, null, COMMAND_QUEUE, &cancel_command)!!;
	defer hub.stop();
	Operation{bool}* request = operation::begin{bool}(mem);
	defer request.release();
	request.retain(); // the reference the queued command carries; the hub releases it
	hub.post({ .kind = CommandKind.FOCUS_WINDOW, .target = "1", .request = request })!!;
	test::@error(request.wait((Duration)5_000_000), error::CANCELLED);
}
