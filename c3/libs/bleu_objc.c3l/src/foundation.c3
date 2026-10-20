<*
 Foundation conversions and the NSError to Bleu excuse mapping.

 Conversions copy across the boundary in both directions, so no `String`
 handed out here points into an Objective-C object. Ownership of every
 returned `Obj` is explicit: a function that returns `Obj` returns an owned
 reference, and one that returns `ObjId` returns a borrowed one.

 Constants:
 * `NSUTF8StringEncoding = 4`: objc2-foundation `src/generated/NSString.rs`
 (generated from the Foundation headers), and Apple `NSString.h`.
 * `NSCocoaErrorDomain`, `NSPOSIXErrorDomain`, `NSOSStatusErrorDomain` are the
 exported string constants: swift-corelibs-foundation `Sources/Foundation/NSError.swift`
 and objc2-foundation `src/generated/NSError.rs`.
 * CocoaError code values: objc2-foundation `src/generated/FoundationErrors.rs`
 (NSFileNoSuchFileError = 4, ...). Errno values: Apple xnu `bsd/sys/errno.h`.
*>
module bleu::objc::foundation @feat(DARWIN) @link("Foundation.framework");
import std::os::darwin::objc, std::os::macos::cg, bleu::objc, bleu::error;

<* `NSUInteger` and `NSInteger`. Bleu's Apple targets are all 64-bit, so both are 64 bits wide. *>
alias NSUInteger = ulong;
alias NSInteger = long;

<* `NSStringEncoding` value for UTF-8 (`NSUTF8StringEncoding`). *>
const NSUInteger NSUTF8_STRING_ENCODING = 4;

<* `NSCocoaErrorDomain` (exported `NSString` constant). *>
const ZString COCOA_ERROR_DOMAIN     = "NSCocoaErrorDomain";
<* `NSPOSIXErrorDomain`: the code is an errno. *>
const ZString POSIX_ERROR_DOMAIN     = "NSPOSIXErrorDomain";
<* `NSOSStatusErrorDomain`: the code is an OSStatus. *>
const ZString OS_STATUS_ERROR_DOMAIN = "NSOSStatusErrorDomain";

<* CocoaError codes that map to a Bleu excuse (objc2-foundation FoundationErrors.rs). *>
const NSInteger COCOA_FILE_NO_SUCH_FILE        = 4;
const NSInteger COCOA_FILE_LOCKING             = 255;
const NSInteger COCOA_FILE_READ_NO_PERMISSION  = 257;
const NSInteger COCOA_FILE_READ_NO_SUCH_FILE   = 260;
const NSInteger COCOA_FILE_WRITE_NO_PERMISSION = 513;
const NSInteger COCOA_USER_CANCELLED           = 3072;
const NSInteger COCOA_FEATURE_UNSUPPORTED      = 3328;

<* errno values on Darwin (xnu bsd/sys/errno.h). *>
const NSInteger POSIX_EPERM     = 1;
const NSInteger POSIX_ENOENT    = 2;
const NSInteger POSIX_ENOMEM    = 12;
const NSInteger POSIX_EACCES    = 13;
const NSInteger POSIX_EBUSY     = 16;
const NSInteger POSIX_EINVAL    = 22;
const NSInteger POSIX_ENOTSUP   = 45;
const NSInteger POSIX_ETIMEDOUT = 60;
const NSInteger POSIX_ECANCELED = 89;

<*
 `errAEEventNotPermitted`: AppleEvents refused, which is how a missing
 Automation (TCC) grant appears to AppleScript. objc2-core-services
 `src/generated/AE/AppleEvents.rs` (value -1743).
*>
const NSInteger OS_STATUS_AE_EVENT_NOT_PERMITTED = -1743;

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

 @return? error::INVALID_ARGUMENT : "when the object is nil or not a string"
*>
fn String? to_string(ObjId value, Allocator allocator)
{
	if (!value) return error::INVALID_ARGUMENT~;
	ZString utf8 = value.send(ZString, "UTF8String");
	if (!utf8) return error::INVALID_ARGUMENT~;
	return utf8.str_view().copy(allocator);
}

<* A new `NSNumber` holding `value`, as a borrowed (autoreleased) object retained into an `Obj`. *>
fn Obj from_long(long value) => objc::borrow(objc::class_named("NSNumber")
	.send(ObjId, "numberWithLongLong:", (long)value));

