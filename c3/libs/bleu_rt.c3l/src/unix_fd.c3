<*
 Owned POSIX file descriptors.

 An `Fd` owns one descriptor and closes it exactly once. Pair every acquisition
 with a `defer` close. The platform constants used here (F_GETFL, F_DUPFD_CLOEXEC,
 O_NONBLOCK) live in `unix_linux.c3` and `unix_darwin.c3`, with their sources.
*>
module bleu::rt::unix @feat(POSIX);
import libc, bleu::rt, bleu::error;

<* The "no descriptor" value. *>
const CInt FD_NONE = -1;

<*
 An owned file descriptor. `value` is `FD_NONE` once closed or released.

 Beware: a zero-initialised `Fd` holds descriptor 0 (stdin), not "nothing".
 Create empty ones with `unix::no_fd()` and never rely on `{}`.
*>
struct Fd
{
	CInt value;
}

<* An `Fd` that owns nothing. Use this, not `{}`, for "not open yet". *>
fn Fd no_fd() @inline => { .value = FD_NONE };

<* True while the value holds an open descriptor. *>
fn bool Fd.is_open(self) @inline => self.value >= 0;

<* The descriptor number, still owned by this `Fd`. *>
fn CInt Fd.raw(self) @inline => self.value;

<*
 Close the descriptor. Closing an empty `Fd` does nothing.

 A close(2) that reports EINTR still released the descriptor on Linux, so it is
 not an error. Call as `defer (void)fd.close();` when the result cannot be acted on.

 @return? error::BACKEND_FAILURE, error::PERMISSION_DENIED : "close(2) reported an error"
*>
fn void? Fd.close(&self) @maydiscard
{
	if (!self.is_open()) return;
	CInt fd = self.value;
	self.value = FD_NONE;
	if (libc::close(fd) == 0) return;
	if (libc::errno() == EINTR) return;
	return errno_fault("close", libc::errno())~;
}

<*
 Give up ownership and return the raw descriptor. The caller must close it.
*>
fn CInt Fd.release(&self)
{
	CInt fd = self.value;
	self.value = FD_NONE;
	return fd;
}

<*
 Duplicate the descriptor with FD_CLOEXEC set atomically, so that no concurrently
 forked child can inherit it (F_DUPFD_CLOEXEC, fcntl(2)).

 @return? error::BACKEND_FAILURE : "fcntl(2) failed"
*>
fn Fd? Fd.dup_cloexec(self)
{
	CInt copy = rt::fcntl(self.value, F_DUPFD_CLOEXEC, 0);
	if (copy < 0) return errno_fault("fcntl(F_DUPFD_CLOEXEC)", libc::errno())~;
	return { .value = copy };
}

<*
 Switch O_NONBLOCK on or off.

 @return? error::BACKEND_FAILURE, error::PERMISSION_DENIED : "fcntl(2) failed"
*>
fn void? Fd.set_nonblocking(&self, bool non_blocking)
{
	CInt flags = rt::fcntl(self.value, F_GETFL, 0);
	if (flags < 0) return errno_fault("fcntl(F_GETFL)", libc::errno())~;
	CInt wanted = non_blocking ? flags | O_NONBLOCK_FLAG : flags & ~O_NONBLOCK_FLAG;
	if (wanted == flags) return;
	if (rt::fcntl(self.value, F_SETFL, wanted) < 0) return errno_fault("fcntl(F_SETFL)", libc::errno())~;
}