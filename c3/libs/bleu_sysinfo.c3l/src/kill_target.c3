<*
 Which process ids a kill may name. The rule runs before anything is signalled,
 both when the request is made (so the caller gets the refusal at once) and on
 the worker just before the system call (so no path reaches the system without it).

 A `uint` id is never negative, but on POSIX it becomes a `pid_t` (a signed 32-bit
 int, POSIX.1 sys/types.h), where a value at or above 2^31 is negative and
 `kill` would then signal a process group or every process (-1). Pid 0 means the
 caller's own process group.
*>
module bleu::sysinfo;
import bleu::error;

<*
 Largest id a kill may name: INT_MAX, the top of `pid_t`. Linux pids are at most
 4 194 304 (pid_max) and macOS ids are below 100 000, so every real id fits.
*>
const uint MAX_TARGET_PID = 0x7FFF_FFFF;

<* The system's init process. Ending it takes the session down, so only FORCE may name it. *>
const uint INIT_PID = 1;

<*
 Refuse a kill that would end the wrong thing. Pure: it signals nothing.

 @param pid : "The process id the caller named"
 @param mode : "How the caller wants the process ended"
 @param own_pid : "The id of this process, which a kill never ends"
 @return? error::INVALID_ARGUMENT : "The id is 0, is above MAX_TARGET_PID, names this process, or is init without FORCE"
*>
fn void? check_kill_target(uint pid, KillMode mode, uint own_pid)
{
	if (pid == 0 || pid > MAX_TARGET_PID)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "%d is not a process id", pid)~;
	}
	if (pid == own_pid)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "refusing to end this process")~;
	}
	if (pid == INIT_PID && mode != FORCE)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "process 1 is init: only FORCE may end it")~;
	}
}
