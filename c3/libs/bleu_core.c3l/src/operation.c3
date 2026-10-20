<*
 A request that finishes later: connect to a network, pair a device, ask the
 user for a password.

 An `Operation{Value}` is created by the service when it accepts a request. The
 caller can wait for it, poll it, cancel it, or attach a completion callback;
 the service's worker completes it exactly once. "Accepted", "in progress" and
 "finished" are distinct phases, and the *observed* system state still arrives
 separately through the service's `Observable`.

 `Value` may point into the operation's own arena (`Operation.allocator()`); it
 stays valid until the last reference is released.
*>
module bleu::operation <Value>;
import std::thread, std::atomic, std::time, bleu::error, bleu::deadline;

enum Phase : char
{
	PENDING, // accepted, not started
	RUNNING, // in flight
	SUCCEEDED,
	FAILED,
	CANCELLED,
}

<*
 Called exactly once, on the completing thread, when the operation reaches a
 terminal phase. Must not block.
*>
alias Completion = fn void(void* context, Operation* op);

struct Operation
{
	Atomic{int} refs;
	Allocator parent;
	DynamicArenaAllocator arena;
	Mutex mutex;
	ConditionVariable finished;
	Phase state;
	fault failure;
	Detail failure_detail;  // what the completing thread recorded for the failure; empty if none
	Value value;
	Atomic{bool} cancel_flag;
	Completion completion;
	void* completion_context;
}

<* Create an operation in `PENDING` holding one reference (the caller's). *>
fn Operation* begin(Allocator parent)
{
	Operation* op = alloc::new(parent, Operation);
	op.parent = parent;
	op.arena.init(parent, 1024);
	op.refs.store(1);
	op.mutex.init()!!;
	op.finished.init()!!;
	return op;
}

fn Allocator Operation.allocator(&self) @inline => &self.arena;
fn Operation* Operation.retain(&self)
{
	self.refs.add(1);
	return self;
}

fn void Operation.release(&self)
{
	if (self.refs.sub(1) != 1) return;
	Allocator parent = self.parent;
	self.mutex.destroy();
	self.finished.destroy()!!;
	self.arena.free();
	alloc::free(parent, self);
}

<* Mark the operation as started. Idempotent; ignored once terminal. *>
fn void Operation.start(&self)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	if (self.state == PENDING) self.state = RUNNING;
}

<* True once the caller asked to cancel; long-running work should poll this. *>
fn bool Operation.cancel_requested(&self) @inline => self.cancel_flag.load();

<*
 Ask the operation to stop. The service decides how far it can unwind; the
 operation ends `CANCELLED` if it honours the request and otherwise completes
 normally.
*>
fn void Operation.cancel(&self) => self.cancel_flag.store(true);

<*
 Finish successfully. Only the first terminal call has any effect.

 @return "true when this call performed the transition"
*>
fn bool Operation.succeed(&self, Value value)
{
	self.mutex.lock()!!;
	if (self.state >= SUCCEEDED)
	{
		self.mutex.unlock();
		return false;
	}
	self.value = value;
	self.state = SUCCEEDED;
	self.conclude();
	return true;
}

<*
 Finish with an error (`error::CANCELLED` ends the operation `CANCELLED`).
 Only the first terminal call has any effect.
*>
fn bool Operation.fail(&self, fault failure)
{
	self.mutex.lock()!!;
	if (self.state >= SUCCEEDED)
	{
		self.mutex.unlock();
		return false;
	}
	self.failure = failure;
	self.failure_detail = detail_for(failure);
	self.state = failure == error::CANCELLED ? CANCELLED : FAILED;
	self.conclude();
	return true;
}

// The detail to keep for a failure: the completing thread's own record of it when that
// record has the same status, otherwise an empty detail that carries only the status.
// The waiting caller's thread-local record is never used.
fn Detail detail_for(fault failure) @private
{
	Status status = error::status_of(failure);
	Detail* last  = error::last();
	if (last.status == status) return *last;
	Detail empty = { .status = status };
	return empty;
}

// Wake waiters and run the completion callback. Entered with the mutex held.
fn void Operation.conclude(&self)
{
	Completion callback = self.completion;
	void* context       = self.completion_context;
	self.finished.broadcast()!!;
	self.mutex.unlock();
	if (callback) callback(context, self);
}

<*
 Run `callback` when the operation finishes: immediately (on this thread) if it
 already has, otherwise on the completing thread. An operation takes one callback;
 a second `then` is refused and the first one stays.

 @return? error::INVALID_STATE : "A callback is already attached"
*>
fn void? Operation.then(&self, Completion callback, void* context)
{
	self.mutex.lock()!!;
	if (self.completion)
	{
		self.mutex.unlock();
		return error::raise(error::INVALID_STATE, error::Domain.INTERNAL, 0, "a callback is already attached")~;
	}
	if (self.state >= SUCCEEDED)
	{
		self.mutex.unlock();
		callback(context, self);
		return;
	}
	self.completion = callback;
	self.completion_context = context;
	self.mutex.unlock();
}

fn Phase Operation.phase(&self)
{
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	return self.state;
}

<*
 The native code and message behind a failed operation, when the worker recorded
 them with `error::raise`. Valid after `wait` returned a fault.
*>
fn Detail* Operation.detail(&self) => self.has_detail ? &self.failure_detail : error::last();

<*
 Wait for the operation to finish and return its value.

 @return "The value on success"
 @return? TIMEOUT : "Still running after `timeout` (the operation itself continues)"
 @return? error::CANCELLED : "The operation was cancelled"
*>
fn Value? Operation.wait(&self, Duration timeout = time::FOREVER)
{
	Deadline deadline = deadline::after(timeout);
	self.mutex.lock()!!;
	defer self.mutex.unlock();
	while (self.state < SUCCEEDED)
	{
		if (!deadline.wait(&self.finished, &self.mutex)) return TIMEOUT~;
	}
	if (self.state != SUCCEEDED) return self.failure~;
	return self.value;
}