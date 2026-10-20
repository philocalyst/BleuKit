<*
 Ending a process on Windows: OpenProcess with PROCESS_TERMINATE, then
 TerminateProcess. The platform has no polite form, so both kill modes end the
 process at once; the mode is kept in the receipt, not acted on.
*>
module bleu::sysinfo @feat(WIN32);
import std::os::win32, bleu::error, bleu::win::errors, bleu::sysinfo::win;

const uint PROCESS_TERMINATE_ACCESS = 0x0001;
const uint EXIT_CODE_KILLED         = 1;

<* The id of this process (GetCurrentProcessId). *>
fn uint own_process_id()
{
	return (uint)win32::getCurrentProcessId();
}

<*
 Terminate process `pid`.

 @return? NOT_FOUND : "No process has that id"
 @return? error::PERMISSION_DENIED : "The process is protected or belongs to another account"
*>
fn void? send_signal(uint pid, KillMode mode)
{
	void* process = win::sys_open_process(PROCESS_TERMINATE_ACCESS, 0, pid);
	if (process == null)
	{
		// ERROR_INVALID_PARAMETER is what OpenProcess reports for an id that names no process.
		fault failure = errors::raise_last("OpenProcess");
		if (error::last()
			.code == (int)win::ERROR_INVALID_PARAMETER) return error::raise(
				NOT_FOUND,
				error::Domain.WIN32,
				error::last()
				.code, "no process %d", pid)~;
		return failure~;
	}
	defer (void)win32::closeHandle(process);
	if (win32::terminateProcess(process, EXIT_CODE_KILLED) == 0) return errors::raise_last("TerminateProcess")~;
}