<*
 IVirtualDesktopManager: the documented COM interface that says which virtual
 desktop a window is on, whether it is on the current one, and moves it to another.
 It cannot enumerate desktops or switch to one; those need the undocumented
 interfaces, which this library does not use.

 Sources, checked against each other: mingw-w64 `shobjidl.h` (lines 30582-30597
 for the IID and the vtable; 32929 for the CLSID) and windows-sys 0.59.0
 `UI/Shell/mod.rs` (line 6674 for the CLSID). IID a5cd92ff-29be-454c-8d04-d82879fb3f1b,
 CLSID aa509086-5ca9-4c25-8f95-589d3c07b48a. Vtable order after IUnknown:
 IsWindowOnCurrentVirtualDesktop, GetWindowDesktopId, MoveWindowToDesktop.
*>
module bleu::windows::win32_vdm @feat(WIN32);
import bleu::error, bleu::win::com, bleu::win::com_ptr, bleu::win::errors, bleu::win::guid, bleu::win::hresult;

const Guid CLSID_VIRTUAL_DESKTOP_MANAGER = guid::guid("aa509086-5ca9-4c25-8f95-589d3c07b48a");
const Guid IID_IVIRTUAL_DESKTOP_MANAGER  = guid::guid("a5cd92ff-29be-454c-8d04-d82879fb3f1b");

alias IsOnCurrentFn = fn hresult::Hresult(void* self, void* hwnd, int* on_current);
alias GetDesktopIdFn = fn hresult::Hresult(void* self, void* hwnd, Guid* desktop_id);
alias MoveToDesktopFn = fn hresult::Hresult(void* self, void* hwnd, Guid* desktop_id);

struct IVirtualDesktopManagerVtbl
{
	com::QueryInterfaceFn query_interface;
	com::AddRefFn add_ref;
	com::ReleaseFn release;
	IsOnCurrentFn is_window_on_current_desktop;
	GetDesktopIdFn get_window_desktop_id;
	MoveToDesktopFn move_window_to_desktop;
}

<* A COM object of IVirtualDesktopManager: its vtable pointer is the first member. *>
struct IVirtualDesktopManager
{
	IVirtualDesktopManagerVtbl* vtbl;
}

<* Create the desktop manager of this session. Its interface is released with the owning `Com`. *>
fn com_ptr::Com{IVirtualDesktopManager}? open_manager()
{
	return com_ptr::co_create_instance{IVirtualDesktopManager}(
		CLSID_VIRTUAL_DESKTOP_MANAGER,
		IID_IVIRTUAL_DESKTOP_MANAGER
	);
}

<*
 Whether a window is on the virtual desktop in front of the user.

 @return? error::BACKEND_FAILURE : "The call failed; the error is in `error::last()`"
*>
fn bool? on_current_desktop(IVirtualDesktopManager* manager, void* hwnd)
{
	int on_current      = 0;
	hresult::Hresult hr = manager.vtbl.is_window_on_current_desktop(manager, hwnd, &on_current);
	if (hr.failed()) return errors::raise_hresult(hr, "IsWindowOnCurrentVirtualDesktop")~;
	return on_current != 0;
}

<*
 The GUID of the virtual desktop a window is on.

 @return? error::BACKEND_FAILURE : "The call failed; the error is in `error::last()`"
*>
fn Guid? desktop_of(IVirtualDesktopManager* manager, void* hwnd)
{
	Guid desktop_id;
	hresult::Hresult hr = manager.vtbl.get_window_desktop_id(manager, hwnd, &desktop_id);
	if (hr.failed()) return errors::raise_hresult(hr, "GetWindowDesktopId")~;
	return desktop_id;
}

<*
 Move a window to a virtual desktop, without changing which desktop is shown.

 @return? error::BACKEND_FAILURE : "The call failed; the error is in `error::last()`"
*>
fn void? move_to_desktop(IVirtualDesktopManager* manager, void* hwnd, Guid desktop_id)
{
	hresult::Hresult hr = manager.vtbl.move_window_to_desktop(manager, hwnd, &desktop_id);
	if (hr.failed()) return errors::raise_hresult(hr, "MoveWindowToDesktop")~;
}