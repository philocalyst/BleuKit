<*
 Grand Central Dispatch helpers for Bleu services: a serial queue for ordered
 work, and repeating timers that fire on a queue.

 The stdlib has no libdispatch binding, so these are the C entry points from
 libSystem. Signatures and constants: Apple libdispatch headers
 (apple-oss-distributions/libdispatch: `dispatch/queue.h` for `dispatch_async_f`
 and `dispatch_queue_create` (`DISPATCH_QUEUE_SERIAL` is `NULL`), `dispatch/source.h`
 for `dispatch_source_create`, `dispatch_source_set_timer`, the `_f` handler
 variants and `DISPATCH_SOURCE_TYPE_TIMER`, `dispatch/time.h` for `dispatch_time`
 and `DISPATCH_TIME_NOW`, `dispatch/object.h` for `dispatch_release`). The
 `dispatch_release`/`dispatch_set_context` prototypes are also in dispatch2 0.3.0
 `src/generated/mod.rs`.

 Threading: work submitted to a queue runs on a libdispatch thread, one item at a
 time for a serial queue. Native callbacks should enqueue onto a service's own
 worker, not run service logic directly.
*>
module bleu::cf::dispatch @feat(DARWIN);
import std::time, bleu::error;

<* A function run on a queue. `context` is the pointer given with the work or timer. *>
alias WorkFn = fn void(void* context);

<* Nanoseconds in a `Duration` (microseconds): the multiplier from `Duration.to_nano`. *>
const ulong NANOS_PER_MICRO = 1000;

<* `DISPATCH_TIME_NOW`: the current time, for `dispatch_time`. *>
const ulong DISPATCH_TIME_NOW_VALUE = 0;

<* `DISPATCH_QUEUE_SERIAL` is `NULL` (queue.h). *>
const void* DISPATCH_QUEUE_SERIAL_ATTR = null;

extern fn void* dispatch_queue_create(ZString label, void* attributes) @cname("dispatch_queue_create");
extern fn void dispatch_async_f(void* queue, void* context, WorkFn work) @cname("dispatch_async_f");
extern fn void dispatch_release(void* object) @cname("dispatch_release");
extern fn void dispatch_set_context(void* object, void* context) @cname("dispatch_set_context");
extern fn void dispatch_resume(void* object) @cname("dispatch_resume");
extern fn ulong dispatch_time(ulong base, long offset) @cname("dispatch_time");
extern fn void* dispatch_source_create(void* type, ulong handle, ulong mask, void* queue) @cname("dispatch_source_create");
extern fn void dispatch_source_set_timer(void* source, ulong start, ulong interval, ulong leeway) @cname("dispatch_source_set_timer");
extern fn void dispatch_source_set_event_handler_f(void* source, WorkFn handler) @cname("dispatch_source_set_event_handler_f");
extern fn void dispatch_source_cancel(void* source) @cname("dispatch_source_cancel");

<* The address of the timer source type (`DISPATCH_SOURCE_TYPE_TIMER`). *>
extern const char DISPATCH_SOURCE_TYPE_TIMER_SYMBOL @cname("_dispatch_source_type_timer");

<* A serial dispatch queue: work runs one item at a time, in submission order. *>
struct SerialQueue
{
	void* queue;
}

<*
 Create a serial queue. `label` names it in debuggers and crash reports.

 @return? error::BACKEND_FAILURE : "when libdispatch refuses to create the queue"
*>
fn SerialQueue? serial_queue(ZString label)
{
	void* queue = dispatch_queue_create(label, DISPATCH_QUEUE_SERIAL_ATTR);
	if (!queue) return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, 0, "dispatch_queue_create('%s') failed", label)~;
	return { .queue = queue };
}

<* Submit `work(context)` to the queue. Never blocks the caller. *>
fn void SerialQueue.async(self, WorkFn work, void* context) => dispatch_async_f(self.queue, context, work);

<*
 Drop the caller's reference to the queue. Work already submitted still runs.
 Idempotent.
*>
fn void SerialQueue.close(&self)
{
	if (self.queue) dispatch_release(self.queue);
	self.queue = null;
}

<*
 A repeating timer on a queue. It is created suspended; `start` arms it and
 `stop` cancels it. Close it when done.
*>
struct Timer
{
	void* source;
	Duration interval;
}

<*
 Create a repeating timer that calls `handler(context)` on `queue` every
 `interval`. Leeway is 10 % of the interval, which lets the system coalesce wake-ups.

 @require interval > time::DURATION_ZERO : "A timer needs a positive interval"
 @return? error::BACKEND_FAILURE : "when libdispatch refuses to create the source"
*>
fn Timer? repeating_timer(SerialQueue queue, Duration interval, WorkFn handler, void* context)
{
	void* source = dispatch_source_create((void*)&DISPATCH_SOURCE_TYPE_TIMER_SYMBOL, 0, 0, queue.queue);
	if (!source) return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, 0, "dispatch_source_create(timer) failed")~;
	dispatch_set_context(source, context);
	dispatch_source_set_event_handler_f(source, handler);
	return { .source = source, .interval = interval };
}

<* Arm the timer: the first tick comes one interval from now. *>
fn void Timer.start(&self)
{
	ulong period = (ulong)self.interval.to_nano() * NANOS_PER_MICRO / NANOS_PER_MICRO;
	ulong first = dispatch_time(DISPATCH_TIME_NOW_VALUE, (long)period);
	dispatch_source_set_timer(self.source, first, period, period / 10);
	dispatch_resume(self.source);
}

<* Cancel the timer. No further ticks are delivered after this returns. *>
fn void Timer.stop(&self) => dispatch_source_cancel(self.source);

<* Release the timer, cancelling it first. Idempotent. *>
fn void Timer.close(&self)
{
	if (!self.source) return;
	dispatch_source_cancel(self.source);
	dispatch_release(self.source);
	self.source = null;
}
