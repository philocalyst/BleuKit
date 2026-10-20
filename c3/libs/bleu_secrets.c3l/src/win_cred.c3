<*
 Windows Credential Manager declarations, in advapi32.

 Sources: wincred.h as in the Wine headers
 (https://raw.githubusercontent.com/wine-mirror/wine/master/include/wincred.h):
 CREDENTIALW (lines 92-106), CREDENTIAL_ATTRIBUTEW (65-71), the prototypes
 CredDeleteW, CredEnumerateW, CredFree, CredReadW and CredWriteW (lines 255-281),
 CRED_TYPE_GENERIC = 1 (214), CRED_PERSIST_LOCAL_MACHINE = 2 (225),
 CRED_MAX_CREDENTIAL_BLOB_SIZE = 5 * 512 (197, 196), CRED_MAX_ATTRIBUTES = 64 (194);
 ERROR_NOT_FOUND = 1168 (winerror.h line 1011). Microsoft Learn's CREDENTIALW page
 gives the same field order and values. Compiled only: nothing here has run.
*>
module bleu::secrets::cred @feat(WIN32) @link("advapi32");
import std::os::win32;

<* Generic credential: an application's own secret (wincred.h line 214). *>
const Win32_DWORD CRED_TYPE_GENERIC             = 1;
<* Survives reboots on this machine only, unlike CRED_PERSIST_ENTERPRISE (wincred.h line 225). *>
const Win32_DWORD CRED_PERSIST_LOCAL_MACHINE    = 2;
<* Largest blob CredWriteW accepts: 5 * CRED_MAX_BLOB_SIZE (512) bytes (wincred.h 196-197). *>
const Win32_DWORD CRED_MAX_CREDENTIAL_BLOB_SIZE = 2560;
<* Most attributes one credential may carry (wincred.h line 194). *>
const Win32_DWORD CRED_MAX_ATTRIBUTES           = 64;
<* GetLastError value for "no such credential" (winerror.h line 1011). *>
const Win32_DWORD ERROR_NOT_FOUND               = 1168;

<* FILETIME as two 32-bit halves (100 ns units since 1601). *>
struct Filetime
{
	uint low;
	uint high;
}

<* CREDENTIAL_ATTRIBUTEW: a keyword with an opaque value. *>
struct CredentialAttribute
{
	WString keyword;
	Win32_DWORD flags;
	Win32_DWORD value_size;
	char* value;
}

<* CREDENTIALW. The field order is the ABI; do not reorder. *>
struct Credential
{
	Win32_DWORD flags;
	Win32_DWORD type;
	WString target_name;
	WString comment;
	Filetime last_written;
	Win32_DWORD blob_size;
	char* blob;
	Win32_DWORD persist;
	Win32_DWORD attribute_count;
	CredentialAttribute* attributes;
	WString target_alias;
	WString user_name;
}

extern fn Win32_BOOL cred_write(Credential* credential, Win32_DWORD flags) @cname("CredWriteW");
extern fn Win32_BOOL cred_read(
	WString target,
	Win32_DWORD type,
	Win32_DWORD flags,
	Credential** found
) @cname("CredReadW");
extern fn Win32_BOOL cred_delete(WString target, Win32_DWORD type, Win32_DWORD flags) @cname("CredDeleteW");
extern fn Win32_BOOL cred_enumerate(
	WString filter,
	Win32_DWORD flags,
	Win32_DWORD* count,
	Credential*** found
) @cname("CredEnumerateW");
extern fn void cred_free(void* buffer) @cname("CredFree");