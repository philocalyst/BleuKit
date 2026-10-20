<*
 The Windows registry: opening keys in an explicit registry view, reading typed
 values, and enumerating subkeys and values.

 Every failure is a Bleu fault, recorded with `Domain.WIN32` and the native
 code in `error::last()`. A value of a different type than the one asked for
 is `INVALID_ARGUMENT`. Sources: winreg.h and winnt.h (`KEY_*`, `REG_*`),
 Microsoft Learn "RegOpenKeyExW", "RegQueryValueExW", "RegEnumKeyExW",
 "RegEnumValueW", "Registry Element Size Limits" and "Accessing an Alternate
 Registry View" (docs/research/bleu_win.md, section 8).
*>
module bleu::win::registry @feat(WIN32) @link("advapi32");
import std::os::win32, std::collections::list;
import bleu::error;
import bleu::win::errors, bleu::win::hresult, bleu::win::text;

<* The root key a path is relative to. *>
enum Hive : char
{
	LOCAL_MACHINE, // HKEY_LOCAL_MACHINE
	CURRENT_USER,  // HKEY_CURRENT_USER
}

<*
 Which registry view to open a key in. On 64-bit Windows a 32-bit process sees
 redirected keys (for example under `Software\WOW6432Node`); `WOW64_64` and
 `WOW64_32` name a view explicitly, and `NATIVE` uses the caller's own.
*>
enum View : char
{
	NATIVE,
	WOW64_64,
	WOW64_32,
}

<* `KEY_QUERY_VALUE`: read values. winnt.h. *>
const uint KEY_QUERY_VALUE        = 0x0001;
<* `KEY_SET_VALUE`: write values. winnt.h. *>
const uint KEY_SET_VALUE          = 0x0002;
<* `KEY_CREATE_SUB_KEY`: create subkeys. winnt.h. *>
const uint KEY_CREATE_SUB_KEY     = 0x0004;
<* `KEY_ENUMERATE_SUB_KEYS`: list subkeys. winnt.h. *>
const uint KEY_ENUMERATE_SUB_KEYS = 0x0008;
<* `KEY_NOTIFY`: watch for changes. winnt.h. *>
const uint KEY_NOTIFY             = 0x0010;
<* `KEY_WOW64_64KEY`: open the 64-bit view explicitly. winnt.h; Learn "Accessing an Alternate Registry View". *>
const uint KEY_WOW64_64KEY        = 0x0100;
<* `KEY_WOW64_32KEY`: open the 32-bit view explicitly. winnt.h; Learn "Accessing an Alternate Registry View". *>
const uint KEY_WOW64_32KEY        = 0x0200;
<* `KEY_READ` = STANDARD_RIGHTS_READ | query | enumerate | notify (winnt.h, without SYNCHRONIZE). *>
const uint KEY_READ               = 0x00020019;
<* `KEY_WRITE` = STANDARD_RIGHTS_WRITE | set value | create subkey (winnt.h). *>
const uint KEY_WRITE              = 0x00020006;

<* `REG_SZ`: a NUL-terminated string. winnt.h. *>
const uint REG_SZ        = 1;
<* `REG_EXPAND_SZ`: a string with `%VAR%` references, returned unexpanded. winnt.h. *>
const uint REG_EXPAND_SZ = 2;
<* `REG_BINARY`: raw bytes. winnt.h. *>
const uint REG_BINARY    = 3;
<* `REG_DWORD`: a 32-bit little-endian integer. winnt.h. *>
const uint REG_DWORD     = 4;
<* `REG_MULTI_SZ`: NUL-separated strings ending with an empty string. winnt.h. *>
const uint REG_MULTI_SZ  = 7;
<* `REG_QWORD`: a 64-bit little-endian integer. winnt.h. *>
const uint REG_QWORD     = 11;

<* Longest key name, in characters (Learn, "Registry Element Size Limits"). *>
const usz MAX_KEY_NAME   = 255;
<* Longest value name, in characters (Learn, "Registry Element Size Limits"). *>
const usz MAX_VALUE_NAME = 16383;
<* `ERROR_SUCCESS`. *>
const uint ERROR_SUCCESS = 0;

extern fn Win32_LSTATUS regOpenKeyExW(
	void* root,
	WString path,
	uint options,
	uint access,
	void** out
) @cname("RegOpenKeyExW");
extern fn Win32_LSTATUS regCloseKey(void* key) @cname("RegCloseKey");
extern fn Win32_LSTATUS regQueryValueExW(
	void* key,
	WString name,
	uint* reserved,
	uint* type,
	void* data,
	uint* size
) @cname("RegQueryValueExW");
extern fn Win32_LSTATUS regEnumKeyExW(
	void* key,
	uint index,
	Char16* name,
	uint* name_size,
	uint* reserved,
	Char16* class_name,
	uint* class_size,
	void* last_write
) @cname("RegEnumKeyExW");
extern fn Win32_LSTATUS regEnumValueW(
	void* key,
	uint index,
	Char16* name,
	uint* name_size,
	uint* reserved,
	uint* type,
	void* data,
	uint* data_size
) @cname("RegEnumValueW");

