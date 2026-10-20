<*
 Ending a process with kill(2), shared by every POSIX platform. The signal
 numbers are the same on Linux and macOS: SIGKILL is 9 and SIGTERM is 15 (signal.h
 of glibc, bits/signum-generic.h, and XNU bsd/sys/signal.h; verified on the
 sandbox's glibc).
*>
module bleu::sysinfo @feat(POSIX);
import bleu::error, bleu::rt::unix, libc;

const CInt SIGKILL_NUMBER = 9;
const CInt SIGTERM_NUMBER = 15;

<*
 Send the signal for `mode` to `pid`. `pid` must already have passed
 `check_kill_target`: the conversion to `pid_t` below is only safe for ids up to INT_MAX.

 @return? NOT_FOUND : "No process has that id"
 @return? error::PERMISSION_DENIED : "The system refused, typically another account's process"
*>
fn void? send_signal(uint pid, KillMode mode)
{
	CInt signal = mode == FORCE ? SIGKILL_NUMBER : SIGTERM_NUMBER;
	if (sys_kill((Pid_t)pid, signal) == 0) return;
	CInt err = libc::errno();
	if ((Errno)err == Errno.ESRCH) return error::raise(NOT_FOUND, error::Domain.ERRNO, err, "no process %d", pid)~;
	return unix::errno_fault("kill", err)~;
}

<* The id of this process (getpid(2)). *>
fn uint own_process_id()
{
	return (uint)sys_getpid();
}

extern fn CInt sys_kill(Pid_t pid, CInt signal) @cname("kill");
extern fn CInt sys_getpid() @cname("getpid");