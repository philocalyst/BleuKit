<*
 Entry into temporary-memory code from a thread the C3 runtime did not start
 for the main program.

 C3's temporary allocator (`tmem`, `@pool`, `string::tformat`, `tcopy`) is
 thread-local, and only the main thread gets one implicitly. Any other thread
 that touches it aborts with "Use '@pool_init()' to enable the temp allocator on
 a new thread". This is true for threads created with `std::thread` as well as
 for threads created with `pthread_create`, and for every native callback that
 arrives on a thread owned by a framework (CoreAudio, WASAPI, GCD, D-Bus).
 Verified on C3 0.8.5 / glibc: the body of a pthread without the wrapper dies
 with SIGILL in `create_temp_allocator_on_demand`; with it, it runs.

 Every native callback trampoline and every thread entry point in Bleu must
 run its body inside `@foreign_entry`. The macro creates a per-call temp
 allocator backed by the heap and destroys it on exit when the thread has none;
 a thread that already has one (a C3-started thread, or an enclosing entry) keeps
 it. Either way nothing allocated in temporary memory outlives the callback.
*>
module bleu::rt::foreign;

<* Size of the temporary pool created for one foreign entry. *>
const usz FOREIGN_POOL_SIZE = 64 * 1024;

<*
 Whether the current thread already has a top-level temporary allocator. The C3
 runtime gives one to the threads it starts; a foreign thread has none until a
 `@foreign_entry` creates one.
*>
fn bool has_temp_allocator() => std::core::mem::allocators::top_temp != null;

<*
 Run the body with a temporary allocator available on the current thread. Safe on
 any thread, and nested: a thread that already has a temporary allocator (the C3
 runtime's threads, or an enclosing `@foreign_entry`) runs the body in it, and
 only an entry that finds none creates one, from the heap, and destroys it when
 the body ends. Temporary memory allocated inside must not escape the body. Use
 it as a block after a callback's trampoline: the trampoline calls the macro,
 and the body enqueues work to a mailbox, never publishing or blocking.
*>
macro void @foreign_entry(; @body)
{
	if (has_temp_allocator())
	{
		@body();
	}
	else
	{
		@pool_init(mem, FOREIGN_POOL_SIZE)
		{
			@body();
		};
	}
}