<*
 An open registry key. Owns its handle until `close`.
*>
struct Key
{
	void* handle;
}

<*
 Open the key `path` under `hive`, in `view`, with the given access rights
 (`KEY_READ`, `KEY_WRITE`, or a combination).

 @param path : "The key's path under the hive, with backslashes, for example `Software\\Microsoft\\Windows`"
 @return "An open key; release it with `Key.close`"
 @return? NOT_FOUND : "The key does not exist in that view"
 @return? error::PERMISSION_DENIED : "The access rights were refused"
*>
fn Key? open(Hive hive, String path, View view, uint access)
{
	WideZ wide   = text::to_wide(tmem, path)!;
	uint options = access;
	if (view == WOW64_64) options |= KEY_WOW64_64KEY;
	if (view == WOW64_32) options |= KEY_WOW64_32KEY;
	void* root   = hive == LOCAL_MACHINE ? win32::HKEY_LOCAL_MACHINE : win32::HKEY_CURRENT_USER;
	void* handle = null;
	uint status  = (uint)regOpenKeyExW(root, wide.as_wstring(), 0, options, &handle);
	if (status != ERROR_SUCCESS) return errors::raise_win32(status, "RegOpenKeyExW")~;
	return { .handle = handle };
}

<* Close the key. Safe on a closed key. *>
fn void Key.close(&self)
{
	if (self.handle) regCloseKey(self.handle);
	self.handle = null;
}

<*
 Read a `REG_DWORD` value.

 @return? error::INVALID_ARGUMENT : "The value is not a `REG_DWORD`"
 @return? NOT_FOUND : "The value does not exist"
*>
fn uint? Key.dword(&self, String name)
{
	char[] bytes = typed_value(self, tmem, name, REG_DWORD, 4)!;
	return (uint)bytes[0] | ((uint)bytes[1] << 8) | ((uint)bytes[2] << 16) | ((uint)bytes[3] << 24);
}

<*
 Read a `REG_QWORD` value.

 @return? error::INVALID_ARGUMENT : "The value is not a `REG_QWORD`"
 @return? NOT_FOUND : "The value does not exist"
*>
fn ulong? Key.qword(&self, String name)
{
	char[] bytes = typed_value(self, tmem, name, REG_QWORD, 8)!;
	ulong value  = 0;
	for (usz i = 0; i < 8; i++) value |= (ulong)bytes[i] << (i * 8);
	return value;
}

<*
 Read a `REG_SZ` or `REG_EXPAND_SZ` value as UTF-8. The text stops at the
 first NUL; `REG_EXPAND_SZ` is returned unexpanded.

 @param allocator : "Where the text lives"
 @return? error::INVALID_ARGUMENT : "The value is not a string"
*>
fn String? Key.string(&self, Allocator allocator, String name)
{
	char[] bytes   = typed_value(self, tmem, name, REG_SZ, -1)!;
	Char16[] units = wide_units(bytes);
	return text::from_wide_units(allocator, units[:first_nul(units)]);
}

<*
 Read a `REG_MULTI_SZ` value: its strings, in order, as UTF-8. The list ends at
 the empty string that terminates the value.

 @param allocator : "Where the strings live"
 @return? error::INVALID_ARGUMENT : "The value is not a `REG_MULTI_SZ`"
*>
fn String[]? Key.multi_string(&self, Allocator allocator, String name)
{
	char[] bytes   = typed_value(self, tmem, name, REG_MULTI_SZ, -1)!;
	Char16[] units = wide_units(bytes);
	List{String} parts;
	parts.tinit();
	usz start = 0;
	for (usz i = 0; i < units.len; i++)
	{
		if (units[i] != 0) continue;
		if (i == start) break;
		parts.push(text::from_wide_units(allocator, units[start:i - start])!);
		start = i + 1;
	}
	return parts.to_array(allocator);
}

<*
 Read a `REG_BINARY` value.

 @param allocator : "Where the bytes live"
 @return? error::INVALID_ARGUMENT : "The value is not `REG_BINARY`"
*>
fn char[]? Key.binary(&self, Allocator allocator, String name)
{
	char[] bytes = typed_value(self, tmem, name, REG_BINARY, -1)!;
	char[] copy  = alloc::new_array(allocator, char, bytes.len)[:bytes.len];
	mem::copy(copy.ptr, bytes.ptr, bytes.len);
	return copy;
}

