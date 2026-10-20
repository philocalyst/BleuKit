<*
 Mach `kern_return_t` and IOKit `IOReturn` codes, and their mapping to Bleu excuses.

 Both are `int`s. An IOKit code is a `sys_iokit | sub_iokit_common | n` value with
 the high byte `0xE0`, so it is negative as an `int`; the constants here are
 written as `uint` to avoid that sign question. Sources:
 * Apple xnu `iokit/IOKit/IOReturn.h` (`err_system(0x38)` = 0xE0000000,
 `iokit_common_err(n)`) and `osfmk/mach/kern_return.h` (KERN_* values);
 * the Rust `io-kit-sys` 0.4.1 crate `src/ret.rs` (same `kIOReturn*` values) and
 the `libc` crate's Apple bindings (`mach_error_string`).
*>
module bleu::mach @feat(DARWIN);
import bleu::error;

<*
 The Mach and IOKit return codes Bleu classifies, with the names of their header
 macros: `KERN_*` (osfmk/mach/kern_return.h) and `IO_*` for `kIOReturn*` (IOReturn.h).
 A `constset` so one `switch` covers both families. Values are the codes as `uint`.
*>
constset MachCode : uint
{
	KERN_SUCCESS             = 0,
	KERN_NO_SPACE            = 3,
	KERN_INVALID_ARGUMENT    = 4,
	KERN_FAILURE             = 5,
	KERN_RESOURCE_SHORTAGE   = 6,
	KERN_NO_ACCESS           = 8,
	KERN_ABORTED             = 14,
	KERN_NOT_SUPPORTED       = 46,
	KERN_OPERATION_TIMED_OUT = 49,
	KERN_DENIED              = 53,
	KERN_NOT_FOUND           = 56,
	IO_SUCCESS               = 0,
	IO_ERROR                 = 0xE00002BC,
	IO_NO_MEMORY             = 0xE00002BD,
	IO_NO_RESOURCES          = 0xE00002BE,
	IO_IPC_ERROR             = 0xE00002BF,
	IO_NO_DEVICE             = 0xE00002C0,
	IO_NOT_PRIVILEGED        = 0xE00002C1,
	IO_BAD_ARGUMENT          = 0xE00002C2,
	IO_EXCLUSIVE_ACCESS      = 0xE00002C5,
	IO_UNSUPPORTED           = 0xE00002C7,
	IO_INTERNAL_ERROR        = 0xE00002C9,
	IO_IO_ERROR              = 0xE00002CA,
	IO_NOT_OPEN              = 0xE00002CD,
	IO_BUSY                  = 0xE00002D5,
	IO_TIMEOUT               = 0xE00002D6,
	IO_OFFLINE               = 0xE00002D7,
	IO_NOT_READY             = 0xE00002D8,
	IO_NOT_ATTACHED          = 0xE00002D9,
	IO_NOT_PERMITTED         = 0xE00002E2,
	IO_NO_POWER              = 0xE00002E3,
	IO_NO_MEDIA              = 0xE00002E4,
	IO_ABORTED               = 0xE00002EB,
	IO_NOT_RESPONDING        = 0xE00002ED,
	IO_NOT_FOUND             = 0xE00002F0,
}

<* `mach_error_string`: the standard text for a Mach error (libSystem). Returns a static string. *>
extern fn ZString mach_error_string(int error_value) @cname("mach_error_string");

<*
 Classify a Mach or IOKit return code as a Bleu excuse. `KERN_SUCCESS` and
 `kIOReturnSuccess` have no excuse and must be filtered out by the caller.

 Permission refusals (`kIOReturnNotPermitted`, `kIOReturnNotPrivileged`,
 `KERN_NO_ACCESS`, `KERN_DENIED`) become `PERMISSION_DENIED`; absent devices and
 services become `NOT_FOUND`; timeouts `TIMEOUT`; busy resources `BUSY`.
 Anything without a clear class is `BACKEND_FAILURE`, with the text in the detail.
*>
fn fault classify(int code)
{
	switch ((MachCode)(uint)code)
	{
		case MachCode.KERN_INVALID_ARGUMENT:
		case MachCode.IO_BAD_ARGUMENT:
			return error::INVALID_ARGUMENT;
		case MachCode.KERN_NO_ACCESS:
		case MachCode.KERN_DENIED:
		case MachCode.IO_NOT_PERMITTED:
		case MachCode.IO_NOT_PRIVILEGED:
			return error::PERMISSION_DENIED;
		case MachCode.KERN_NOT_FOUND:
		case MachCode.IO_NO_DEVICE:
		case MachCode.IO_NOT_FOUND:
			return NOT_FOUND;
		case MachCode.KERN_OPERATION_TIMED_OUT:
		case MachCode.IO_TIMEOUT:
			return TIMEOUT;
		case MachCode.KERN_ABORTED:
		case MachCode.IO_ABORTED:
			return error::CANCELLED;
		case MachCode.KERN_RESOURCE_SHORTAGE:
		case MachCode.IO_BUSY:
		case MachCode.IO_EXCLUSIVE_ACCESS:
			return error::BUSY;
		case MachCode.KERN_NOT_SUPPORTED:
		case MachCode.IO_UNSUPPORTED:
			return error::UNSUPPORTED;
		case MachCode.IO_NO_MEMORY:
			return error::NO_MEMORY;
		case MachCode.IO_NOT_OPEN:
		case MachCode.IO_NOT_ATTACHED:
			return error::INVALID_STATE;
		case MachCode.IO_OFFLINE:
		case MachCode.IO_NOT_READY:
		case MachCode.IO_NO_POWER:
		case MachCode.IO_NO_MEDIA:
			return error::UNAVAILABLE;
		case MachCode.IO_IPC_ERROR:
		case MachCode.IO_NOT_RESPONDING:
			return error::DISCONNECTED;
		default:
			return error::BACKEND_FAILURE;
	}
}

<*
 Raise a Mach or IOKit return code as a Bleu fault. The detail records the code
 with `Domain.MACH`; the message holds `context` and the `mach_error_string` text.

 return mach::raise_code(result, "IOServiceOpen")~;

 @param code : "The kern_return_t or IOReturn value (non-zero)"
 @param context : "What the caller was doing"
*>
fn fault raise_code(int code, ZString context)
{
	return error::raise(classify(code), error::Domain.MACH, code, "%s: %s", context, mach_error_string(code));
}

<*
 Succeed on `KERN_SUCCESS`/`kIOReturnSuccess`; otherwise raise the code, which
 classifies as described in `classify`.
*>
fn void? check(int code, ZString context)
{
	if (code == 0) return;
	return raise_code(code, context)~;
}