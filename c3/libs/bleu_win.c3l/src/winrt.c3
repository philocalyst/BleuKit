<*
 Minimal WinRT bring-up: `RoInitialize`, activation factories, the
 `IInspectable` and `IAsyncInfo` vtables, and waiting for asynchronous work
 without deadlocking the calling apartment.

 Sources: roapi.h, inspectable.h, asyncinfo.h (mingw-w64; Wine
 `include/roapi.idl`, `inspectable.idl`, `asyncinfo.idl`), and Microsoft Learn
 "RoInitialize" (Library RuntimeObject.lib), "IInspectable", "IAsyncInfo".
 Slot numbers: docs/research/bleu_win.md, section 4.

 Threads: `enter` and `Runtime.leave` must run on the same thread. A thread
 that initialised WinRT as single-threaded (STA) receives its completions as
 window messages, so `wait_async` pumps messages while it waits.
*>
module bleu::win::winrt @feat(WIN32) @link("runtimeobject");
import std::time;
import bleu::error, bleu::deadline;
import bleu::win::com, bleu::win::com_ptr, bleu::win::guid, bleu::win::hresult;
import bleu::win::errors, bleu::win::hstring, bleu::win::message_loop;

<* `IID_IInspectable` (inspectable.h; Wine inspectable.idl). *>
const Guid IID_IINSPECTABLE = guid::guid("af86e2e0-b12d-4c6a-9c5a-d7aa65101e90");
<* `IID_IAsyncInfo` (asyncinfo.h; Wine asyncinfo.idl). *>
const Guid IID_IASYNCINFO   = guid::guid("00000036-0000-0000-c000-000000000046");

<* `RO_INIT_SINGLETHREADED` (roapi.h): WinRT on a single-threaded apartment. *>
const uint RO_INIT_SINGLETHREADED = 0;
<* `RO_INIT_MULTITHREADED` (roapi.h): WinRT on the multithreaded apartment. *>
const uint RO_INIT_MULTITHREADED  = 1;

<* `TrustLevel` of a runtime class (inspectable.idl). *>
enum TrustLevel : int
{
	BASE_TRUST,
	PARTIAL_TRUST,
	FULL_TRUST,
}

<*
 `AsyncStatus` (asyncinfo.idl). The values are in the order of the enum in
 the Windows Runtime; `ERRORED` is the IDL's `Error`, renamed because `ERROR`
 names a Win32 macro in C code.
*>
enum AsyncStatus : int
{
	STARTED,
	COMPLETED,
	CANCELED,
	ERRORED,
}

alias GetIidsFn = fn hresult::Hresult(void* self, uint* count, Guid** iids);
alias GetRuntimeClassNameFn = fn hresult::Hresult(void* self, void** class_name);
alias GetTrustLevelFn = fn hresult::Hresult(void* self, TrustLevel* level);

<*
 The vtable of `IInspectable`: `IUnknown` (slots 0-2), then GetIids (3),
 GetRuntimeClassName (4), GetTrustLevel (5).
*>
struct IInspectableVtbl
{
	com::QueryInterfaceFn query_interface;
	com::AddRefFn add_ref;
	com::ReleaseFn release;
	GetIidsFn get_iids;
	GetRuntimeClassNameFn get_runtime_class_name;
	GetTrustLevelFn get_trust_level;
}

<* An `IInspectable` object: a pointer to its vtable. *>
struct IInspectable
{
	IInspectableVtbl* vtbl;
}

alias GetIdFn = fn hresult::Hresult(void* self, uint* id);
alias GetStatusFn = fn hresult::Hresult(void* self, AsyncStatus* status);
alias GetErrorCodeFn = fn hresult::Hresult(void* self, hresult::Hresult* error_code);
alias CancelFn = fn hresult::Hresult(void* self);
alias CloseFn = fn hresult::Hresult(void* self);

<*
 The vtable of `IAsyncInfo`: `IInspectable` (slots 0-5), then get_Id (6),
 get_Status (7), get_ErrorCode (8), Cancel (9), Close (10).
*>
struct IAsyncInfoVtbl
{
	com::QueryInterfaceFn query_interface;
	com::AddRefFn add_ref;
	com::ReleaseFn release;
	GetIidsFn get_iids;
	GetRuntimeClassNameFn get_runtime_class_name;
	GetTrustLevelFn get_trust_level;
	GetIdFn get_id;
	GetStatusFn get_status;
	GetErrorCodeFn get_error_code;
	CancelFn cancel;
	CloseFn close;
}

<* An `IAsyncInfo` object: a pointer to its vtable. *>
struct IAsyncInfo
{
	IAsyncInfoVtbl* vtbl;
}

<* WinRT initialised on the calling thread, released by `leave`. *>
struct Runtime
{
	bool owned;
}

