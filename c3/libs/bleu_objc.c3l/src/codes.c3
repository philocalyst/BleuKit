<*
 Mach, IOKit and NSError return codes, and their mapping to Bleu excuses.

 This module is pure data and logic: no Objective-C or CoreFoundation call, and
 no `@feat`, so every target compiles it and its `@test`s run on Linux. The
 Darwin-only modules (`mach`, `foundation`) call it.

 Sources (values, each checked against the header named):
 * `KERN_*`: Apple xnu `osfmk/mach/kern_return.h` (`KERN_RESOURCE_SHORTAGE` is 6).
 * `kIOReturn*` (`IO_*`): Apple xnu `iokit/IOKit/IOReturn.h` (`err_system(0x38)`,
   `iokit_common_err(n)`), and the Rust `io-kit-sys` 0.4.1 `src/ret.rs`.
 * `NSCocoaErrorDomain` codes: objc2-foundation `src/generated/FoundationErrors.rs`.
 * errno values: Apple xnu `bsd/sys/errno.h`.
 * `errAEEventNotPermitted` (-1743): objc2-core-services `src/generated/AE/AppleEvents.rs`.
*>
module bleu::objc::codes;
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

<*
 Classify a Mach or IOKit return code as a Bleu excuse. `KERN_SUCCESS` and
 `kIOReturnSuccess` have no excuse and must be filtered out by the caller.

 Permission refusals (`kIOReturnNotPermitted`, `kIOReturnNotPrivileged`,
 `KERN_NO_ACCESS`, `KERN_DENIED`) become `PERMISSION_DENIED`; absent devices and
 services become `NOT_FOUND`; timeouts `TIMEOUT`; busy resources `BUSY`.
 `KERN_RESOURCE_SHORTAGE` is a generic "not enough resources" and is reported as
 `NO_MEMORY`; the detail text keeps the Mach message. Anything without a clear
 class is `BACKEND_FAILURE`, with the text in the detail.
*>
fn fault classify_mach(int code)
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
		case MachCode.IO_BUSY:
		case MachCode.IO_EXCLUSIVE_ACCESS:
			return error::BUSY;
		case MachCode.KERN_RESOURCE_SHORTAGE:
		case MachCode.IO_NO_MEMORY:
			return error::NO_MEMORY;
		case MachCode.KERN_NOT_SUPPORTED:
		case MachCode.IO_UNSUPPORTED:
			return error::UNSUPPORTED;
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

<* `NSCocoaErrorDomain` (exported `NSString` constant). *>
const ZString COCOA_ERROR_DOMAIN     = "NSCocoaErrorDomain";
<* `NSPOSIXErrorDomain`: the code is an errno. *>
const ZString POSIX_ERROR_DOMAIN     = "NSPOSIXErrorDomain";
<* `NSOSStatusErrorDomain`: the code is an OSStatus. *>
const ZString OS_STATUS_ERROR_DOMAIN = "NSOSStatusErrorDomain";

<* CocoaError codes that map to a Bleu excuse (objc2-foundation FoundationErrors.rs). *>
const long COCOA_FILE_NO_SUCH_FILE        = 4;
<* `NSFileLockingError` (255). *>
const long COCOA_FILE_LOCKING             = 255;
<* `NSFileReadNoPermissionError` (257). *>
const long COCOA_FILE_READ_NO_PERMISSION  = 257;
<* `NSFileReadNoSuchFileError` (260). *>
const long COCOA_FILE_READ_NO_SUCH_FILE   = 260;
<* `NSFileWriteNoPermissionError` (513). *>
const long COCOA_FILE_WRITE_NO_PERMISSION = 513;
<* `NSUserCancelledError` (3072). *>
const long COCOA_USER_CANCELLED           = 3072;
<* `NSFeatureUnsupportedError` (3328). *>
const long COCOA_FEATURE_UNSUPPORTED      = 3328;

<* errno values on Darwin (xnu bsd/sys/errno.h). *>
const long POSIX_EPERM     = 1;
<* errno `ENOENT` on Darwin. *>
const long POSIX_ENOENT    = 2;
<* errno `ENOMEM` on Darwin. *>
const long POSIX_ENOMEM    = 12;
<* errno `EACCES` on Darwin. *>
const long POSIX_EACCES    = 13;
<* errno `EBUSY` on Darwin. *>
const long POSIX_EBUSY     = 16;
<* errno `EINVAL` on Darwin. *>
const long POSIX_EINVAL    = 22;
<* errno `ENOTSUP` on Darwin. *>
const long POSIX_ENOTSUP   = 45;
<* errno `ETIMEDOUT` on Darwin. *>
const long POSIX_ETIMEDOUT = 60;
<* errno `ECANCELED` on Darwin. *>
const long POSIX_ECANCELED = 89;

<*
 `errAEEventNotPermitted`: AppleEvents refused, which is how a missing
 Automation (TCC) grant appears to AppleScript (objc2-core-services, value -1743).
*>
const long OS_STATUS_AE_EVENT_NOT_PERMITTED = -1743;

<*
 Classify an NSError by its domain and code. The mapping is deliberately small:
 only codes whose meaning is unambiguous get a specific excuse, and everything
 else is `BACKEND_FAILURE` with the text preserved in the detail.

 Permission (TCC, file ACL, AppleEvents) maps to `PERMISSION_DENIED`; a missing
 file, device or service to `NOT_FOUND`; a POSIX timeout to `TIMEOUT`; a
 cancelled dialog to `CANCELLED`; a feature the OS does not have to `UNSUPPORTED`.
*>
fn fault classify_ns(String domain, long code)
{
	if (domain == COCOA_ERROR_DOMAIN)
	{
		switch (code)
		{
			case COCOA_FILE_NO_SUCH_FILE:
			case COCOA_FILE_READ_NO_SUCH_FILE:
				return NOT_FOUND;
			case COCOA_FILE_READ_NO_PERMISSION:
			case COCOA_FILE_WRITE_NO_PERMISSION:
				return error::PERMISSION_DENIED;
			case COCOA_FILE_LOCKING:
				return error::BUSY;
			case COCOA_USER_CANCELLED:
				return error::CANCELLED;
			case COCOA_FEATURE_UNSUPPORTED:
				return error::UNSUPPORTED;
			default:
				return error::BACKEND_FAILURE;
		}
	}
	if (domain == POSIX_ERROR_DOMAIN)
	{
		switch (code)
		{
			case POSIX_EPERM:
			case POSIX_EACCES:
				return error::PERMISSION_DENIED;
			case POSIX_ENOENT:
				return NOT_FOUND;
			case POSIX_EBUSY:
				return error::BUSY;
			case POSIX_EINVAL:
				return error::INVALID_ARGUMENT;
			case POSIX_ENOMEM:
				return error::NO_MEMORY;
			case POSIX_ENOTSUP:
				return error::UNSUPPORTED;
			case POSIX_ETIMEDOUT:
				return TIMEOUT;
			case POSIX_ECANCELED:
				return error::CANCELLED;
			default:
				return error::BACKEND_FAILURE;
		}
	}
	if (domain == OS_STATUS_ERROR_DOMAIN && code == OS_STATUS_AE_EVENT_NOT_PERMITTED) return error::PERMISSION_DENIED;
	return error::BACKEND_FAILURE;
}
