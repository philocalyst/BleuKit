<*
 Foundation conversions and the NSError to Bleu excuse mapping.

 Conversions copy across the boundary in both directions, so no `String`
 handed out here points into an Objective-C object. Ownership of every
 returned `Obj` is explicit: a function that returns `Obj` returns an owned
 reference, and one that returns `ObjId` returns a borrowed one.

 Pools: the `NSNumber`, `NSData` and notification-center factories return
 autoreleased objects. Call them inside `objc::@autorelease_pool()` or
 `objc::@objc_entry()`, or the objects stay alive until the thread's outer pool
 drains. The NSError constants and the classification are in `codes.c3`.

 Constants:
 * `NSUTF8StringEncoding = 4`: objc2-foundation `src/generated/NSString.rs`
 (generated from the Foundation headers), and Apple `NSString.h`.
 * CocoaError code values: objc2-foundation `src/generated/FoundationErrors.rs`.
 * Errno values: Apple xnu `bsd/sys/errno.h`.
*>
module bleu::objc::foundation @feat(DARWIN) @link("Foundation.framework");
import std::os::darwin::objc, std::os::macos::cg, bleu::objc, bleu::objc::codes, bleu::error;

<* `NSUInteger` and `NSInteger`. Bleu's Apple targets are all 64-bit, so both are 64 bits wide. *>
alias NSUInteger = ulong;
<* `NSInteger`: 64 bits on every Apple target Bleu builds for. *>
alias NSInteger = long;

<* `NSStringEncoding` value for UTF-8 (`NSUTF8StringEncoding`). *>
const NSUInteger NSUTF8_STRING_ENCODING = 4;

<*
 A new `NSString` with a copy of `value`, as an owned reference.
 Embedded NUL bytes are kept (`initWithBytes:length:encoding:` takes a length).
*>
fn Obj from_string(String value)
{
	ObjClass cls = objc::class_named("NSString");
	ObjId raw = cls.alloc()
		.send(ObjId, "initWithBytes:length:encoding:", (void*)value.ptr, (NSUInteger)value.len, NSUTF8_STRING_ENCODING);
	return objc::adopt(raw);
}

<*
 Copy an `NSString` into `allocator` as UTF-8. The result does not point into
 the object, so it survives the object's release.

 @return? error::INVALID_ARGUMENT : "when the object is nil or not an NSString"
 @return? error::BACKEND_FAILURE : "when the string cannot be represented as UTF-8"
*>
fn String? to_string(ObjId value, Allocator allocator)
{
	if (!value) return error::INVALID_ARGUMENT~;
	if (!value.send(bool, "isKindOfClass:", objc::class_named("NSString")))
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "object is not an NSString")~;
	}
	ZString utf8 = value.send(ZString, "UTF8String");
	if (!utf8) return error::raise(
		error::BACKEND_FAILURE,
		error::Domain.INTERNAL,
		0,
		"NSString is not representable as UTF-8"
	)~;
	return utf8.str_view().copy(allocator);
}

<*
 A new `NSNumber` holding `value`, as a borrowed (autoreleased) object retained into an `Obj`.
 Call inside a pool (see the module comment).
*>
fn Obj from_long(long value) => objc::borrow(objc::class_named("NSNumber")
	.send(ObjId, "numberWithLongLong:", (long)value));

<* A new `NSNumber` holding `value`, autoreleased; call inside a pool. *>
fn Obj from_double(double value) => objc::borrow(objc::class_named("NSNumber").send(ObjId, "numberWithDouble:", value));

<* A new `NSNumber` holding `value` as a `BOOL`, autoreleased; call inside a pool. *>
fn Obj from_bool(bool value) => objc::borrow(objc::class_named("NSNumber").send(ObjId, "numberWithBool:", value));

<* The `longLongValue` of an `NSNumber` (nil reads as 0). *>
fn long number_as_long(objc::Obj number) => number.send_long("longLongValue");

<* The `doubleValue` of an `NSNumber` (nil reads as 0). *>
fn double number_as_double(objc::Obj number) => number.send_double("doubleValue");

<* The `boolValue` of an `NSNumber` (`BOOL`; nil reads as false). *>
fn bool number_as_bool(objc::Obj number) => number.send_bool("boolValue");