extern fn hresult::Hresult roInitialize(uint init_type) @cname("RoInitialize");
extern fn void roUninitialize() @cname("RoUninitialize");
extern fn hresult::Hresult roGetActivationFactory(
	void* class_id,
	Guid* iid,
	void** out
) @cname("RoGetActivationFactory");

<*
 Initialise WinRT on the calling thread. Single-threaded for `STA`, multithreaded
 for `MTA`.

 @return "The runtime, to be `leave`d on this thread"
 @return? error::INVALID_STATE : "The thread already uses the other concurrency model"
*>
fn Runtime? enter(com::Model model)
{
	uint init_type      = model == com::Model.MULTI_THREADED ? RO_INIT_MULTITHREADED : RO_INIT_SINGLETHREADED;
	hresult::Hresult hr = (hresult::Hresult)roInitialize(init_type);
	if (hr == (hresult::Hresult)hresult::S_OK || hr == (hresult::Hresult)hresult::S_FALSE) return { .owned = true };
	if (hr == (hresult::Hresult)hresult::RPC_E_CHANGED_MODE)
	{
		return error::raise(
			error::INVALID_STATE,
			error::Domain.WIN32,
			(int)hr,
			"this thread already uses the other WinRT concurrency model"
		)~;
	}
	return errors::raise_hresult(hr, "RoInitialize")~;
}

<* Balance a successful `enter` on the same thread. Safe to call twice. *>
fn void Runtime.leave(&self)
{
	if (!self.owned) return;
	roUninitialize();
	self.owned = false;
}

<* Current status of an `IAsyncInfo`. *>
fn AsyncStatus? status_of(IAsyncInfo* info)
{
	AsyncStatus status;
	hresult::Hresult hr = (hresult::Hresult)info.vtbl.get_status(info, &status);
	if (hr.failed()) return errors::raise_hresult(hr, "IAsyncInfo.get_Status")~;
	return status;
}

<* How long each wait for messages lasts before the status is read again. *>
// Ten milliseconds, in the microseconds that `Duration` counts.
const time::Duration ASYNC_POLL_SLICE = (time::Duration)10_000;

<*
 Wait for an asynchronous operation to leave `STARTED` and return the status it
 finished with. `operation` is any WinRT async object (IAsyncAction,
 IAsyncOperation<T>, ...); the status comes from its `IAsyncInfo` facet.

 The wait does not block the thread: it pumps the thread's messages, so an
 STA receives the completion it is waiting for. A blocking wait here would
 deadlock an STA whose completion is posted to its own message queue.

 Read the result afterwards with the operation's `GetResults`; a `ERRORED`
 status carries its HRESULT in `IAsyncInfo.ErrorCode`.

 @param operation : "An owned pointer to the async object; it is not released"
 @param timeout : "How long to wait; `time::FOREVER` waits without limit"
 @return "The final status: COMPLETED, CANCELED or ERRORED"
 @return? TIMEOUT : "The operation was still running at the deadline"
*>
fn AsyncStatus? wait_async(com_ptr::Com{com::IUnknown}* operation, time::Duration timeout)
{
	com_ptr::Com{IAsyncInfo} info = com_ptr::query_interface{com::IUnknown, IAsyncInfo}(operation, IID_IASYNCINFO)!;
	defer info.release();
	Deadline deadline = deadline::after(timeout);
	while (true)
	{
		AsyncStatus status = status_of(info.ptr)!;
		if (status != AsyncStatus.STARTED) return status;
		if (deadline.expired()) return error::raise(
			TIMEOUT,
			error::Domain.INTERNAL,
			0,
			"async operation still running"
		)~;
		time::Duration slice = deadline.remaining();
		if (slice > ASYNC_POLL_SLICE) slice = ASYNC_POLL_SLICE;
		message_loop::pump(slice)!;
	}
}

module bleu::win::winrt <Target>;
import bleu::error;
import bleu::win::com_ptr, bleu::win::guid, bleu::win::hresult, bleu::win::errors, bleu::win::hstring;

<*
 The activation factory of runtime class `class_name` (for example
 "Windows.Foundation.Uri"), as interface `Target` whose IID is `iid`.

 @param class_name : "The runtime class's full name"
 @return "An owning pointer to the factory"
 @return? error::UNAVAILABLE : "The class is not registered on this system"
*>
fn com_ptr::Com{Target}? activation_factory(String class_name, Guid iid)
{
	hstring::Hstring name = hstring::create(class_name)!;
	defer name.close();
	void* raw           = null;
	hresult::Hresult hr = (hresult::Hresult)roGetActivationFactory(name.handle, &iid, &raw);
	if (hr.failed()) return errors::raise_hresult(hr, "RoGetActivationFactory")~;
	return { .ptr = (Target*)raw };
}