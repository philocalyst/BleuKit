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
 allocator backed by the heap and destroys it on exit, so nothing allocated in
 temporary memory outlives the callback.
*>
module bleu::rt::foreign;

<* Size of the temporary pool created for one foreign entry. *>
const usz FOREIGN_POOL_SIZE = 64 * 1024;

<*
 Run `@body` with a temporary allocator available on the current thread.

     fn void* on_callback(void* context)
     {
         @foreign_entry()
         {
             String text = string::tformat("event %d", 7);
             // ... enqueue, never publish or block ...
         };
         return null;
     }

 The body must not let temporary memory escape the block.
*>
macro void @foreign_entry(; @body)
{
	@pool_init(mem, FOREIGN_POOL_SIZE)
	{
		@body();
	};
}
