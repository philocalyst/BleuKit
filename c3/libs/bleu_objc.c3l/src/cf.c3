<*
 CoreFoundation for Bleu: an owned reference type, the conversions every IOKit
 and CoreWLAN backend needs, and a property-list converter.

 Ownership mirrors `bleu::objc::Obj`: `Ref.adopt` takes a +1 result of a `Create`
 or `Copy` function, `Ref.borrow` retains a +0 result of a `Get` function.
 CoreFoundation types are `alias`es of `void*` (not `typedef`s) so they mix freely
 with Objective-C `ObjId`s and raw C pointers at the boundary.

 Sources:
 * Type sizes: CoreFoundation `CFBase.h`, where `CFIndex` is `signed long`,
 `CFTypeID` and `CFOptionFlags` are `unsigned long` on LP64, and `Boolean` is `unsigned char`
 (apple-oss-distributions/CF, repo root `CFBase.h`).
 * Constants and prototypes: `CFNumber.h`, `CFString.h`, `CFData.h`, `CFArray.h`,
 `CFDictionary.h`, `CFBase.h` in the same repository; the Rust `core-foundation-sys`
 0.8.7 crate's `src/*.rs` (same names and values) is the second source.
*>
module bleu::cf @feat(DARWIN) @link("CoreFoundation.framework");
import std::os::darwin::objc, bleu::error;

<* A CoreFoundation object reference (`CFTypeRef`). Pointer-sized; `alias` so it mixes with `ObjId`. *>
alias CFTypeRef = void*;
<* `CFIndex`: signed long on LP64. *>
alias CFIndex = long;
<* `CFTypeID`: unsigned long on LP64. *>
alias CFTypeID = ulong;
<* `CFStringEncoding`: UInt32. *>
alias CFStringEncoding = uint;

<* `kCFStringEncodingUTF8` (CFString.h). *>
const CFStringEncoding CF_STRING_ENCODING_UTF8 = 0x08000100;
<* `kCFNumberSInt64Type` (CFNumber.h): 64-bit signed integers. *>
const CFIndex CF_NUMBER_SINT64                 = 4;
<* `kCFNumberDoubleType` (CFNumber.h): 64-bit IEEE 754 floats. *>
const CFIndex CF_NUMBER_DOUBLE                 = 13;

<* Room for the terminating NUL when copying a CFString to C. *>
const CFIndex NUL_BYTES = 1;

<* Deepest property-list nesting the converter accepts before refusing (guards cycles). *>
const int PLAIN_MAX_DEPTH = 32;

extern fn CFTypeRef cf_retain(CFTypeRef value) @cname("CFRetain");
extern fn void cf_release(CFTypeRef value) @cname("CFRelease");
extern fn CFTypeID cf_get_type_id(CFTypeRef value) @cname("CFGetTypeID");
extern fn CFTypeID cf_string_type_id() @cname("CFStringGetTypeID");
extern fn CFTypeID cf_number_type_id() @cname("CFNumberGetTypeID");
extern fn CFTypeID cf_boolean_type_id() @cname("CFBooleanGetTypeID");
extern fn CFTypeID cf_data_type_id() @cname("CFDataGetTypeID");
extern fn CFTypeID cf_array_type_id() @cname("CFArrayGetTypeID");
extern fn CFTypeID cf_dictionary_type_id() @cname("CFDictionaryGetTypeID");

extern fn CFTypeRef cf_string_create_with_bytes(
	CFTypeRef allocator,
	char* bytes,
	CFIndex length,
	CFStringEncoding encoding,
	bool external
) @cname("CFStringCreateWithBytes");
extern fn CFIndex cf_string_length(CFTypeRef string) @cname("CFStringGetLength");
extern fn CFIndex cf_string_max_size(
	CFIndex length,
	CFStringEncoding encoding
) @cname("CFStringGetMaximumSizeForEncoding");
extern fn bool cf_string_get_cstring(
	CFTypeRef string,
	char* buffer,
	CFIndex size,
	CFStringEncoding encoding
) @cname("CFStringGetCString");

extern fn CFTypeRef cf_number_create(CFTypeRef allocator, CFIndex type, void* value) @cname("CFNumberCreate");
extern fn bool cf_number_get_value(CFTypeRef number, CFIndex type, void* value) @cname("CFNumberGetValue");
extern fn bool cf_number_is_float(CFTypeRef number) @cname("CFNumberIsFloatType");

extern const CFTypeRef KCF_BOOLEAN_TRUE @cname("kCFBooleanTrue");
extern const CFTypeRef KCF_BOOLEAN_FALSE @cname("kCFBooleanFalse");
extern fn bool cf_boolean_get_value(CFTypeRef boolean) @cname("CFBooleanGetValue");