<* A new `NSNumber` holding `value`. *>
fn Obj from_double(double value) => objc::borrow(objc::class_named("NSNumber").send(ObjId, "numberWithDouble:", value));

<* A new `NSNumber` holding `value` as a `BOOL`. *>
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

<* A new `NSData` with a copy of `bytes`. *>
fn Obj from_bytes(char[] bytes)
{
	ObjClass cls = objc::class_named("NSData");
	return objc::borrow(cls.send(ObjId, "dataWithBytes:length:", (void*)bytes.ptr, (NSUInteger)bytes.len));
}

<*
 Copy an `NSData`'s bytes into `allocator`.

 @return? error::INVALID_ARGUMENT : "when the object is nil or not data"
*>
fn char[]? data_bytes(ObjId data, Allocator allocator)
{
	if (!data) return error::INVALID_ARGUMENT~;
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
 Classify an NSError by its domain and code. The mapping is deliberately small:
 only codes whose meaning is unambiguous get a specific excuse, and everything
 else is `BACKEND_FAILURE` with the text preserved in the detail.

 Permission (TCC, file ACL, AppleEvents) maps to `PERMISSION_DENIED`; a missing
 file, device or service to `NOT_FOUND`; a POSIX timeout to `TIMEOUT`; a
 cancelled dialog to `CANCELLED`; a feature the OS does not have to `UNSUPPORTED`.
*>
fn fault classify_ns_error(String domain, NSInteger code)
{
	if (domain == COCOA_ERROR_DOMAIN)
	{
		switch (code)
		{
			case COCOA_FILE_NO_SUCH_FILE:
			case COCOA_FILE_READ_NO_SUCH_FILE:
				return NOT_FOUND;
			case COCOA_FILE_READ_NO_PERMISSION:
			case COCOA_FILE_WRITE_NO_PERMISSION:
				return error::PERMISSION_DENIED;
			case COCOA_FILE_LOCKING:
				return error::BUSY;
			case COCOA_USER_CANCELLED:
				return error::CANCELLED;
			case COCOA_FEATURE_UNSUPPORTED:
				return error::UNSUPPORTED;
			default:
				return error::BACKEND_FAILURE;
		}
	}
	if (domain == POSIX_ERROR_DOMAIN)
	{
		switch (code)
		{
			case POSIX_EPERM:
			case POSIX_EACCES:
				return error::PERMISSION_DENIED;
			case POSIX_ENOENT:
				return NOT_FOUND;
			case POSIX_EBUSY:
				return error::BUSY;
			case POSIX_EINVAL:
				return error::INVALID_ARGUMENT;
			case POSIX_ENOMEM:
				return error::NO_MEMORY;
			case POSIX_ENOTSUP:
				return error::UNSUPPORTED;
			case POSIX_ETIMEDOUT:
				return TIMEOUT;
			case POSIX_ECANCELED:
				return error::CANCELLED;
			default:
				return error::BACKEND_FAILURE;
		}
	}
	if (domain == OS_STATUS_ERROR_DOMAIN && code == OS_STATUS_AE_EVENT_NOT_PERMITTED) return error::PERMISSION_DENIED;
	return error::BACKEND_FAILURE;
}

<*
 Raise an NSError as a Bleu fault. The detail records the domain and code
 (`Domain.NS_ERROR`) and the message holds the caller's `context`, the object's
 `localizedDescription`, and the domain and code.

 return foundation::raise_ns_error(err, "could not join network")~;

 @param error : "The NSError object (nil is reported as an unknown failure)"
 @param context : "What the caller was doing; a short noun phrase"
 @return "The classified fault, ready to be returned with `~`"
*>
fn fault raise_ns_error(ObjId error, String context)
{
	if (!error) return error::raise(error::BACKEND_FAILURE, error::Domain.NS_ERROR, 0, "%s: no error object", context);
	@pool()
	{
		String domain      = to_string(error.send(ObjId, "domain"), tmem) ?? "?";
		NSInteger code     = error.send(NSInteger, "code");
		String description = to_string(error.send(ObjId, "localizedDescription"), tmem) ?? "";
		fault f            = classify_ns_error(domain, code);
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