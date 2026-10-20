<*
 Implementing Objective-C classes from C3: delegates, observers and
 notification targets.

 The flow is the one AppKit and CoreWLAN expect:
 1. `begin_class` allocates a subclass pair (`objc_allocateClassPair`).
 2. `add_context_ivar` adds the instance variable that holds a C3 pointer back to
 the Bleu object that owns the instance (the same pattern as gfx_macos.c3's
 `gfx_window` ivar).
 3. `method` registers each C3 function as a selector implementation
 (`class_addMethod`), with a type encoding from `signature`.
 4. `adopt_protocol` adds formal protocols (`class_addProtocol`).
 5. `finish` registers the class (`objc_registerClassPair`). It cannot change afterwards.

 Sources: Apple objc4 `runtime/runtime.h` (objc_allocateClassPair,
 class_addMethod, class_addIvar, class_addProtocol, objc_getProtocol,
 objc_registerClassPair) and `runtime/objc.h` (the `OBJC_BOOL_IS_BOOL` rule, which
 defers to `__OBJC_BOOL_IS_BOOL` when clang defines it); the arm64/x86_64 split of
 BOOL is from the objc2 crate's `src/runtime/bool.rs`, which says clang always defines
 `__OBJC_BOOL_IS_BOOL`; cross-checked with the stdlib's
 `std/gfx/private/gfx_macos.c3` (lines ~1097-1151), a working C3 delegate class.
*>
module bleu::objc @feat(DARWIN) @link("Foundation.framework");
import std::os::darwin::objc;
import bleu::error, bleu::objc::encoding;

<* An Objective-C protocol object (`Protocol *`), from `objc_getProtocol`. *>
typedef ObjProtocol = void*;

extern fn ObjProtocol objc_getProtocol(ZString name);
extern fn bool class_addProtocol(ObjClass cls, ObjProtocol protocol);

<* Name of the instance variable that stores the C3 context pointer. *>
const ZString CONTEXT_IVAR = "bleu_context";

<* Type encoding of the context ivar: a C pointer, `^v`. *>
const ZString CONTEXT_IVAR_ENCODING = "^v";

<*
 A class under construction. Not yet usable as an object class: it becomes one
 only after `finish`. Keep it on the stack or in the owning service; it holds no
 resources that need freeing if `finish` is never called (the runtime leaks the
 class pair, which is acceptable for classes that live for the process).
*>
struct ClassBuilder
{
	ObjClass cls;
}

<*
 Start a new subclass of `superclass` called `name`.

 @require name != "" : "A class needs a name"
 @return? error::INVALID_STATE : "when a class of that name already exists"
*>
fn ClassBuilder? begin_class(ObjClass superclass, ZString name)
{
	ObjClass cls = superclass.new_subclass(name);
	if (!cls)
	{
		return error::raise(
			error::INVALID_STATE,
			error::Domain.INTERNAL,
			0,
			"cannot create class '%s': the name is taken",
			name
		)~;
	}
	return { .cls = cls };
}

<*
 Add the instance variable that holds the owning C3 object's pointer.

 @return? error::BACKEND_FAILURE : "when the runtime refuses the ivar"
*>
fn void? ClassBuilder.add_context_ivar(&self)
{
	if (!self.cls.add_ivar(CONTEXT_IVAR, void*, CONTEXT_IVAR_ENCODING))
	{
		return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, 0, "cannot add ivar '%s'", CONTEXT_IVAR)~;
	}
}

<*
 Register `imp` as the implementation of `selector`. `encoding` is normally
 built with `encoding::signature`. An implementation that can be called from a foreign
 thread (any AppKit, CoreWLAN or GCD callback) should begin its body with
 `objc::@objc_entry()`. An explicit string is accepted for the rare case where
 a type cannot be sampled. The runtime returns `false` if the class already
 has that method; this is reported as `BACKEND_FAILURE`.

 @return? error::BACKEND_FAILURE
*>
fn void? ClassBuilder.method(&self, ZString selector, void* imp, ZString encoding)
{
	if (!self.cls.add_method(selector, imp, encoding))
	{
		return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, 0, "cannot add method '%s'", selector)~;
	}
}

<*
 Register `imp` for a selector of the common delegate shape
 `void (id self, SEL _cmd, id argument)`, such as `windowWillClose:` or a
 notification handler. The encoding is generated from the C3 types of a sample call.

 @return? error::BACKEND_FAILURE : "when the runtime refuses the method"
*>
fn void? ClassBuilder.method_void_object(&self, ZString selector, void* imp)
{
	self.method(selector, imp, encoding::signature(void, (ObjId)null))!;
}

<*
 Declare conformance to a formal protocol such as `NSUserNotificationCenterDelegate`.

 @return? NOT_FOUND : "when the protocol is not known to the runtime"
*>
fn void? ClassBuilder.adopt_protocol(&self, ZString name)
{
	ObjProtocol protocol = objc_getProtocol(name);
	if (!protocol) return NOT_FOUND~;
	class_addProtocol(self.cls, protocol);
}

<*
 Register the class with the runtime and return it. The builder must not be
 used afterwards.
*>
fn ObjClass ClassBuilder.finish(&self)
{
	objc::register_new_subclass(self.cls);
	return self.cls;
}

<* Store a C3 pointer in an instance created from a class with a context ivar. *>
fn void set_context(ObjId instance, void* context) @inline => instance.set_ivar(CONTEXT_IVAR, context);

<*
 Read the C3 pointer stored by `set_context`. Returns null for a nil instance.
*>
fn void* context_of(ObjId instance)
{
	void* context = null;
	if (instance) instance.get_ivar(CONTEXT_IVAR, &context);
	return context;
}