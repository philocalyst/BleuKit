<*
 The handler threads. Each runs registered methods, one request at a time, on
 its own mailbox. The I/O thread decides which thread gets a request (the least
 busy one) and hands the request over with `Job`; the thread runs the handler,
 finishes the request state, and frees the job.
*>
module bleu::ipc @feat(POSIX);
import std::collections::object, std::thread, std::atomic, bleu::rt::worker, bleu::rt::poller, bleu::error;

// Bytes of the first chunk of a request's arena.
const usz JOB_ARENA_CHUNK = 4096;

// Jobs taken from a handler's mailbox per batch.
const usz POOL_BATCH = 16;

<*
 One request on its way to a handler. The arena owns `params`, `name` and the
 parsed tree; it is freed with the job, after the handler has returned.
*>
struct Job
{
	Allocator allocator;
	DynamicArenaAllocator arena;
	Method* method;
	Pending* pending;
	long id;
	String name;
	Object* params;
}

// Release the arena and the job. The job must not be used afterwards.
fn void Job.free(&self)
{
	self.arena.free();
	alloc::free(self.allocator, self);
}

<*
 One handler thread: its worker, the poller that sleeps on its mailbox, and the
 number of requests it has in hand or queued (the I/O thread reads it to balance).
*>
struct PoolSlot
{
	worker::Worker{Job*} worker;
	poller::Poller waiter;
	Atomic{int} in_flight;
}

<*
 Start the handler thread of this slot. Its poller is set up first, and undone if
 the thread cannot start.

 @return? error::BACKEND_FAILURE : "The thread could not be created"
*>
fn void? PoolSlot.start(&self, Allocator allocator)
{
	self.in_flight.store(0);
	self.waiter.init(allocator, self.worker.mailbox.wakeup(), 1)!;
	if (catch err = self.worker.start("bleu-ipc-handler", &pool_main, self))
	{
		self.waiter.free();
		return err~;
	}
}

// The handler thread's entry point. Runs until its worker is stopped.
fn void pool_main(void* context, worker::Host{Job*}* host)
{
	PoolSlot* slot = (PoolSlot*)context;
	Job*[POOL_BATCH] batch;
	while (true)
	{
		usz taken = host.mailbox().take_all(batch[..]);
		for (usz i = 0; i < taken; i++) run_job(slot, batch[(sz)i]);
		if (host.stopping())
		{
			abandon_queued(slot, host, batch[..]);
			return;
		}
		if (taken == 0) slot.waiter.wait()!!;
	}
}

// Run one request: the handler, then the dispatcher's fallback reply, then the release.
fn void run_job(PoolSlot* slot, Job* job) @private
{
	Call call = { .method = job.name, .params = job.params, .id = job.id, .pending = job.pending };
	job.method.handler(job.method.context, &call);
	if (!job.pending.answered.load() && !job.pending.deferred)
	{
		call.respond_error("handler returned without a response");
	}
	slot.in_flight.sub(1);
	job.pending.release();
	job.free();
}

// The worker was stopped: drop what is still queued, without running it, and release it.
fn void abandon_queued(PoolSlot* slot, worker::Host{Job*}* host, Job*[] batch) @private
{
	while (host.mailbox().pending() > 0)
	{
		usz taken = host.mailbox().take_all(batch);
		for (usz i = 0; i < taken; i++)
		{
			Job* job = batch[(sz)i];
			slot.in_flight.sub(1);
			job.pending.release();
			job.free();
		}
	}
}
