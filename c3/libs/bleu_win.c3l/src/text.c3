<*
 Text at the Windows boundary: UTF-8 (Bleu's `String`) to UTF-16 (`WCHAR`,
 `LPCWSTR`, BSTR and HSTRING payloads) and back.

 The conversion is the standard library's (`String.to_utf16`,
 `string::from_wstring`), which validates both directions, so it is the same
 on every host and needs no `MultiByteToWideChar` call. Invalid input is
 reported as an error, never silently replaced.

 Pure logic: unit-tested on every host.
*>
module bleu::win::text;
import std::core::string;
import bleu::error;

<*
 A UTF-16 string owned by its allocator, with the zero terminator that Win32
 APIs expect after the last unit. `units` holds the text without the
 terminator; the unit after `units[units.len - 1]` is zero.
*>
struct WideZ
{
	Char16[] units;
	Allocator allocator;
}

<* The zero-terminated pointer, for `LPCWSTR` parameters. Valid until `free`. *>
fn WString WideZ.as_wstring(self) @inline => (WString)self.units.ptr;

<* Number of UTF-16 code units, excluding the terminator. *>
fn sz WideZ.len(self) @inline => self.units.len;

<* Release the buffer. The value must not be used afterwards. *>
fn void WideZ.free(&self)
{
	alloc::free(self.allocator, self.units.ptr);
	self.units = { };
}

<*
 Convert UTF-8 to a zero-terminated UTF-16 buffer allocated from `allocator`.

 @param allocator : "Where the buffer lives; release it with `WideZ.free`"
 @param text : "UTF-8 text"
 @return "The UTF-16 buffer"
 @return? error::INVALID_ARGUMENT : "If `text` is not valid UTF-8"
*>
fn WideZ? to_wide(Allocator allocator, String text)
{
	if (try units = text.to_utf16(allocator)) return { .units = units, .allocator = allocator };
	return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "text is not valid UTF-8")~;
}

<*
 Convert a zero-terminated UTF-16 string to UTF-8, allocated from `allocator`.
 A null pointer is an error, not an empty string.

 @param allocator : "Where the result lives"
 @param text : "The zero-terminated UTF-16 string"
 @return "The UTF-8 text"
 @return? error::BACKEND_FAILURE : "If the string is not valid UTF-16"
*>
fn String? from_wide(Allocator allocator, WString text)
{
	if (!text) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "null wide string")~;
	if (try result = string::from_wstring(allocator, text)) return result;
	return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, 0, "wide string is not valid UTF-16")~;
}

<*
 Convert a UTF-16 slice (not zero-terminated) to UTF-8, allocated from `allocator`.

 @param allocator : "Where the result lives"
 @param units : "The UTF-16 code units"
 @return "The UTF-8 text"
 @return? error::BACKEND_FAILURE : "If the units are not valid UTF-16"
*>
fn String? from_wide_units(Allocator allocator, Char16[] units)
{
	if (try result = string::from_utf16(allocator, units)) return result;
	return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, 0, "UTF-16 units are not valid")~;
}