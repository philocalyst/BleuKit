<*
 Facts about the running process that a shell needs: whether it is elevated,
 which user it runs as, the image it was started from, its session, and
 whether the session's workstation is locked.

 Sources: winnt.h (`TOKEN_INFORMATION_CLASS`: TokenUser = 1, TokenElevation = 20),
 sddl.h (`ConvertSidToStringSidW`), processthreadsapi.h (`OpenProcess`,
 `QueryFullProcessImageNameW`, `ProcessIdToSessionId`), and Microsoft Learn for
 each (docs/research/bleu_win.md, section 9).
*>
module bleu::win::process @feat(WIN32) @link("advapi32");
import std::os::win32;
import bleu::error;
import bleu::win::errors, bleu::win::hresult, bleu::win::session, bleu::win::text;

<* `TOKEN_QUERY`: read a token's information. winnt.h. *>
const uint TOKEN_QUERY                       = 0x0008;
<* `TokenUser` (winnt.h `TOKEN_INFORMATION_CLASS`). *>
const uint TOKEN_USER_CLASS                  = 1;
<* `TokenElevation` (winnt.h `TOKEN_INFORMATION_CLASS`). *>
const uint TOKEN_ELEVATION_CLASS             = 20;
<* `PROCESS_QUERY_LIMITED_INFORMATION`: read a process's image name without full access. winnt.h. *>
const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
<*
 Longest path the Windows API returns, in characters: 32,767 (Learn, "Maximum
 file path limitation"). Sized for the extended-length form.
*>
const usz MAX_EXTENDED_PATH                  = 32767;

extern fn Win32_BOOL openProcessToken(void* process, uint access, void** token) @cname("OpenProcessToken");
extern fn Win32_BOOL getTokenInformation(
	void* token,
	uint info_class,
	void* info,
	uint length,
	uint* return_length
) @cname("GetTokenInformation");
extern fn Win32_BOOL convertSidToStringSidW(void* sid, WString* out) @cname("ConvertSidToStringSidW");
extern fn void* localFree(void* memory) @cname("LocalFree");
extern fn void* openProcess(uint access, Win32_BOOL inherit, uint process_id) @cname("OpenProcess");
extern fn Win32_BOOL queryFullProcessImageNameW(
	void* process,
	uint flags,
	Char16* name,
	uint* size
) @cname("QueryFullProcessImageNameW");
extern fn Win32_BOOL processIdToSessionId(uint process_id, uint* session) @cname("ProcessIdToSessionId");

<* `TOKEN_ELEVATION` (winnt.h): non-zero when the token is elevated. *>
struct TokenElevation
{
	uint is_elevated;
}

<* `SID_AND_ATTRIBUTES` (winnt.h): a SID pointer and its attributes. 16 bytes on 64-bit Windows. *>
struct SidAndAttributes
{
	void* sid;
	uint attributes;
}

<* `TOKEN_USER` (winnt.h): the user's SID. *>
struct TokenUser
{
	SidAndAttributes user;
}

<* Open the calling process's token for reading. The caller closes it. *>
fn void*? open_current_token() @local
{
	void* token = null;
	if (openProcessToken(
		win32::getCurrentProcess(),
		TOKEN_QUERY,
		&token
	) == 0) return errors::raise_last("OpenProcessToken")~;
	return token;
}

<*
 Whether the process runs elevated (UAC has granted it its full token).

 @return? error::PERMISSION_DENIED : "The token could not be read"
*>
fn bool? is_elevated()
{
	void* token = open_current_token()!;
	defer win32::closeHandle(token);
	TokenElevation info;
	uint returned = 0;
	if (getTokenInformation(token, TOKEN_ELEVATION_CLASS, &info, TokenElevation::size, &returned) == 0)
	{
		return errors::raise_last("GetTokenInformation(TokenElevation)")~;
	}
	return info.is_elevated != 0;
}

<*
 The SID of the user the process runs as, in the string form `S-1-5-...`.

 @param allocator : "Where the string lives"
 @return? error::BACKEND_FAILURE : "The token or the SID could not be read"
*>
fn String? current_user_sid(Allocator allocator)
{
	void* token = open_current_token()!;
	defer win32::closeHandle(token);
	uint needed = 0;
	// The first call only reports the size; it is expected to fail with ERROR_INSUFFICIENT_BUFFER.
	if (getTokenInformation(token, TOKEN_USER_CLASS, null, 0, &needed) == 0)
	{
		uint code = win32::getLastError();
		if (code != hresult::ERROR_INSUFFICIENT_BUFFER) return errors::raise_win32(
			code,
			"GetTokenInformation(TokenUser)"
		)~;
	}
	// TOKEN_USER holds pointers: the storage is in whole 8-byte words to keep it aligned.
	sz words        = (sz)(needed + 7) / 8;
	ulong[] storage = alloc::new_array(tmem, ulong, words)[:words];
	if (getTokenInformation(token, TOKEN_USER_CLASS, storage.ptr, needed, &needed) == 0)
	{
		return errors::raise_last("GetTokenInformation(TokenUser)")~;
	}
	TokenUser* user  = (TokenUser*)storage.ptr;
	WString sid_text = null;
	if (convertSidToStringSidW(user.user.sid, &sid_text) == 0) return errors::raise_last("ConvertSidToStringSidW")~;
	defer localFree(sid_text);
	return text::from_wide(allocator, sid_text);
}

<*
 Full path of the executable of process `process_id`, in Win32 form (`C:\...`).
 Use `win32::getCurrentProcessId()` for this process.

 @param allocator : "Where the path lives"
 @return? error::PERMISSION_DENIED : "The process cannot be opened for queries"
 @return? NOT_FOUND : "No such process"
*>
fn String? query_image_name(uint process_id, Allocator allocator)
{
	void* process = openProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, process_id);
	if (!process) return errors::raise_last("OpenProcess")~;
	defer win32::closeHandle(process);
	Char16[] buffer = alloc::new_array(tmem, Char16, MAX_EXTENDED_PATH)[:MAX_EXTENDED_PATH];
	uint size       = (uint)MAX_EXTENDED_PATH;
	if (queryFullProcessImageNameW(
		process,
		0,
		buffer.ptr,
		&size
	) == 0) return errors::raise_last("QueryFullProcessImageNameW")~;
	return text::from_wide_units(allocator, buffer[:size]);
}

<*
 The terminal-services session this process runs in.

 @return? error::BACKEND_FAILURE : "ProcessIdToSessionId failed"
*>
fn uint? wts_session_id()
{
	uint session = 0;
	if (processIdToSessionId(
		win32::getCurrentProcessId(),
		&session
	) == 0) return errors::raise_last("ProcessIdToSessionId")~;
	return session;
}

<*
 Whether the workstation this process runs in is locked: the lock screen is up,
 and the user has not signed back in. Asks the session, so it is correct for
 processes that have no window and no desktop of their own.

 @return? error::UNAVAILABLE : "The system reports the lock state as unknown"
*>
fn bool? locked_workstation()
{
	return session::is_locked(session::WTS_CURRENT_SESSION);
}