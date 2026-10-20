// The worker's leftover-command path: requests that are queued while the backend is busy are all
// completed when the backend returns. No waiter is left on an operation that will never run.
module bleu::bluetooth::abandon_test;
import std::atomic, std::thread, std::time, bleu::bluetooth, bleu::error, bleu::operation, bleu::rt::worker;

// How many requests are queued behind the blocked backend.
const usz QUEUED = 8;

// Holds the worker's backend until the test opens it.
struct Gate
{
	Atomic{bool} open;
}

// The backend of the test: it takes no commands until the gate opens, then returns.
fn void hold_until_open(void* backend, BluetoothHub* hub, Host{Request}* host)
{
	Gate* gate = (Gate*)backend;
	while (!gate.open.load()) thread::sleep_ms(1);
}

fn void requests_queued_behind_a_returning_backend_all_complete() @test
{
	Gate gate;
	BluetoothHub hub;
	hub.start(mem, "test", "test", &hold_until_open, &gate, abandon: &bluetooth::abandon_request)!!;
	defer hub.free();
	Task*[QUEUED] tasks;
	for (usz i = 0; i < QUEUED; i++)
	{
		Task* task = operation::begin{Done}(mem);
		tasks[i] = task;
		hub.post({ .kind = Command.REFRESH, .op = task.retain() })!!;
	}
	gate.open.store(true);
	hub.stop();
	foreach (task : tasks)
	{
		// Each one ends with DISCONNECTED: the backend went away before it could run the request.
		assert(@catch(
			task.wait(time::ms(0))
		) == error::DISCONNECTED, "a queued request is completed, not left pending");
		task.release();
	}
}