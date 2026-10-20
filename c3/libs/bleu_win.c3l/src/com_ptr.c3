<*
 `Com{T}`: an owning pointer to a COM interface, released exactly once.

 The pointer's reference is the caller's. `release` gives it back; `retain`
 makes a second owning copy. `query_interface` and `co_create_instance` return
 a new owning pointer and fail with the fault of the HRESULT they got.

 A COM interface is any struct whose first member is `IUnknown.vtbl` (see
 `bleu::win::com`), so `Com{T}` can release any interface through `IUnknown`.

 C3 has no static methods and a method cannot take its own type parameter, so
 `query_interface` is a generic function over the source and target types:

 Com{IMMDevice}? device = com_ptr::query_interface{IMMDeviceEnumerator, IMMDevice}(&enumerator, com::IID_IUNKNOWN)!;
*>
module bleu::win::com_ptr @feat(WIN32);
import bleu::error, bleu::win::com, bleu::win::guid, bleu::win::hresult, bleu::win::errors;

<* An owning pointer to a COM interface `Target`. A null `ptr` owns nothing. *>
struct Com<Target>
{
	Target* ptr;
}

<* Release the owned reference and clear the pointer. Safe on a null pointer. *>
fn void Com.release(&self)
{
	if (!self.ptr) return;
	com::IUnknown* unknown = (com::IUnknown*)self.ptr;
	unknown.vtbl.release(unknown);
	self.ptr = null;
}

<* A second owning copy of this pointer: takes one more reference. *>
fn Com{Target} Com.retain(self)
{
	if (self.ptr)
	{
		com::IUnknown* unknown = (com::IUnknown*)self.ptr;
		unknown.vtbl.add_ref(unknown);
	}
	return self;
}

<* True when the pointer owns nothing. *>
fn bool Com.is_null(self) @inline => self.ptr == null;

module bleu::win::com_ptr <Target>;
import bleu::error, bleu::win::com, bleu::win::guid, bleu::win::hresult, bleu::win::errors;

<*
 `CoCreateInstance` for an object of class `clsid`, asked for interface `Target`
 whose IID is `iid`. Runs in-process, out-of-process or remotely (`CLSCTX_ALL`).

 @param clsid : "The class to create"
 @param iid : "The interface the caller wants, which is also `Target`"
 @return "An owning pointer to the new object's `Target` interface"
 @return? error::PERMISSION_DENIED : "Activation was refused by the system"
*>
fn Com{Target}? co_create_instance(Guid clsid, Guid iid)
{
	void* raw           = null;
	hresult::Hresult hr = (hresult::Hresult)com::coCreateInstance(&clsid, null, com::CLSCTX_ALL, &iid, &raw);
	if (hr.failed()) return errors::raise_hresult(hr, "CoCreateInstance")~;
	return { .ptr = (Target*)raw };
}

module bleu::win::com_ptr <Source, Target>;
import bleu::error, bleu::win::com, bleu::win::guid, bleu::win::hresult, bleu::win::errors;

<*
 `QueryInterface` from an owned `Source` pointer to interface `Target`, whose
 IID is `iid`. The source pointer keeps its own reference.

 @param source : "A pointer that owns a reference to a `Source` object"
 @param iid : "The IID of `Target`"
 @return "A new owning pointer to `Target`"
 @return? error::UNSUPPORTED : "The object does not implement `Target`"
*>
fn Com{Target}? query_interface(Com{Source}* source, Guid iid)
{
	if (!source.ptr) return error::raise(
		error::INVALID_ARGUMENT,
		error::Domain.INTERNAL,
		0,
		"query on a null COM pointer"
	)~;
	com::IUnknown* unknown = (com::IUnknown*)source.ptr;
	void* raw              = null;
	hresult::Hresult hr    = (hresult::Hresult)unknown.vtbl.query_interface(unknown, &iid, &raw);
	if (hr.failed()) return errors::raise_hresult(hr, "QueryInterface")~;
	return { .ptr = (Target*)raw };
}