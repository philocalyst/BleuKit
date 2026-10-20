<*
 The shared machinery behind every exported function: the entry wrapper, the
 options and timeout conventions, error reporting and buffers handed to C.
*>
module bleu::capi;
import std::time, bleu::error, bleu::rt::foreign;

<*
 Longest timeout or poll interval in milliseconds the C side may ask for: one
 year. A wait longer than this is treated as forever.
*>
const ulong MAX_MILLISECONDS = 31_536_000_000;

// How many exported calls are running on this thread. A nested call (a listener calling an accessor) must not make a second pool.
tlocal uint scope_depth;

<* Enter an exported call; true for the outermost one on this thread. *>
fn bool enter_scope()
{
	scope_depth++;
	return scope_depth == 1;
}

<* Leave an exported call entered with `enter_scope`. *>
fn void leave_scope()
{
	scope_depth--;
}

<*
 Whether this thread already has a temporary allocator. Threads the C3 runtime started
 do (the service workers), and `@pool_init` must not run on them.
*>
fn bool has_temp_allocator() => std::core::mem::allocators::top_temp != null;

<*
 Wrap the body of any exported function. The outermost call on a thread runs its body
 in a temporary allocator that exists on any thread (`rt::foreign`), so a C caller may
 come from a thread the runtime did not start. A nested call runs in that allocator.
 (`@foreign_entry` must not be nested, nor run where a temporary allocator already exists: it asserts both.)
*>
macro void @capi_scope(; @body)
{
	bool outermost = enter_scope();
	defer leave_scope();
	if (outermost && !has_temp_allocator())
	{
		foreign::@foreign_entry()
		{
			@body();
		};
	}
	else
	{
		@body();
	}
}

<*
 Wrap the body of an exported function that reports a status: as `@capi_scope`, and
 it first clears the calling thread's last error (see `bleu_last_error`).
*>
macro void @capi_entry(; @body)
{
	error::Detail* detail = error::last();
	detail.status = error::Status.OK;
	detail.len = 0;
	@capi_scope()
	{
		@body();
	};
}

<*
 Copy a caller's versioned options struct into `destination`, which holds the
 current layout. `struct_size` is the size the caller compiled against: members
 beyond it keep the destination's values (the defaults), and members the library
 does not know are ignored.

 Fails with INVALID_ARGUMENT: struct_size is zero
*>
fn CStatus take_options(void* destination, usz destination_size, void* source, uint struct_size)
{
	if (struct_size == 0) return argument_error("struct_size is 0: set it to sizeof the options struct");
	mem::copy(destination, source, (sz)min((usz)struct_size, destination_size));
	return CStatus.OK;
}

<* A refused argument: NULL where a pointer is required, or a value out of range. *>
fn CStatus argument_error(String message) => report(error::INVALID_ARGUMENT, message);

<*
 Refuse a call made from inside a listener of the same service. The worker holds
 the service's lock while it calls the listener, so the call would deadlock.
*>
fn CStatus reentry_refused() => report(error::INVALID_STATE, "called from a listener of the same service");

<*
 Convert `f` to its status. The calling thread keeps the native details a backend
 already recorded for the same failure; otherwise `context` is recorded.
*>
fn CStatus report(fault f, String context)
{
	error::Detail* detail = error::last();
	if (detail.len == 0 || detail.status != error::status_of(f))
	{
		error::raise(f, error::Domain.INTERNAL, 0, "%s", context);
	}
	return (CStatus)(int)error::status_of(f);
}

<* The text of a C string, empty for NULL. The text is borrowed. *>
fn String text_of(ZString text)
{
	if (!text) return "";
	return text.str_view();
}

<*
 Copy `text` into a new NUL-terminated buffer that the caller frees with
 `bleu_free`. The length excludes the NUL.
*>
fn CStatus copy_out(String text, char** out, usz* length)
{
	usz count    = (usz)text.len;
	char* buffer = alloc::new_array(mem, char, (sz)count + 1);
	if (count > 0) mem::copy(buffer, text.ptr, (sz)count);
	buffer[count] = 0;
	*out = buffer;
	*length = count;
	return CStatus.OK;
}

<* A timeout in milliseconds as a `Duration`; anything longer than a year is forever. *>
fn Duration milliseconds(ulong ms)
{
	if (ms > MAX_MILLISECONDS) return time::FOREVER;
	return (Duration)(ms * 1000);
}

<* A wait in milliseconds: negative means forever (the caller has rejected anything below -1). *>
fn Duration wait_duration(long ms)
{
	if (ms < 0) return time::FOREVER;
	return milliseconds((ulong)ms);
}