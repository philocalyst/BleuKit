<*
 Objective-C object references and message sending for macOS services.

 Everything here sits on top of `std::os::darwin::objc` (the message-send
 macros, selector and class lookup, `ObjId`/`ObjClass`/`ObjSel`). What this
 file adds is ownership: `Obj` is the only way a backend should hold an
 Objective-C object, so retain/release pairs are written once and checked by
 the reader.

 Source for the runtime functions: Apple objc4 `runtime/runtime.h` and
 `runtime/message.h` (https://raw.githubusercontent.com/apple-oss-distributions/objc4/main/runtime/runtime.h),
 cross-checked with the `objc2` crate `src/runtime/message_receiver.rs` (Rust bindings that
 select the same `objc_msgSend` variants). See docs/research/bleu_objc.md.
*>
module bleu::objc @feat(DARWIN) @link("Foundation.framework");
import std::os::darwin::objc;
import std::os::macos::cg;
import bleu::error;

<*
 A `NSRange`: two `NSUInteger` fields. Returned in registers on both
 arm64 and x86_64 (16 bytes), so `send` uses plain `objc_msgSend`.
*>
struct NSRange
{
	ulong location;
	ulong length;
}

<*
 An owned reference to an Objective-C object, or nil.

 `Obj` never retains or releases on its own; the constructor says what the
 caller hands over:
 * `Obj.adopt(id)`   takes an already +1 reference (`alloc`/`init`, `new`, `copy`, `create`).
 * `Obj.borrow(id)`  retains a +0 reference (getters, autoreleased results).
 `close()` releases the owned reference and leaves the wrapper nil, so it is
 safe to call twice and works with `defer`.
*>
struct Obj
{
	ObjId ptr;
}

<* Take over a +1 reference returned by `alloc`, `new`, `copy` or `create`. *>
fn Obj adopt(ObjId owned) @inline => { .ptr = owned };

<* Retain a +0 reference (a getter's result, an autoreleased object) so the wrapper owns one. *>
fn Obj borrow(ObjId borrowed) => { .ptr = objc::retain(borrowed) };

<* Release the owned reference, if any, and become nil. Idempotent. *>
fn void Obj.close(&self)
{
	if (self.ptr) objc::release(self.ptr);
	self.ptr = null;
}

<* True when the wrapper holds no object. *>
fn bool Obj.is_nil(self) @inline => !self.ptr;

<*
 Hand the owned reference to the current autorelease pool and become nil.

 @return "the object, borrowed from the pool; valid until the pool drains"
*>
fn ObjId Obj.autorelease(&self)
{
	ObjId id = self.ptr;
	self.ptr = null;
	return id ? id.send(ObjId, "autorelease") : null;
}

<*
 Whether the object is an instance of `cls` or a subclass. Nil is never of any class.
*>
fn bool Obj.is_kind_of(self, ObjClass cls) => self.send_bool("isKindOfClass:", cls);

<*
 Whether the object implements `sel` (an instance method). Nil responds to nothing.
*>
fn bool Obj.responds_to(self, ObjSel sel) => self.send_bool("respondsToSelector:", sel);

<*
 A new owned reference to a copy of the object (`-copy`). Nil copies to nil.
*>
fn Obj Obj.copy(self) => adopt(self.send_id("copy"));

<* Register (or look up) a selector by name. *>
fn ObjSel selector(ZString name) @inline => objc::sel_getUid(name);

<* Look up a class by name. Returns a null class when it is not loaded. *>
fn ObjClass class_named(ZString name) @inline => objc::lookUpClass(name);

<*
 Typed message sends on an `Obj`, with the struct-return rules handled by the
 stdlib `send` macro.

 Return-type rules (Apple objc4 `runtime/Messengers.subproj/objc-msg-x86_64.s`
 and `objc-msg-arm64.s`, and the objc2 crate):
 * x86_64: a struct of at most 16 bytes is returned in registers, so plain
 `objc_msgSend` is used; larger structs (CGRect, 32 bytes) go through
 `objc_msgSend_stret`, which the stdlib selects for `size > 16`.
 * arm64: there is no `objc_msgSend_stret`. Every struct return goes through
 plain `objc_msgSend` because it is a tail jump that preserves `x8`
 (the indirect-result register) and `v0`..`v3` (HFA returns).

 Arguments are passed as ordinary C3 values. Pass an `ObjId` for objects, an
 `ObjSel` for selectors, a C3 `bool` for a `BOOL` argument, and an `NSUInteger`
 (`ulong`) for `NSUInteger`. Selectors must be string literals.
*>
macro ObjId Obj.send_id(self, ZString $selector, ...) => self.ptr.send(ObjId, $selector, ...$vaarg);
<* Send a message returning `BOOL` (C3 `bool`). *>
macro bool Obj.send_bool(self, ZString $selector, ...) => self.ptr.send(bool, $selector, ...$vaarg);
<* Send a message returning a 64-bit signed integer (`long`, `NSInteger`). *>
macro long Obj.send_long(self, ZString $selector, ...) => self.ptr.send(long, $selector, ...$vaarg);
<* Send a message returning a 64-bit unsigned integer (`NSUInteger`). *>
macro ulong Obj.send_ulong(self, ZString $selector, ...) => self.ptr.send(ulong, $selector, ...$vaarg);
<* Send a message returning `double` (`CGFloat` on 64-bit). *>
macro double Obj.send_double(self, ZString $selector, ...) => self.ptr.send(double, $selector, ...$vaarg);
<* Send a message with no return value. *>
macro void Obj.send_void(self, ZString $selector, ...) => self.ptr.send_void($selector, ...$vaarg);
<* Send a message returning `CGRect` or `NSRect`. Stret rules: see above. *>
macro cg::CGRect Obj.send_rect(self, ZString $selector, ...) => self.ptr.send(cg::CGRect, $selector, ...$vaarg);
<* Send a message returning `NSRange`. *>
macro NSRange Obj.send_range(self, ZString $selector, ...) => self.ptr.send(NSRange, $selector, ...$vaarg);

<*
 Run `@body` inside an autorelease pool. Use it for Objective-C work that is
 not already covered by a callback entry point.

 objc::@autorelease_pool() { ... };
*>
macro void @autorelease_pool(; @body)
{
	void* pool = objc::pool_push();
	defer objc::pool_pop(pool);
	@body();
}

<*
 Temporary-allocator size for a foreign-thread entry point, in bytes.
 Callbacks are short, so 256 KiB is far more than any of them need.
*>
const usz CALLBACK_TEMP_BYTES = 256 * 1024;

<*
 Entry guard for code that arrives on a thread Bleu did not create (AppKit,
 CoreWLAN, GCD, IOKit and CoreAudio callbacks). It gives the body an
 autorelease pool and a fresh C3 temporary-allocator scope, so `tmem`,
 `tformat` and `@pool()` work and Objective-C autoreleased objects are
 drained when the callback returns.

 This is the stand-in for `bleu::rt::foreign`'s `@foreign_entry`, which will
 replace it once that library exists. It uses `@pool_init` from the standard
 library (`/opt/c3/c3/lib/std/core/mem.c3`) until then.

 objc::@objc_entry() { ... };
*>
macro void @objc_entry(; @body)
{
	void* pool = objc::pool_push();
	defer objc::pool_pop(pool);
	@pool_init(mem, CALLBACK_TEMP_BYTES)
	{
		@body();
	};
}