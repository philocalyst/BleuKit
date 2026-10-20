<*
 The platform loader's own account of its most recent failure.

 Read it immediately after the failing `dlopen`, `dlsym` or `LoadLibraryExW`
 call: POSIX `dlerror()` and `GetLastError()` describe only the last call.
 `text` is copied into the temporary allocator and is valid only until the
 enclosing `@pool()` ends.
*>
module bleu::dl::native;
import std::os, libc, bleu::error;

const uint FORMAT_MESSAGE_FROM_SYSTEM = 0x00001000;
const uint FORMAT_MESSAGE_IGNORE_INSERTS = 0x00000200;
const uint WIN32_MESSAGE_CAPACITY = 256;

// POSIX: returns the text of the last `dlopen`/`dlsym` failure, or null if there is none.
extern fn ZString posix_dlerror() @cname("dlerror");

// Win32: FormatMessageA (ANSI variant; the message is only for diagnostics).
extern fn uint format_message_a(uint flags, void* source, uint message_id, uint language_id, char* buffer, uint size, void* arguments) @cname("FormatMessageA");

<* One failure as the loader reported it. *>
struct Failure
{
	error::Domain domain;
	int code;
	String text;
}

<*
 Read the loader's failure state for this thread.

 @return "The domain, native code and a human-readable text of the failure"
*>
fn Failure last_failure()
{
	$if env::WIN32:
		uint code = std::os::win32::getLastError();
		char[WIN32_MESSAGE_CAPACITY] buffer;
		uint length = format_message_a(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, null, code, 0, &buffer[0], WIN32_MESSAGE_CAPACITY, null);
		if (length == 0) return { .domain = error::Domain.WIN32, .code = (int)code, .text = string::tformat("Windows error %u", code) };
		// FormatMessage terminates the text with CR LF; drop it.
		while (length > 0 && (buffer[length - 1] == '\n' || buffer[length - 1] == '\r')) length--;
		return { .domain = error::Domain.WIN32, .code = (int)code, .text = ((String)buffer[:length]).tcopy() };
	$else
		int code = (int)libc::errno();
		ZString text = posix_dlerror();
		if (!text) return { .domain = error::Domain.ERRNO, .code = code, .text = "the loader gave no reason" };
		return { .domain = error::Domain.ERRNO, .code = code, .text = text.tcopy() };
	$endif
}