extern fn CFTypeRef cf_data_create(CFTypeRef allocator, char* bytes, CFIndex length) @cname("CFDataCreate");
extern fn CFIndex cf_data_length(CFTypeRef data) @cname("CFDataGetLength");
extern fn char* cf_data_bytes(CFTypeRef data) @cname("CFDataGetBytePtr");

extern fn CFIndex cf_array_count(CFTypeRef array) @cname("CFArrayGetCount");
extern fn CFTypeRef cf_array_value_at(CFTypeRef array, CFIndex index) @cname("CFArrayGetValueAtIndex");

extern fn CFIndex cf_dictionary_count(CFTypeRef dictionary) @cname("CFDictionaryGetCount");
extern fn void cf_dictionary_keys_and_values(
	CFTypeRef dictionary,
	CFTypeRef* keys,
	CFTypeRef* values
) @cname("CFDictionaryGetKeysAndValues");

<*
 An owned CoreFoundation reference, or null. `close()` releases it.
*>
struct Ref
{
	CFTypeRef ptr;
}

<* Take over a +1 reference from a `Create` or `Copy` function. *>
fn Ref adopt(CFTypeRef owned) @inline => { .ptr = owned };

<* Retain a +0 reference from a `Get` function so the wrapper owns one. Null stays null. *>
fn Ref borrow(CFTypeRef borrowed) => { .ptr = borrowed ? cf_retain(borrowed) : null };

<* Release the owned reference, if any, and become null. Idempotent. *>
fn void Ref.close(&self)
{
	if (self.ptr) cf_release(self.ptr);
	self.ptr = null;
}

<* True when the wrapper holds no reference. *>
fn bool Ref.is_nil(self) @inline => !self.ptr;

<* True when the reference is a CoreFoundation object of type `type_id` (for example `cf::string_type_id()`). *>
fn bool Ref.is_of(self, CFTypeID type_id) => self.ptr && cf_get_type_id(self.ptr) == type_id;

<* The type id of the object (0 for null). *>
fn CFTypeID type_of(CFTypeRef value) => value ? cf_get_type_id(value) : 0;

<* CFString type id, for `Ref.is_of`. *>
fn CFTypeID string_type_id() @inline => cf_string_type_id();
<* CFNumber type id, for `Ref.is_of`. *>
fn CFTypeID number_type_id() @inline => cf_number_type_id();
<* CFBoolean type id, for `Ref.is_of`. *>
fn CFTypeID boolean_type_id() @inline => cf_boolean_type_id();
<* CFData type id, for `Ref.is_of`. *>
fn CFTypeID data_type_id() @inline => cf_data_type_id();
<* CFArray type id, for `Ref.is_of`. *>
fn CFTypeID array_type_id() @inline => cf_array_type_id();
<* CFDictionary type id, for `Ref.is_of`. *>
fn CFTypeID dictionary_type_id() @inline => cf_dictionary_type_id();

<*
 A new CFString holding a copy of `value` (UTF-8). Owned.
*>
fn Ref from_string(
	String value
) => adopt(cf_string_create_with_bytes(null, value.ptr, (CFIndex)value.len, CF_STRING_ENCODING_UTF8, false));

<*
 Copy a CFString into `allocator` as UTF-8.

 @return? error::INVALID_ARGUMENT : "when the reference is not a string or cannot be represented as UTF-8"
*>
fn String? string_value(CFTypeRef string, Allocator allocator)
{
	if (!string || cf_get_type_id(
		string
	) != cf_string_type_id()) return error::raise(
		error::INVALID_ARGUMENT,
		error::Domain.INTERNAL,
		0,
		"not a CFString"
	)~;
	CFIndex capacity = cf_string_max_size(cf_string_length(string), CF_STRING_ENCODING_UTF8) + NUL_BYTES;
	// The scratch buffer comes from the heap, and no pool is opened: the copy goes to
	// `allocator`, which may be `tmem`, so it must not be released before the caller's pool.
	char[] scratch   = alloc::new_array(mem, char, (sz)capacity);
	defer alloc::free(mem, scratch.ptr);
	if (!cf_string_get_cstring(string, scratch.ptr, capacity, CF_STRING_ENCODING_UTF8))
	{
		return error::raise(
			error::INVALID_ARGUMENT,
			error::Domain.INTERNAL,
			0,
			"CFString is not representable as UTF-8"
		)~;
	}
	return ((ZString)scratch.ptr).str_view().copy(allocator);
}

