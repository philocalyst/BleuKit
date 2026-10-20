<*
 BSTR, the length-prefixed UTF-16 string of COM automation (IDispatch,
 WMI, Shell objects).

 `Bstr` owns one BSTR and frees it with `close`. Source: oleauto.h (mingw-w64;
 Wine include/oleauto.h), Microsoft Learn "SysAllocStringLen" (Library OleAut32.lib)
 and "BSTR" (https://learn.microsoft.com/en-us/previous-versions/windows/desktop/automat/bstr).
*>
module bleu::win::bstr @feat(WIN32) @link("oleaut32");
import bleu::error, bleu::win::text;

<* An owned BSTR. A null pointer owns nothing. *>
struct Bstr
{
	Char16* ptr;
}

extern fn Char16* sysAllocStringLen(Char16* text, uint length) @cname("SysAllocStringLen");
extern fn void sysFreeString(Char16* bstr) @cname("SysFreeString");
extern fn uint sysStringLen(Char16* bstr) @cname("SysStringLen");

<*
 Allocate a BSTR holding a copy of `text`.

 @param text : "UTF-8 text"
 @return "The owned BSTR; release it with `Bstr.close`"
 @return? error::INVALID_ARGUMENT : "If `text` is not valid UTF-8"
 @return? error::NO_MEMORY : "If the system could not allocate the string"
*>
fn Bstr? create(String text)
{
	WideZ wide = text::to_wide(tmem, text)!;
	Char16* ptr = sysAllocStringLen(wide.units.ptr, (uint)wide.len());
	if (!ptr && wide.len() > 0) return error::raise(error::NO_MEMORY, error::Domain.WIN32, 0, "SysAllocStringLen failed")~;
	return { .ptr = ptr };
}

<* Free the BSTR. Safe on a null pointer. The value must not be used afterwards. *>
fn void Bstr.close(&self)
{
	if (self.ptr) sysFreeString(self.ptr);
	self.ptr = null;
}

<*
 Copy the BSTR's text into UTF-8, allocated from `allocator`. The length comes
 from the BSTR's own prefix, not from a terminator.

 @param allocator : "Where the text lives"
 @return? error::BACKEND_FAILURE : "If the BSTR holds text that is not valid UTF-16"
*>
fn String? Bstr.to_string(self, Allocator allocator)
{
	if (!self.ptr) return "".copy(allocator);
	return text::from_wide_units(allocator, self.ptr[:sysStringLen(self.ptr)]);
}