<*
 Names of the subkeys of this key, in the order the system returns them.

 @param allocator : "Where the names live"
 @return? error::PERMISSION_DENIED : "The key cannot be enumerated"
*>
fn String[]? Key.subkeys(&self, Allocator allocator)
{
	List{String} names;
	names.tinit();
	Char16[MAX_KEY_NAME + 1] buffer;
	for (uint index = 0;; index++)
	{
		uint length = MAX_KEY_NAME + 1;
		uint status = (uint)regEnumKeyExW(self.handle, index, &buffer, &length, null, null, null, null);
		if (status == hresult::ERROR_NO_MORE_ITEMS) break;
		if (status != ERROR_SUCCESS) return errors::raise_win32(status, "RegEnumKeyExW")~;
		names.push(text::from_wide_units(allocator, buffer[:length])!);
	}
	return names.to_array(allocator);
}

<*
 Names of the values of this key, in the order the system returns them.

 @param allocator : "Where the names live"
 @return? error::PERMISSION_DENIED : "The key cannot be enumerated"
*>
fn String[]? Key.values(&self, Allocator allocator)
{
	List{String} names;
	names.tinit();
	Char16[MAX_VALUE_NAME + 1] buffer;
	for (uint index = 0;; index++)
	{
		uint length = MAX_VALUE_NAME + 1;
		uint status = (uint)regEnumValueW(self.handle, index, &buffer, &length, null, null, null, null);
		if (status == hresult::ERROR_NO_MORE_ITEMS) break;
		if (status != ERROR_SUCCESS) return errors::raise_win32(status, "RegEnumValueW")~;
		names.push(text::from_wide_units(allocator, buffer[:length])!);
	}
	return names.to_array(allocator);
}

<* How many times a value is read before giving up because it keeps growing. *>
const uint READ_ATTEMPTS = 3;

<*
 The data of value `name`, which must have type `expected` (`REG_EXPAND_SZ`
 also satisfies `REG_SZ`). `expected_size` is the exact byte count, or -1 for
 any size. The data lives in `allocator`.
*>
fn char[]? typed_value(Key* key, Allocator allocator, String name, uint expected, sz expected_size) @local
{
	uint type         = 0;
	char[] data       = read_value(key.handle, allocator, name, &type)!;
	bool type_matches = type == expected || (expected == REG_SZ && type == REG_EXPAND_SZ);
	if (!type_matches)
	{
		return error::raise(
			error::INVALID_ARGUMENT,
			error::Domain.WIN32,
			(int)type,
			"value '%s' has type %d, not %d",
			name,
			type,
			expected
		)~;
	}
	if (expected_size >= 0 && data.len != expected_size)
	{
		return error::raise(
			error::PROTOCOL,
			error::Domain.WIN32,
			0,
			"value '%s' has %d bytes, expected %d",
			name,
			data.len,
			expected_size
		)~;
	}
	return data;
}

<*
 Read the raw data and type of value `name`. The size is queried first and the
 read retried if the value grew in between, up to `READ_ATTEMPTS` times.
*>
fn char[]? read_value(void* key, Allocator allocator, String name, uint* type) @local
{
	WideZ wide  = text::to_wide(tmem, name)!;
	uint size   = 0;
	uint status = (uint)regQueryValueExW(key, wide.as_wstring(), null, type, null, &size);
	if (status != ERROR_SUCCESS) return errors::raise_win32(status, "RegQueryValueExW")~;
	for (uint attempt = 0; attempt < READ_ATTEMPTS; attempt++)
	{
		char[] data = alloc::new_array(allocator, char, size)[:size];
		status = (uint)regQueryValueExW(key, wide.as_wstring(), null, type, data.ptr, &size);
		if (status == ERROR_SUCCESS) return data[:size];
		alloc::free(allocator, data.ptr);
		if (status != hresult::ERROR_MORE_DATA) return errors::raise_win32(status, "RegQueryValueExW")~;
	}
	return error::raise(error::BUSY, error::Domain.WIN32, 0, "value '%s' kept growing while it was read", name)~;
}

<* The UTF-16 units of a byte buffer that the registry wrote, in place. The buffer is two-byte aligned. *>
fn Char16[] wide_units(char[] bytes) @inline => ((Char16*)bytes.ptr)[:bytes.len / 2];

<* Index of the first zero unit, or the length when there is none. *>
fn usz first_nul(Char16[] units) @inline
{
	for (usz i = 0; i < units.len; i++)
	{
		if (units[i] == 0) return i;
	}
	return units.len;
}