<* A new CFNumber holding a 64-bit signed integer. Owned. *>
fn Ref from_long(long value) => adopt(cf_number_create(null, CF_NUMBER_SINT64, &value));

<* A new CFNumber holding a double. Owned. *>
fn Ref from_double(double value) => adopt(cf_number_create(null, CF_NUMBER_DOUBLE, &value));

<*
 The value of a CFNumber as a 64-bit integer. A number with a fraction, or one that
 does not fit in 64 bits, is refused: `CFNumberGetValue` returns false for a lossy
 or out-of-range conversion (CFNumber.h:118-119).

 @return? error::INVALID_ARGUMENT : "when the reference is not a number"
 @return? error::OUT_OF_RANGE : "when the value is not an exact 64-bit integer"
*>
fn long? number_long(CFTypeRef number)
{
	if (!number || cf_get_type_id(
		number
	) != cf_number_type_id()) return error::raise(
		error::INVALID_ARGUMENT,
		error::Domain.INTERNAL,
		0,
		"not a CFNumber"
	)~;
	long value = 0;
	if (!cf_number_get_value(
		number,
		CF_NUMBER_SINT64,
		&value
	)) return error::raise(error::OUT_OF_RANGE, error::Domain.INTERNAL, 0, "CFNumber is not an exact 64-bit integer")~;
	return value;
}

<*
 The value of a CFNumber as a double. Integers are converted; a conversion that
 `CFNumberGetValue` reports as lossy still yields the closest double (CFNumber.h:118-120).
*>
fn double number_double(CFTypeRef number)
{
	double value = 0;
	cf_number_get_value(number, CF_NUMBER_DOUBLE, &value);
	return value;
}

<* A CFBoolean. The result is a shared singleton, retained into an owned wrapper. *>
fn Ref from_bool(bool value) => borrow(value ? KCF_BOOLEAN_TRUE : KCF_BOOLEAN_FALSE);

<* A new CFData holding a copy of `bytes`. Owned. *>
fn Ref from_bytes(char[] bytes) => adopt(cf_data_create(null, bytes.ptr, (CFIndex)bytes.len));

<*
 The bytes of a CFData, copied into `allocator`.

 @return? error::INVALID_ARGUMENT : "when the reference is not data"
*>
fn char[]? data_bytes(CFTypeRef data, Allocator allocator)
{
	if (!data || cf_get_type_id(
		data
	) != cf_data_type_id()) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "not CFData")~;
	sz length   = (sz)cf_data_length(data);
	char[] copy = alloc::new_array(allocator, char, length);
	if (length) mem::copy(copy.ptr, cf_data_bytes(data), length);
	return copy;
}

<*
 Number of elements of a CFArray. Null has none.

 @require !array || type_of(array) == array_type_id() : "array must be a CFArray or null"
*>
fn sz array_count(CFTypeRef array) => array ? (sz)cf_array_count(array) : 0;

<*
 The element at `index` of a CFArray, borrowed. Null when out of range or null.

 @require !array || type_of(array) == array_type_id() : "array must be a CFArray or null"
*>
fn CFTypeRef array_at(
	CFTypeRef array,
	sz index
) => index >= 0 && index < array_count(array) ? cf_array_value_at(array, (CFIndex)index) : null;

<*
 Number of entries of a CFDictionary. Null has none.

 @require !dictionary || type_of(dictionary) == dictionary_type_id() : "dictionary must be a CFDictionary or null"
*>
fn sz dictionary_count(CFTypeRef dictionary) => dictionary ? (sz)cf_dictionary_count(dictionary) : 0;

<*
 Every key and value of a CFDictionary, borrowed, in one pass. `keys` and
 `values` must each have room for `dictionary_count` entries.

 @require keys.len >= dictionary_count(dictionary) : "keys needs room for every entry"
 @require values.len >= dictionary_count(dictionary) : "values needs room for every entry"
 @require !dictionary || type_of(dictionary) == dictionary_type_id() : "dictionary must be a CFDictionary or null"
*>
fn void dictionary_entries(CFTypeRef dictionary, CFTypeRef[] keys, CFTypeRef[] values)
{
	if (dictionary_count(dictionary) == 0) return;
	cf_dictionary_keys_and_values(dictionary, keys.ptr, values.ptr);
}

<*
 A property-list value as plain Bleu data: a tagged tree whose strings, bytes
 and nested lists are copied out of CoreFoundation. Fields not used by the
 kind are zero. Dictionaries keep their key order in `keys`, aligned with `items`.
