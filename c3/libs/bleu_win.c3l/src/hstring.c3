<*
 WinRT's HSTRING: a reference-counted, immutable UTF-16 string the runtime owns.

 `Hstring` owns one handle and releases it with `close`. Source: winstring.h
 (mingw-w64; Wine include/winstring.h) and Microsoft Learn "HSTRING"
 (https://learn.microsoft.com/en-us/windows/win32/winrt/hstring). The functions
 are exported by the WinRT runtime (`runtimeobject.lib`, Microsoft Learn
 "WindowsCreateString": Library RuntimeObject.lib).
*>
module bleu::win::hstring @feat(WIN32) @link("runtimeobject");
import bleu::error, bleu::win::hresult, bleu::win::errors, bleu::win::text;

<* An owned HSTRING handle. A null handle is the empty string. *>
struct Hstring
{
	void* handle;
}

extern fn hresult::Hresult windowsCreateString(Char16* text, uint length, void** out) @cname("WindowsCreateString");
extern fn hresult::Hresult windowsDeleteString(void* handle) @cname("WindowsDeleteString");
extern fn Char16* windowsGetStringRawBuffer(void* handle, uint* length) @cname("WindowsGetStringRawBuffer");

<*
 Create an HSTRING holding a copy of `text`.

 @param text : "UTF-8 text"
 @return "The owned handle; release it with `Hstring.close`"
 @return? error::INVALID_ARGUMENT : "If `text` is not valid UTF-8"
 @return? error::NO_MEMORY : "If the runtime could not allocate the string"
*>
fn Hstring? create(String text)
{
	WideZ wide = text::to_wide(tmem, text)!;
	void* handle = null;
	hresult::Hresult hr = (hresult::Hresult)windowsCreateString(wide.units.ptr, (uint)wide.len(), &handle);
	if (hr.failed()) return errors::raise_hresult(hr, "WindowsCreateString")~;
	return { .handle = handle };
}

<* Release the handle. Safe on the empty string. The value must not be used afterwards. *>
fn void Hstring.close(&self)
{
	if (self.handle) windowsDeleteString(self.handle);
	self.handle = null;
}

<*
 Copy the string's text into UTF-8, allocated from `allocator`.

 @param allocator : "Where the text lives"
 @return? error::BACKEND_FAILURE : "If the runtime holds text that is not valid UTF-16"
*>
fn String? Hstring.to_string(self, Allocator allocator)
{
	uint length = 0;
	Char16* raw = windowsGetStringRawBuffer(self.handle, &length);
	if (!raw || length == 0) return "".copy(allocator);
	return text::from_wide_units(allocator, raw[:length]);
}
