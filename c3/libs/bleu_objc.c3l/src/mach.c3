<*
 Raising Mach `kern_return_t` and IOKit `IOReturn` codes as Bleu faults.

 Both are `int`s. An IOKit code is a `sys_iokit | sub_iokit_common | n` value with
 the high byte `0xE0`, so it is negative as an `int`. The code tables and the
 classification are in `codes.c3` (pure logic, tested on every platform); this
 module adds the `mach_error_string` text and the `raise`/`check` helpers.

 Sources for the text: Apple libsyscall `mach_error_string`, and the Rust `libc`
 crate's Apple bindings.
*>
module bleu::mach @feat(DARWIN);
import bleu::error, bleu::objc::codes;

<* `mach_error_string`: the standard text for a Mach error (libSystem). Returns a static string. *>
extern fn ZString mach_error_string(int error_value) @cname("mach_error_string");

<*
 Raise a Mach or IOKit return code as a Bleu fault. The detail records the code
 with `Domain.MACH`; the message holds `context` and the `mach_error_string` text.
 The classification is `codes::classify_mach`.

 return mach::raise_code(result, "IOServiceOpen")~;

 @param code : "The kern_return_t or IOReturn value (non-zero)"
 @param context : "What the caller was doing"
*>
fn fault raise_code(int code, ZString context)
{
	return error::raise(
		codes::classify_mach(code),
		error::Domain.MACH,
		code,
		"%s: %s",
		context,
		mach_error_string(code)
	);
}

<*
 Succeed on `KERN_SUCCESS`/`kIOReturnSuccess`; otherwise raise the code, which
 classifies as described in `codes::classify_mach`.
*>
fn void? check(int code, ZString context)
{
	if (code == 0) return;
	return raise_code(code, context)~;
}