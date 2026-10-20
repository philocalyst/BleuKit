<*
 The C ABI of Bleu: plain C functions, opaque handles and plain structs. The
 header is generated from this library by `tools/capi/genheader.py`; the
 conventions are in `docs/CAPI.md`.

 Every exported function runs its body through `@capi_entry` (any thread may call
 it), returns a `bleu_status_t` unless it is one of the documented accessors, and
 gives results through out-parameters that are set to NULL on failure. C3 faults,
 optionals and slices never cross the boundary.
*>
module bleu::capi;
import bleu::error, bleu::availability;

<*
 Version of this C ABI. Compare it with BLEU_ABI_VERSION from the header you
 compiled against. It is bumped whenever an entry point, a struct member or an
 enumerator is appended, and never reused.
*>
const uint ABI_VERSION = 1;

<* Bytes of `bleu_error_detail_t.message`, including the terminating NUL. *>
const usz ERROR_MESSAGE_CAPACITY = 256;

<* Bytes of `bleu_capability_t.note`, including the terminating NUL. *>
const usz CAPABILITY_NOTE_CAPACITY = 128;

<*
 The result of every fallible entry point. The numbers are the ordinals of
 `bleu::error::Status`, the same wire contract IPC uses: append only. A unit test
 checks that the two enums keep the same members in the same order.
*>
enum CStatus : int @export("bleu_status_t")
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
 The phase of an operation, mirroring `bleu::operation::Phase` (same members, same
 order, copied out of the generic type so that C sees one name).
*>
enum OperationPhase : char @export("bleu_operation_phase_t")
{
	PENDING,
	RUNNING,
	SUCCEEDED,
	FAILED,
	CANCELLED,
}

<*
 What went wrong on the calling thread: the status, the subsystem that produced
 the native code, that code, and a NUL-terminated message (truncated if longer).
*>
struct ErrorDetail @export("bleu_error_detail_t")
{
	CStatus status;
	error::Domain domain;
	int native_code;
	char[ERROR_MESSAGE_CAPACITY] message;
}

<*
 One capability of a service: `reason` is `AVAILABLE` (or `DEGRADED`, which still
 works), otherwise why it is not available. `note` is a NUL-terminated sentence.
*>
struct Capability @export("bleu_capability_t")
{
	availability::Reason reason;
	char[CAPABILITY_NOTE_CAPACITY] note;
}

<* Copy a thread's failure details into the C layout. *>
fn void fill_detail(ErrorDetail* out, error::Detail* detail)
{
	out.status = (CStatus)(int)detail.status;
	out.domain = detail.domain;
	out.native_code = detail.code;
	usz length = min((usz)detail.len, ERROR_MESSAGE_CAPACITY - 1);
	if (length > 0) mem::copy(&out.message, &detail.text, (sz)length);
	out.message[length] = 0;
}

<* Copy a capability's availability into the C layout, truncating its note. *>
fn void fill_capability(Capability* out, availability::Availability value)
{
	out.reason = value.reason;
	usz length = min((usz)value.note.len, CAPABILITY_NOTE_CAPACITY - 1);
	if (length > 0) mem::copy(&out.note, value.note.ptr, (sz)length);
	out.note[length] = 0;
}

<* Map an operation phase's ordinal (identical in every service) onto the C enum. *>
fn OperationPhase phase_from_ordinal(usz ordinal) => (OperationPhase)(char)ordinal;

<*
 The ABI version this library implements. It equals `BLEU_ABI_VERSION` in the
 header generated from the same sources.
*>
fn uint bleu_abi_version() @export("bleu_abi_version")
{
	@capi_scope()
	{
		return ABI_VERSION;
	};
}

<*
 The name of a status code, such as "NOT_FOUND". Unknown numbers give "INVALID".
 The string is static and must not be freed.
*>
fn ZString bleu_status_name(int status) @export("bleu_status_name")
{
	@capi_scope()
	{
		if (status < 0 || status > (int)CStatus.UNKNOWN.ordinal) return "INVALID";
		switch ((CStatus)status)
		{
			case CStatus.OK: return "OK";
			case CStatus.UNSUPPORTED: return "UNSUPPORTED";
			case CStatus.UNAVAILABLE: return "UNAVAILABLE";
			case CStatus.PERMISSION_DENIED: return "PERMISSION_DENIED";
			case CStatus.AUTH_REQUIRED: return "AUTH_REQUIRED";
			case CStatus.NOT_FOUND: return "NOT_FOUND";
			case CStatus.INVALID_ARGUMENT: return "INVALID_ARGUMENT";
			case CStatus.INVALID_STATE: return "INVALID_STATE";
			case CStatus.BUSY: return "BUSY";
			case CStatus.TIMEOUT: return "TIMEOUT";
			case CStatus.CANCELLED: return "CANCELLED";
			case CStatus.DISCONNECTED: return "DISCONNECTED";
			case CStatus.PROTOCOL: return "PROTOCOL";
			case CStatus.BACKEND_FAILURE: return "BACKEND_FAILURE";
			case CStatus.OUT_OF_RANGE: return "OUT_OF_RANGE";
			case CStatus.NO_MEMORY: return "NO_MEMORY";
			case CStatus.UNKNOWN: return "UNKNOWN";
		}
	};
}

<*
 Copy the most recent failure of the calling thread into `out`. The call itself
 returns OK. Every other entry point clears the record on entry, so it describes
 the last call made on this thread, not an older one. Operation failures are
 copied here by `bleu_operation_wait`.
*>
fn CStatus bleu_last_error(ErrorDetail* out) @export("bleu_last_error")
{
	@capi_scope()
	{
		if (!out) return CStatus.INVALID_ARGUMENT;
		fill_detail(out, error::last());
		return CStatus.OK;
	};
}

<*
 Free a buffer that this library returned (JSON text, a backend name). Passing
 NULL does nothing.
*>
fn void bleu_free(void* memory) @export("bleu_free")
{
	@capi_scope()
	{
		if (memory) alloc::free(mem, memory);
	};
}