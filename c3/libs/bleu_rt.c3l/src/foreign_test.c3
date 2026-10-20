<*
 Proves the foreign-entry wrapper: a thread created with pthread_create, which the
 C3 runtime knows nothing about, can use temporary memory inside `@foreign_entry`.
 Without the wrapper the same body aborts with "Use '@pool_init()' ..." (verified
 by hand on C3 0.8.5, see docs/research/bleu_rt.md).
*>
module bleu::rt::foreign_test @feat(POSIX);
import bleu::rt::foreign, std::core::test, std::core::string;

alias ForeignStart = fn void*(void* arg);

extern fn CInt pthread_create(ulong* thread, void* attributes, ForeignStart start, void* arg) @cname("pthread_create");
extern fn CInt pthread_join(ulong thread, void** value) @cname("pthread_join");

struct Probe
{
	usz length;
}

fn void* probe_entry(void* arg)
{
	Probe* probe = (Probe*)arg;
	foreign::@foreign_entry()
	{
		// tformat allocates from the temporary allocator: this is the call that traps
		// on a thread without it.
		String text = string::tformat("foreign %d", 42);
		probe.length = text.len;
	};
	return null;
}

fn void foreign_thread_has_a_temporary_allocator() @test
{
	Probe probe;
	ulong thread;
	test::eq(0, pthread_create(&thread, null, &probe_entry, &probe));
	test::eq(0, pthread_join(thread, null));
	test::eq((usz)"foreign 42".len, probe.length);
}
