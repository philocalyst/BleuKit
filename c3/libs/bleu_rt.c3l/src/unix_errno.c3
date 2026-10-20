<*
 errno values mapped onto the Bleu excuse vocabulary, in one place, so that every
 backend classifies the same failure the same way.
*>
module bleu::rt::unix @feat(POSIX);
import libc, bleu::error;

<*
 Classify an errno value. Values not listed are `BACKEND_FAILURE`: the native
 code is still recorded in `error::last()`, so nothing is lost.

 The names are the platform's own constants (`libc` provides them per OS), so
 the same switch is correct on Linux and macOS.

 @param err : "An errno value, as read from `libc::errno()` right after the failing call"
*>
fn fault errno_to_fault(CInt err)
{
	switch ((Errno)err)
	{
		case ENOENT:                       return NOT_FOUND;
		case EACCES:
		case EPERM:                        return error::PERMISSION_DENIED;
		case ECONNREFUSED:
		case ECONNRESET:
		case EPIPE:                        return error::DISCONNECTED;
		case ETIMEDOUT:                    return TIMEOUT;
		case EAGAIN:                       return error::BUSY;
		case EINVAL:                       return error::INVALID_ARGUMENT;
		case ENOMEM:                       return error::NO_MEMORY;
		default:                           return error::BACKEND_FAILURE;
	}
}

<*
 Record a failed system call in `error::last()` and return the matching fault,
 ready to be returned with `~`:

     return errno_fault("connect", libc::errno())~;

 @param what : "The system call that failed, for the message"
 @param err : "The errno value captured right after the call"
*>
fn fault errno_fault(String what, CInt err)
{
	return error::raise(errno_to_fault(err), error::Domain.ERRNO, err, "%s failed: %s", what, (String)libc::strerror(err));
}
