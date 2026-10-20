<*
 The kernel32 calls that name a window's program: the process handle and the image
 path. Values: processthreadsapi.h and winbase.h (mingw-w64 `hdr/` copies), checked
 against windows-sys 0.59.0 `System/Threading/mod.rs` (lines 242, 255, 531).
*>
module bleu::windows::win32_proc @feat(WIN32) @link("kernel32");

// PROCESS_QUERY_LIMITED_INFORMATION: enough to read a process's image path.
const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
// PROCESS_NAME_WIN32 asks for the path in the Win32 form (drive letters), flags 0.
const uint PROCESS_NAME_WIN32                = 0;

extern fn void* open_process(uint access, int inherit_handle, uint process_id) @cname("OpenProcess");
extern fn int close_handle(void* handle) @cname("CloseHandle");
extern fn int query_full_process_image_name_w(
	void* process,
	uint flags,
	Char16* name,
	uint* size
) @cname("QueryFullProcessImageNameW");