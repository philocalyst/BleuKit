<*
 Windows half of the root module: `Native` is a HANDLE, which is what
 `WaitForMultipleObjects` waits on. See `rt_posix.c3` for the module overview.
*>
module bleu::rt @feat(WIN32);
import std::os::win32;

<*
 A waitable native object: a kernel object handle (event, process, thread,
 timer or wait-able socket event) that `WaitForMultipleObjects` accepts.
*>
typedef Native = Win32_HANDLE;
