<*
 Raising Win32 and HRESULT failures as Bleu faults.

 Every failure is recorded in `error::last()` with `Domain.WIN32`, its native
 code, and the text that `FormatMessageW` gives for that code, so a shell can
 show "Access is denied" instead of "0x80070005".

 Source for `FormatMessageW`: winbase.h (mingw-w64 `winbase.h`; Wine
 `include/winbase.h`), Microsoft Learn "FormatMessageW"
 (https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-formatmessagew).
*>
module bleu::win::errors @feat(WIN32) @link("kernel32");
import std::os::win32, std::core::string;
import bleu::error, bleu::win::hresult, bleu::win::text;

<* `FORMAT_MESSAGE_FROM_SYSTEM`: look the code up in the system message table. *>
const Win32_DWORD FORMAT_MESSAGE_FROM_SYSTEM    = 0x00001000;
<* `FORMAT_MESSAGE_IGNORE_INSERTS`: do not expand `%1`-style inserts (we pass none). *>
const Win32_DWORD FORMAT_MESSAGE_IGNORE_INSERTS = 0x00000200;
<* Capacity of the message buffer, in UTF-16 units. System messages are far shorter. *>
const usz MESSAGE_CAPACITY                      = 512;
<* Language 0 is `LANG_NEUTRAL` with `SUBLANG_DEFAULT`: the user's installed language. *>
const Win32_DWORD LANG_USER_DEFAULT             = 0;

extern fn Win32_DWORD formatMessageW(
	Win32_DWORD flags,
	void* source,
	Win32_DWORD message_id,
	Win32_DWORD language,
	Win32_LPWSTR buffer,
	Win32_DWORD size,
	void* arguments
) @cname("FormatMessageW");

<*
 The system's text for a code, trimmed of the trailing line break that
 `FormatMessageW` appends. Returns the empty string when the system has no text.

 @param allocator : "Where the returned text lives"
 @param code : "A Win32 error code or an HRESULT"
*>
fn String system_message(Allocator allocator, uint code)
{
	Char16[MESSAGE_CAPACITY] buffer;
	Win32_DWORD written = formatMessageW(
		FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
		null,
		code,
		LANG_USER_DEFAULT,
		&buffer,
		MESSAGE_CAPACITY,
		null
	);
	if (written == 0) return "";
	// A message that is not valid UTF-16 is only decoration for the error; the code is still reported.
	String text = text::from_wide_units(allocator, buffer[:written]) ?? "";
	return text.trim();
}

<*
 Record `hr` as the thread's last failure and return the fault it maps to.
 Use as `return errors::raise_hresult(hr, "CoCreateInstance")~;`.

 @param hr : "A failed HRESULT"
 @param context : "What the caller was doing, for the message"
 @return "The fault for `hr`, see `hresult::Hresult.to_fault`"
*>
fn fault raise_hresult(hresult::Hresult hr, String context)
{
	@pool()
	{
		String message = system_message(tmem, (uint)hr);
		return error::raise(
			hr.to_fault(),
			error::Domain.WIN32,
			(int)hr,
			"%s failed: %s (0x%x)",
			context,
			message,
			(uint)hr
		);
	};
}

<*
 Record a Win32 error code as the thread's last failure and return its fault.

 @param code : "A Win32 error code, such as from `GetLastError`"
 @param context : "What the caller was doing, for the message"
*>
fn fault raise_win32(uint code, String context)
{
	@pool()
	{
		String message = system_message(tmem, code);
		return error::raise(
			hresult::win32_to_fault(code),
			error::Domain.WIN32,
			(int)code,
			"%s failed: %s (%d)",
			context,
			message,
			code
		);
	};
}

<*
 Record the calling thread's `GetLastError` value as the last failure. Reads
 the code first, so call it before anything else that may fail.

 @param context : "What the caller was doing, for the message"
*>
fn fault raise_last(String context)
{
	uint code = win32::getLastError();
	return raise_win32(code, context);
}