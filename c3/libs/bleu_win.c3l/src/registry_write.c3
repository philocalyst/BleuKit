<*
 Writing registry values. Part of `bleu::win::registry`; the key must have been
 opened with `KEY_SET_VALUE` (`KEY_WRITE`).

 Source: `RegSetValueExW` (winreg.h; Learn "RegSetValueExW"). Data layout: a
 `REG_DWORD` and `REG_QWORD` are little-endian, `REG_SZ` is UTF-16 with a
 terminating NUL (Learn, "Registry Value Types").
*>
module bleu::win::registry @feat(WIN32) @link("advapi32");
import std::os::win32;
import bleu::error;
import bleu::win::errors, bleu::win::text;

extern fn Win32_LSTATUS regSetValueExW(
	void* key,
	WString name,
	uint reserved,
	uint type,
	void* data,
	uint size
) @cname("RegSetValueExW");

<*
 Set a `REG_DWORD` value, creating it if needed.

 @return? error::PERMISSION_DENIED : "The key was not opened for writing"
*>
fn void? Key.set_dword(&self, String name, uint value)
{
	char[4] bytes = { (char)value, (char)(value >> 8), (char)(value >> 16), (char)(value >> 24) };
	write_value(self.handle, name, REG_DWORD, &bytes, 4)!;
}

<*
 Set a `REG_QWORD` value, creating it if needed.

 @return? error::PERMISSION_DENIED : "The key was not opened for writing"
*>
fn void? Key.set_qword(&self, String name, ulong value)
{
	char[8] bytes;
	for (usz i = 0; i < 8; i++) bytes[i] = (char)(value >> (i * 8));
	write_value(self.handle, name, REG_QWORD, &bytes, 8)!;
}

<*
 Set a `REG_SZ` value to `value`, creating it if needed.

 @return? error::INVALID_ARGUMENT : "`value` is not valid UTF-8"
 @return? error::PERMISSION_DENIED : "The key was not opened for writing"
*>
fn void? Key.set_string(&self, String name, String value)
{
	WideZ wide = text::to_wide(tmem, value)!;
	// The data includes the terminating NUL, and its size is in bytes.
	write_value(self.handle, name, REG_SZ, wide.as_wstring(), (usz)(wide.len() + 1) * Char16::size)!;
}

<* Store `size` bytes at `data` as value `name` of `type` in the open key `key`. *>
fn void? write_value(void* key, String name, uint type, void* data, usz size) @local
{
	WideZ wide  = text::to_wide(tmem, name)!;
	uint status = (uint)regSetValueExW(key, wide.as_wstring(), 0, type, data, (uint)size);
	if (status != ERROR_SUCCESS) return errors::raise_win32(status, "RegSetValueExW")~;
}