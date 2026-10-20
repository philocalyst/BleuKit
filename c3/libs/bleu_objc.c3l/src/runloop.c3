<*
 A thread that runs a CoreFoundation run loop, and can be woken or stopped from
 any other thread. This is how a macOS service worker waits for callback-based
 APIs (IOKit notifications, CoreWLAN events, power sources) without polling.

 The wake-up path is a version-0 `CFRunLoopSource`. Any thread calls `wake()`,
 which signals the source and calls `CFRunLoopWakeUp`; the loop thread then runs
 `on_wake` on its own thread. Both calls are documented as safe from any thread
 (CFRunLoop.h: CFRunLoopSourceSignal, CFRunLoopWakeUp).

 Sources: CoreFoundation `CFRunLoop.h` (CFRunLoopSourceContext field order, which
 is `version, info, retain, release, copyDescription, equal, hash, schedule, cancel,
 perform`; CFRunLoopRunInMode return values; kCFRunLoopDefaultMode) from
 apple-oss-distributions/CF. The `perform` callback signature is `void (*)(void *info)`.
*>
module bleu::cf::runloop @feat(DARWIN) @link("CoreFoundation.framework");
import std::thread, std::atomic, bleu::error;

<* The default run-loop mode name (`kCFRunLoopDefaultMode`). *>
extern const void* KCF_RUNLOOP_DEFAULT_MODE @cname("kCFRunLoopDefaultMode");

extern fn void* cf_run_loop_get_current() @cname("CFRunLoopGetCurrent");
extern fn void cf_run_loop_add_source(void* loop, void* source, void* mode) @cname("CFRunLoopAddSource");
extern fn void cf_run_loop_remove_source(void* loop, void* source, void* mode) @cname("CFRunLoopRemoveSource");
extern fn int cf_run_loop_run_in_mode(void* mode, double seconds, bool return_after_source) @cname("CFRunLoopRunInMode");
extern fn void cf_run_loop_wake_up(void* loop) @cname("CFRunLoopWakeUp");
extern fn void* cf_run_loop_source_create(void* allocator, long order, RunLoopSourceContext* context) @cname("CFRunLoopSourceCreate");
extern fn void cf_run_loop_source_signal(void* source) @cname("CFRunLoopSourceSignal");
extern fn void cf_run_loop_source_invalidate(void* source) @cname("CFRunLoopSourceInvalidate");
extern fn void cf_release(void* value) @cname("CFRelease");

<*
 `CFRunLoopSourceContext`, version 0. Function-pointer fields are `void*`:
 the layout is identical (one pointer each) and only `perform` is set here.
*>
struct RunLoopSourceContext
{
	long version;
	void* info;
	void* retain;
	void* release;
	void* copy_description;
	void* equal;
	void* hash;
	void* schedule;
	void* cancel;
	void* perform;
}

<* Seconds per `CFRunLoopRunInMode` slice. Wake-ups end a slice early, so this only bounds an idle loop. *>
const double RUN_SLICE_SECONDS = 60.0;

<* Return value of `CFRunLoopRunInMode` when a source was handled (CFRunLoop.h: kCFRunLoopRunHandledSource). *>
const int RUN_HANDLED_SOURCE = 4;

<* Called on the loop thread once the loop exists and before it first runs. `loop` is a `CFRunLoopRef`. *>
alias RunLoopSetup = fn void(void* loop, void* context);

<* Called on the loop thread each time the thread is woken. Must not block. *>
alias RunLoopWake = fn void(void* context);

<*
 A run loop on its own thread. The struct must not move after `start`: the
 thread keeps its address. Allocate it with `alloc::new` or keep it in a
 long-lived service object.
*>
struct RunLoopThread
{
	Thread thread;
	void* loop;
	void* source;
	Mutex mutex;
	ConditionVariable ready;
	bool is_ready;
	Atomic{bool} stop_requested;
	RunLoopSetup setup;
	void* setup_context;
	RunLoopWake on_wake;
	void* wake_context;
}

<*
 Start the thread. Returns after the loop exists and `setup` (if any) has run,
 so the caller can rely on `wake` immediately.

 @param setup : "Runs on the loop thread before the loop starts (attach sources here); may be null"
 @param on_wake : "Runs on the loop thread for every wake-up; may be null"
 @return? error::BACKEND_FAILURE : "when the thread cannot be created"
*>
fn void? RunLoopThread.start(&self, RunLoopSetup setup, void* setup_context, RunLoopWake on_wake, void* wake_context)
{
	self.setup = setup;
	self.setup_context = setup_context;
	self.on_wake = on_wake;
	self.wake_context = wake_context;
	self.mutex.init()!;
	self.ready.init()!;
	self.thread.create(&run_loop_thread_entry, self)!;
	self.mutex.lock()!!;
	while (!self.is_ready) self.ready.wait(&self.mutex)!!;
	self.mutex.unlock();
}

<*
 Wake the loop thread. Safe from any thread, and never blocks. A wake-up that
 arrives while the loop is busy is kept and delivered when the loop returns to
 waiting.
*>
fn void RunLoopThread.wake(&self)
{
	cf_run_loop_source_signal(self.source);
	cf_run_loop_wake_up(self.loop);
}

<*
 Ask the loop to stop, wait for the thread to finish, and release the
 run-loop resources. Call from a thread other than the loop thread.

 @return? error::BACKEND_FAILURE : "when the thread cannot be joined"
*>
fn void? RunLoopThread.stop_and_join(&self)
{
	self.stop_requested.store(true);
	self.wake();
	self.thread.join()!;
	self.ready.destroy();
	self.mutex.destroy();
	self.is_ready = false;
}

<* Thread entry: create the source, run `setup`, then run until stopped. *>
fn int run_loop_thread_entry(void* argument) @local
{
	RunLoopThread* self = (RunLoopThread*)argument;
	self.loop = cf_run_loop_get_current();
	RunLoopSourceContext context = { .version = 0, .info = self, .perform = (void*)&run_loop_perform };
	self.source = cf_run_loop_source_create(null, 0, &context);
	cf_run_loop_add_source(self.loop, self.source, KCF_RUNLOOP_DEFAULT_MODE);
	if (self.setup) self.setup(self.loop, self.setup_context);
	self.mutex.lock()!!;
	self.is_ready = true;
	self.ready.broadcast()!!;
	self.mutex.unlock();
	while (!self.stop_requested.load())
	{
		cf_run_loop_run_in_mode(KCF_RUNLOOP_DEFAULT_MODE, RUN_SLICE_SECONDS, true);
	}
	cf_run_loop_remove_source(self.loop, self.source, KCF_RUNLOOP_DEFAULT_MODE);
	cf_run_loop_source_invalidate(self.source);
	cf_release(self.source);
	self.source = null;
	return 0;
}

<* The source's perform callback: run `on_wake` unless a stop was requested. *>
fn void run_loop_perform(void* info) @local
{
	RunLoopThread* self = (RunLoopThread*)info;
	if (self.stop_requested.load() || !self.on_wake) return;
	self.on_wake(self.wake_context);
}
