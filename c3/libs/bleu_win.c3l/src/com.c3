<*
 COM on Windows: the apartment a thread lives in, the `IUnknown` contract, and
 the GUIDs every COM user needs.

 Every vtable in Bleu starts with the three `IUnknown` slots, in this order:
 `QueryInterface` (0), `AddRef` (1), `Release` (2). Source: mingw-w64
 `unknwn.h` (`IUnknownVtbl` and `IID_IUnknown`) and Microsoft Learn "IUnknown"
 (https://learn.microsoft.com/en-us/windows/win32/api/unknwn/nn-unknwn-iunknown).

 Threads: `enter` and `Apartment.leave` must run on the same thread.
*>
module bleu::win::com @feat(WIN32) @link("ole32");
import std::os::win32;
import bleu::error, bleu::win::guid, bleu::win::hresult, bleu::win::errors;

<* `IID_IUnknown` (unknwn.h; Wine include/unknwn.idl). *>
const Guid IID_IUNKNOWN     = guid::guid("00000000-0000-0000-c000-000000000046");
<*
 `IID_IAgileObject`: "this object may be called from any apartment". Source:
 objidl.h (mingw-w64; Wine include/objidl.idl), Microsoft Learn "IAgileObject".
*>
const Guid IID_IAGILEOBJECT = guid::guid("94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90");

<* `COINIT_MULTITHREADED`: the multithreaded apartment (MTA). objbase.h. *>
const uint COINIT_MULTITHREADED     = 0x0;
<* `COINIT_APARTMENTTHREADED`: a single-threaded apartment (STA). objbase.h. *>
const uint COINIT_APARTMENTTHREADED = 0x2;
<* `CLSCTX_INPROC_SERVER`, in-process server. wtypesbase.h. *>
const uint CLSCTX_INPROC_SERVER     = 0x1;
<* `CLSCTX_INPROC_HANDLER`, in-process handler. wtypesbase.h. *>
const uint CLSCTX_INPROC_HANDLER    = 0x2;
<* `CLSCTX_LOCAL_SERVER`, out-of-process server on this machine. wtypesbase.h. *>
const uint CLSCTX_LOCAL_SERVER      = 0x4;
<* `CLSCTX_REMOTE_SERVER`, server on another machine. wtypesbase.h. *>
const uint CLSCTX_REMOTE_SERVER     = 0x10;
<* `CLSCTX_ALL`, every context above. combaseapi.h. *>
const uint CLSCTX_ALL               = CLSCTX_INPROC_SERVER | CLSCTX_INPROC_HANDLER | CLSCTX_LOCAL_SERVER
	| CLSCTX_REMOTE_SERVER;

alias QueryInterfaceFn = fn hresult::Hresult(void* self, Guid* iid, void** out);
alias AddRefFn = fn uint(void* self);
alias ReleaseFn = fn uint(void* self);

<* The vtable of `IUnknown`: slots 0, 1 and 2. Every interface vtable begins with it. *>
struct IUnknownVtbl
{
	QueryInterfaceFn query_interface;
	AddRefFn add_ref;
	ReleaseFn release;
}

<* Any COM object: a pointer to its vtable. Interface structs embed this as the first member. *>
struct IUnknown
{
	IUnknownVtbl* vtbl;
}

<* The COM threading model of an apartment. *>
enum Model : char
{
	SINGLE_THREADED, // STA, `COINIT_APARTMENTTHREADED`: calls arrive as window messages
	MULTI_THREADED,  // MTA, `COINIT_MULTITHREADED`: calls may arrive on any thread
}

<*
 A thread's COM initialisation, released by `leave`. `owned` is false only
 when `enter` failed; a successful `enter` is always balanced by `leave`,
 including the `hresult::S_FALSE` case where the thread was already initialised.
*>
struct Apartment
{
	bool owned;
}

extern fn Win32_HRESULT coInitializeEx(void* reserved, Win32_DWORD flags) @cname("CoInitializeEx");
extern fn void coUninitialize() @cname("CoUninitialize");
extern fn Win32_HRESULT coCreateInstance(
	Guid* clsid,
	void* outer,
	Win32_DWORD context,
	Guid* iid,
	void** out
) @cname("CoCreateInstance");

<*
 Initialise COM on the calling thread with the given model.

 @param model : "The apartment model to join"
 @return "An apartment that must be `leave`d on this thread"
 @return? error::INVALID_STATE : "The thread already uses the other apartment model"
 @return? error::BACKEND_FAILURE : "CoInitializeEx failed for another reason"
*>
fn Apartment? enter(Model model)
{
	uint flags          = model == MULTI_THREADED ? COINIT_MULTITHREADED : COINIT_APARTMENTTHREADED;
	hresult::Hresult hr = (hresult::Hresult)coInitializeEx(null, flags);
	if (hr == (hresult::Hresult)hresult::S_OK || hr == (hresult::Hresult)hresult::S_FALSE) return { .owned = true };
	if (hr == (hresult::Hresult)hresult::RPC_E_CHANGED_MODE)
	{
		return error::raise(
			error::INVALID_STATE,
			error::Domain.WIN32,
			(int)hr,
			"this thread already uses the other COM apartment model"
		)~;
	}
	return errors::raise_hresult(hr, "CoInitializeEx")~;
}

<* Balance a successful `enter` on the same thread. Safe to call twice. *>
fn void Apartment.leave(&self)
{
	if (!self.owned) return;
	coUninitialize();
	self.owned = false;
}