<* The `count` of an `NSArray`, `NSSet`, `NSDictionary` or other collection (nil has none). *>
fn usz count_of(objc::Obj collection) => (usz)collection.send_ulong("count");

<*
 The `frame` of an `NSView`, `NSWindow` or `NSScreen`, in points. `NSRect` has
 the layout of `CGRect` (origin then size, four CGFloats), so the stdlib struct is used.
*>
fn cg::CGRect frame_of(objc::Obj object) => object.send_rect("frame");

<*
 The range of `needle` inside `haystack` (`-[NSString rangeOfString:]`). When not
 found, `location` is `NSNotFound`, which is `NSIntegerMax`.
*>
fn objc::NSRange find_range(objc::Obj haystack, objc::Obj needle) => haystack.send_range("rangeOfString:", needle.ptr);

<* A new `NSData` with a copy of `bytes`, autoreleased and retained into an `Obj`; call inside a pool. *>
fn Obj from_bytes(char[] bytes)
{
	ObjClass cls = objc::class_named("NSData");
	return objc::borrow(cls.send(ObjId, "dataWithBytes:length:", (void*)bytes.ptr, (NSUInteger)bytes.len));
}

<*
 Copy an `NSData`'s bytes into `allocator`.

 @return? error::INVALID_ARGUMENT : "when the object is nil or not an NSData"
*>
fn char[]? data_bytes(ObjId data, Allocator allocator)
{
	if (!data) return error::INVALID_ARGUMENT~;
	if (!data.send(bool, "isKindOfClass:", objc::class_named("NSData")))
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "object is not NSData")~;
	}
	usz length = (usz)data.send(NSUInteger, "length");
	if (!length) return { };
	char* bytes = (char*)data.send(void*, "bytes");
	char[] copy = alloc::new_array(allocator, char, (sz)length);
	mem::copy(copy.ptr, bytes, (sz)length);
	return copy;
}

<* Number of elements of an `NSArray` or `NSSet`. Nil has none. *>
fn usz array_count(ObjId array) => array ? (usz)array.send(NSUInteger, "count") : 0;

<* The element at `index` of an `NSArray`, borrowed from the array. Out-of-range or nil returns nil. *>
fn ObjId array_at(ObjId array, usz index)
{
	if (!array || index >= array_count(array)) return null;
	return array.send(ObjId, "objectAtIndex:", (NSUInteger)index);
}

<* The keys of an `NSDictionary` as an `NSArray` (autoreleased). Nil dictionary has no keys. *>
fn ObjId dictionary_keys(ObjId dictionary) => dictionary ? dictionary.send(ObjId, "allKeys") : null;

<* The value for `key` in an `NSDictionary`, borrowed from it. Nil when absent. *>
fn ObjId dictionary_value(
	ObjId dictionary,
	ObjId key
) => dictionary ? dictionary.send(ObjId, "objectForKey:", key) : null;

<* The members of an `NSSet` as an `NSArray` (autoreleased). *>
fn ObjId set_members(ObjId set) => set ? set.send(ObjId, "allObjects") : null;

<*
 Raise an NSError as a Bleu fault. The detail records the domain and code
 (`Domain.NS_ERROR`) and the message holds the caller's `context`, the object's
 `localizedDescription`, and the domain and code. The classification is
 `codes::classify_ns`.

 return foundation::raise_ns_error(err, "could not join network")~;

 @param ns_error : "The NSError object (nil is reported as an unknown failure)"
 @param context : "What the caller was doing; a short noun phrase"
 @return "The classified fault, ready to be returned with `~`"
*>
fn fault raise_ns_error(ObjId ns_error, String context)
{
	if (!ns_error) return error::raise(
		error::BACKEND_FAILURE,
		error::Domain.NS_ERROR,
		0,
		"%s: no error object",
		context
	);
	@pool()
	{
		String domain      = to_string(ns_error.send(ObjId, "domain"), tmem) ?? "?";
		NSInteger code     = ns_error.send(NSInteger, "code");
		String description = to_string(ns_error.send(ObjId, "localizedDescription"), tmem) ?? "";
		fault f            = codes::classify_ns(domain, code);
		return error::raise(
			f,
			error::Domain.NS_ERROR,
			(int)code,
			"%s: %s [%s %d]",
			context,
			description,
			domain,
			(int)code
		);
	};
}