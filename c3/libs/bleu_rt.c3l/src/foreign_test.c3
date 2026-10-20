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
	usz outer_length;
	usz inner_length;
	bool temp_left_behind;
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

fn void* nested_entry(void* arg)
{
	Probe* probe = (Probe*)arg;
	foreign::@foreign_entry()
	{
		foreign::@foreign_entry()
		{
			String inner = string::tformat("inner %d", 1);
			probe.inner_length = inner.len;
		};
		// The inner entry reused the allocator of the outer one: it is still usable.
		String outer = string::tformat("outer %d", 2);
		probe.outer_length = outer.len;
	};
	// The outer entry created the allocator, so it destroyed it again on the way out.
	probe.temp_left_behind = foreign::has_temp_allocator();
	return null;
}

fn void nested_entries_share_one_temporary_allocator() @test
{
	Probe probe;
	ulong thread;
	test::eq(0, pthread_create(&thread, null, &nested_entry, &probe));
	test::eq(0, pthread_join(thread, null));
	test::eq((usz)"inner 1".len, probe.inner_length);
	test::eq((usz)"outer 2".len, probe.outer_length);
	test::@check(!probe.temp_left_behind, "the entry tore down the allocator it created");
}

fn void entry_on_a_thread_with_a_temporary_allocator_reuses_it() @test
{
	// The test runner's thread has a temporary allocator, as the C3 runtime gives the threads it
	// starts (service workers). Opening a pool makes sure one exists here.
	@pool()
	{
		test::@check(foreign::has_temp_allocator(), "the pool gave this thread a temporary allocator");
		foreign::@foreign_entry()
		{
			String text = string::tformat("reused %d", 9);
			test::eq((sz)"reused 9".len, text.len);
		};
		// The entry did not tear down the caller's allocator.
		test::@check(foreign::has_temp_allocator(), "the caller's allocator survives the entry");
		String after = string::tformat("after %d", 10);
		test::eq((sz)"after 10".len, after.len);
	};
}