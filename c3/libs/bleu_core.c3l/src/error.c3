<*
 The one error vocabulary shared by every Bleu service.

 `NOT_FOUND` ("the named device/network/object does not exist") and `TIMEOUT`
 ("the peer or the OS did not answer in time") are the standard library's own
 built-in excuses and are reused as-is, so they read the same everywhere.

 Faults classify *what kind* of thing went wrong. The *details* (which OS call,
 which native code, a human-readable message) travel out of band in `Detail`,
 retrievable with `error::last()` on the thread that observed the failure.
 Always raise with `error::raise` rather than a bare `FAULT~` when there is
 anything useful to say.
*>
module bleu::error;

excuse
	UNSUPPORTED,       // This platform or backend can never do this
	UNAVAILABLE,       // Could do it, but the service/hardware is absent or off right now
	PERMISSION_DENIED, // The OS refused (polkit, TCC, entitlement, ACL ...)
	AUTH_REQUIRED,     // A credential or user interaction is needed to continue
	INVALID_ARGUMENT,  // The caller supplied something out of contract
	INVALID_STATE,     // The object is not in a state where this operation applies
	BUSY,              // Another operation holds the resource
	CANCELLED,         // The operation was cancelled by the caller
	DISCONNECTED,      // The connection to the backend went away
	PROTOCOL,          // The peer sent something that violates its protocol
	BACKEND_FAILURE,   // The OS or daemon reported a failure with no better class
	OUT_OF_RANGE,      // A value does not fit the device or API range
	NO_MEMORY;         // An allocation failed

<*
 Stable numeric form of every fault, for the C ABI and for IPC. The ordinal is
 part of the wire contract: append new values at the end, never reorder.
*>
enum Status : int
{
	OK,
	UNSUPPORTED,
	UNAVAILABLE,
	PERMISSION_DENIED,
	AUTH_REQUIRED,
	NOT_FOUND,
	INVALID_ARGUMENT,
	INVALID_STATE,
	BUSY,
	TIMEOUT,
	CANCELLED,
	DISCONNECTED,
	PROTOCOL,
	BACKEND_FAILURE,
	OUT_OF_RANGE,
	NO_MEMORY,
	UNKNOWN,
}

<*
 Which subsystem produced the native code in a `Detail`.
*>
enum Domain : char
{
	NONE,
	ERRNO,       // POSIX errno
	WIN32,       // GetLastError / HRESULT
	MACH,        // kern_return_t / IOReturn
	NS_ERROR,    // NSError code (domain in the text)
	DBUS,        // D-Bus error (name in the text)
	WAYLAND,     // wl_display protocol error
	PULSE,       // PulseAudio protocol error
	COMPOSITOR,  // compositor IPC error reply
	INTERNAL,    // raised by Bleu itself
}

const DETAIL_TEXT_CAPACITY = 240;

<*
 Out-of-band context for the most recent failure raised on this thread.
*>
struct Detail
{
	Status status;
	Domain domain;
	int    code;
	sz     len;
	char[DETAIL_TEXT_CAPACITY] text;
}

fn String Detail.message(&self) => (String)self.text[:self.len];

tlocal Detail last_detail;

<*
 Record the details of a failure on the current thread and hand back `f`,
 ready to be returned with `~`:

     return error::raise(NOT_FOUND, ERRNO, errno, "no such backlight '%s'", name)~;

 @param f : "Classification of the failure"
 @param domain : "Subsystem the native code belongs to"
 @param code : "Native error number, 0 when there is none"
 @param fmt : "Message; truncated to fit the detail buffer"
 @return "The fault passed in"
*>
fn fault raise(fault f, Domain domain, int code, String fmt, args...) @format(3)
{
	Detail* d = &last_detail;
	d.status = status_of(f);
	d.domain = domain;
	d.code = code;
	@pool()
	{
		String text = string::tformat(fmt, ...args);
		d.len = min(text.len, DETAIL_TEXT_CAPACITY);
		mem::copy(&d.text, text.ptr, d.len);
	};
	return f;
}

<*
 Details of the most recent failure raised on this thread.
*>
fn Detail* last() => &last_detail;

<*
 Map a fault onto its stable numeric code. Foreign faults (for instance
 `io::FILE_NOT_FOUND` from the standard library) map to `UNKNOWN`.
*>
fn Status status_of(fault f)
{
	switch (f)
	{
		case UNSUPPORTED:       return UNSUPPORTED;
		case UNAVAILABLE:       return UNAVAILABLE;
		case PERMISSION_DENIED: return PERMISSION_DENIED;
		case AUTH_REQUIRED:     return AUTH_REQUIRED;
		case NOT_FOUND:         return NOT_FOUND;
		case INVALID_ARGUMENT:  return INVALID_ARGUMENT;
		case INVALID_STATE:     return INVALID_STATE;
		case BUSY:              return BUSY;
		case TIMEOUT:           return TIMEOUT;
		case CANCELLED:         return CANCELLED;
		case DISCONNECTED:      return DISCONNECTED;
		case PROTOCOL:          return PROTOCOL;
		case BACKEND_FAILURE:   return BACKEND_FAILURE;
		case OUT_OF_RANGE:      return OUT_OF_RANGE;
		case NO_MEMORY:         return NO_MEMORY;
		default:                return UNKNOWN;
	}
}

<*
 Inverse of `status_of`. `OK` has no fault, so it is not representable.

 @require status != OK : "OK is the absence of a fault"
*>
fn fault fault_of(Status status)
{
	switch (status)
	{
		case OK:                unreachable("OK has no fault");
		case UNSUPPORTED:       return UNSUPPORTED;
		case UNAVAILABLE:       return UNAVAILABLE;
		case PERMISSION_DENIED: return PERMISSION_DENIED;
		case AUTH_REQUIRED:     return AUTH_REQUIRED;
		case NOT_FOUND:         return NOT_FOUND;
		case INVALID_ARGUMENT:  return INVALID_ARGUMENT;
		case INVALID_STATE:     return INVALID_STATE;
		case BUSY:              return BUSY;
		case TIMEOUT:           return TIMEOUT;
		case CANCELLED:         return CANCELLED;
		case DISCONNECTED:      return DISCONNECTED;
		case PROTOCOL:          return PROTOCOL;
		case BACKEND_FAILURE:   return BACKEND_FAILURE;
		case OUT_OF_RANGE:      return OUT_OF_RANGE;
		case NO_MEMORY:         return NO_MEMORY;
		case UNKNOWN:           return BACKEND_FAILURE;
	}
}
