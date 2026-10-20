<*
 Native COM objects implemented in Bleu: callbacks that other components
 (MMDevice, WLAN, WinRT events) call back into.

 A shell is one allocation laid out as COM requires: the first member is a
 pointer to a vtable whose first three slots are `IUnknown`'s. The vtable is a
 per-interface constant, written by the caller, so this module is generic over
 that vtable type and supplies the three `IUnknown` slots itself:

     com_shell::query_interface{MyVtbl}   // slot 0: answers IUnknown, the shell's IID, and IAgileObject
     com_shell::add_ref{MyVtbl}           // slot 1: atomic reference count
     com_shell::release{MyVtbl}           // slot 2: frees the shell when the count reaches zero

 Lifetimes: `create` returns a shell holding one reference, which belongs to
 the caller. Passing the shell to a registrar makes the registrar call
 `add_ref`; it calls `release` when it unregisters. The shell's `context`
 pointer is never freed by the shell.

 Threads: native callbacks arrive on foreign threads. Each callback body must
 run inside `@foreign_entry` (`bleu::rt::foreign`), because the temporary
 allocator is not available on those threads. The three `IUnknown` slots here
 allocate nothing temporary and are safe on any thread.

 Vtable slot numbers and IIDs: docs/research/bleu_win.md, section 3.
*>
module bleu::win::com_shell @feat(WIN32);
import std::atomic, bleu::win::guid;

<*
 The header shared by every shell. `vtbl` must be the first member, and `Vtbl`
 is the interface's vtable struct, whose first three members are the
 `IUnknownVtbl` slots.
*>
struct Shell <Vtbl>
{
	Vtbl* vtbl;
	Atomic{uint} refs;
	Guid iid;
	bool agile;
	Allocator allocator;
	void* context;
}

module bleu::win::com_shell <Vtbl>;
import std::atomic;
import bleu::win::com, bleu::win::guid, bleu::win::hresult;

<*
 Allocate a shell for interface `iid`, holding one reference.

 @param allocator : "Where the shell lives until its last `release`"
 @param table : "The interface's vtable, which must outlive every shell that uses it"
 @param iid : "The IID the shell answers `QueryInterface` for, besides IUnknown"
 @param agile : "True to also answer IAgileObject, i.e. the callbacks may run on any thread"
 @param context : "Caller data, passed back through `Shell.context`; never freed by the shell"
*>
fn Shell{Vtbl}* create(Allocator allocator, Vtbl* table, Guid iid, bool agile, void* context)
{
	Shell{Vtbl}* shell = alloc::new(allocator, Shell{Vtbl});
	shell.vtbl = table;
	shell.refs.store(1);
	shell.iid = iid;
	shell.agile = agile;
	shell.allocator = allocator;
	shell.context = context;
	return shell;
}

<*
 `IUnknown::QueryInterface` for a shell. Answers IUnknown, the shell's IID and,
 when the shell is agile, IAgileObject. Anything else is `E_NOINTERFACE`.

 @param self : "The shell, as the `this` pointer COM passes"
 @param iid : "The requested IID"
 @param out : "Receives the interface pointer, with one reference added"
*>
fn hresult::Hresult query_interface(void* self, Guid* iid, void** out)
{
	if (!out) return (hresult::Hresult)hresult::E_POINTER;
	*out = null;
	if (!iid) return (hresult::Hresult)hresult::E_POINTER;
	Shell{Vtbl}* shell = (Shell{Vtbl}*)self;
	bool answers = iid.equals(com::IID_IUNKNOWN) || iid.equals(shell.iid)
		|| (shell.agile && iid.equals(com::IID_IAGILEOBJECT));
	if (!answers) return (hresult::Hresult)hresult::E_NOINTERFACE;
	shell.refs.add(1);
	*out = self;
	return (hresult::Hresult)hresult::S_OK;
}

<* `IUnknown::AddRef` for a shell. Returns the new count. *>
fn uint add_ref(void* self)
{
	Shell{Vtbl}* shell = (Shell{Vtbl}*)self;
	return shell.refs.add(1) + 1;
}

<*
 `IUnknown::Release` for a shell. Frees the shell when the count reaches zero,
 after which `self` must not be used. Returns the new count.
*>
fn uint release(void* self)
{
	Shell{Vtbl}* shell = (Shell{Vtbl}*)self;
	uint previous = shell.refs.sub(1);
	if (previous == 1)
	{
		Allocator allocator = shell.allocator;
		alloc::free(allocator, shell);
		return 0;
	}
	return previous - 1;
}

<* The shell behind a `this` pointer that COM passed to one of the vtable's functions. *>
fn Shell{Vtbl}* from_this(void* self) @inline => (Shell{Vtbl}*)self;