*>
enum PlainKind : char
{
	NIL,     // no value (a null reference)
	BOOLEAN, // `boolean`
	INTEGER, // `integer`
	REAL,    // `real`
	TEXT,    // `text`
	BYTES,   // `bytes`
	LIST,    // `items`
	MAP,     // `keys[i]` maps to `items[i]`
}

<* One node of a converted property-list tree. *>
struct Plain
{
	PlainKind kind;
	bool boolean;
	long integer;
	double real;
	String text;
	char[] bytes;
	Plain[] items;
	String[] keys;
}

<*
 Convert a CoreFoundation property-list value into a `Plain` tree. Everything
 is allocated from `allocator`, so freeing that allocator frees the whole tree.
 Strings are copied; the result does not refer to CoreFoundation memory.

 Supported: null, CFBoolean, CFNumber (integer or real), CFString, CFData,
 CFArray, CFDictionary with string keys. Other types are refused.

 @return? error::UNSUPPORTED : "for a CoreFoundation type that has no plain form"
 @return? error::INVALID_ARGUMENT : "for a dictionary with a non-string key"
 @return? error::OUT_OF_RANGE : "when nesting exceeds PLAIN_MAX_DEPTH"
*>
fn Plain? property_to_plain(CFTypeRef value, Allocator allocator)
{
	return plain_at(value, allocator, 0);
}

<* Convert one node at `depth` (see `property_to_plain`). *>
fn Plain? plain_at(CFTypeRef value, Allocator allocator, int depth) @local
{
	if (depth > PLAIN_MAX_DEPTH) return error::raise(
		error::OUT_OF_RANGE,
		error::Domain.INTERNAL,
		0,
		"property list nested deeper than %d",
		PLAIN_MAX_DEPTH
	)~;
	if (!value) return { .kind = NIL };
	CFTypeID type = cf_get_type_id(value);
	if (type == cf_string_type_id()) return { .kind = TEXT, .text = string_value(value, allocator)! };
	if (type == cf_boolean_type_id()) return { .kind = BOOLEAN, .boolean = cf_boolean_get_value(value) };
	if (type == cf_number_type_id())
	{
		if (cf_number_is_float(value)) return { .kind = REAL, .real = number_double(value) };
		return { .kind = INTEGER, .integer = number_long(value)! };
	}
	if (type == cf_data_type_id()) return { .kind = BYTES, .bytes = data_bytes(value, allocator)! };
	if (type == cf_array_type_id()) return list_to_plain(value, allocator, depth);
	if (type == cf_dictionary_type_id()) return map_to_plain(value, allocator, depth);
	return error::raise(
		error::UNSUPPORTED,
		error::Domain.INTERNAL,
		0,
		"CoreFoundation type %d has no plain form",
		(int)type
	)~;
}

<* Convert a CFArray at `depth`. *>
fn Plain? list_to_plain(CFTypeRef array, Allocator allocator, int depth) @local
{
	sz count      = array_count(array);
	Plain[] items = alloc::new_array(allocator, Plain, count);
	for (sz i = 0; i < count; i++)
	{
		items[i] = plain_at(array_at(array, i), allocator, depth + 1)!;
	}
	return { .kind = LIST, .items = items };
}

<* Convert a CFDictionary at `depth`, refusing non-string keys. *>
fn Plain? map_to_plain(CFTypeRef dictionary, Allocator allocator, int depth) @local
{
	sz count             = dictionary_count(dictionary);
	Plain[] items        = alloc::new_array(allocator, Plain, count);
	String[] keys        = alloc::new_array(allocator, String, count);
	// The raw references are scratch: they come from the heap, because the results
	// are allocated from `allocator` (which may be `tmem`) and no pool may be open here.
	CFTypeRef[] raw_keys = alloc::new_array(mem, CFTypeRef, count);
	defer alloc::free(mem, raw_keys.ptr);
	CFTypeRef[] raw_values = alloc::new_array(mem, CFTypeRef, count);
	defer alloc::free(mem, raw_values.ptr);
	dictionary_entries(dictionary, raw_keys, raw_values);
	for (sz i = 0; i < count; i++)
	{
		if (!raw_keys[i] || cf_get_type_id(raw_keys[i]) != cf_string_type_id())
		{
			return error::raise(
				error::INVALID_ARGUMENT,
				error::Domain.INTERNAL,
				0,
				"dictionary key %d is not a string",
				(int)i
			)~;
		}
		keys[i] = string_value(raw_keys[i], allocator)!;
		items[i] = plain_at(raw_values[i], allocator, depth + 1)!;
	}
	return { .kind = MAP, .items = items, .keys = keys };
}