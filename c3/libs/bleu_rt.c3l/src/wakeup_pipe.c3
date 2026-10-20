<*
 Non-Linux POSIX wake-up (macOS, BSD): a pipe whose two ends are non-blocking
 and close-on-exec. `signal` writes one byte; `drain` reads every pending byte.

 A full pipe makes `signal` fail with EAGAIN, which means a wake-up is already
 pending, so it is success. `pipe2(2)` with O_CLOEXEC is not available on
 macOS, so the flags are set with fcntl(2) right after creation.

 Sources:
   - pipe(2), https://man7.org/linux/man-pages/man2/pipe.2.html (POSIX.1-2008 pipe)
   - XNU bsd/sys/fcntl.h (https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/sys/fcntl.h):
     F_SETFD 2, F_SETFL 4, F_DUPFD_CLOEXEC 67, FD_CLOEXEC 1, O_NONBLOCK 0x4
   - libc 0.2.170 crate, src/unix/bsd/apple/mod.rs: F_DUPFD_CLOEXEC = 67
*>
module bleu::rt::wakeup @feat(POSIX & !LINUX);
import libc, std::os::posix, bleu::error, bleu::rt;

// fcntl(2) commands and flags, values as in XNU bsd/sys/fcntl.h (see above).
const CInt F_SETFD = 2;
const CInt FD_CLOEXEC = 1;
const CInt F_SETFL = 4;
const CInt O_NONBLOCK_FLAG = 0x4;

fn void? native_open(Wakeup* self) @private
{
	CInt[2] ends;
	if (posix::pipe(&ends) != 0)
	{
		return error::raise(error::BACKEND_FAILURE, error::Domain.ERRNO, libc::errno(), "pipe failed")~;
	}
	if (catch err = set_flags(ends[0]))
	{
		(void)libc::close(ends[0]);
		(void)libc::close(ends[1]);
		return err~;
	}
	if (catch err = set_flags(ends[1]))
	{
		(void)libc::close(ends[0]);
		(void)libc::close(ends[1]);
		return err~;
	}
	self.read_end = ends[0];
	self.write_end = ends[1];
}

// Make one end non-blocking and close-on-exec.
fn void? set_flags(CInt fd) @private
{
	if (rt::fcntl(fd, F_SETFD, FD_CLOEXEC) != 0 || rt::fcntl(fd, F_SETFL, O_NONBLOCK_FLAG) != 0)
	{
		return error::raise(error::BACKEND_FAILURE, error::Domain.ERRNO, libc::errno(), "fcntl failed on wake-up pipe")~;
	}
}

fn void native_close(Wakeup* self) @private
{
	(void)libc::close(self.read_end);
	(void)libc::close(self.write_end);
}

fn void? native_signal(Wakeup* self) @private
{
	char byte = 1;
	sz written = libc::write(self.write_end, &byte, 1);
	if (written == 1 || libc::errno() == EAGAIN) return;
	return error::raise(error::BACKEND_FAILURE, error::Domain.ERRNO, libc::errno(), "wake-up pipe signal failed")~;
}

fn void? native_drain(Wakeup* self) @private
{
	char[64] sink;
	while (true)
	{
		sz read = libc::read(self.read_end, &sink, (usz)sink.len);
		if (read > 0) continue;
		if (read == 0) return;
		if (libc::errno() == EAGAIN) return;
		if (libc::errno() == EINTR) continue;
		return error::raise(error::BACKEND_FAILURE, error::Domain.ERRNO, libc::errno(), "wake-up pipe drain failed")~;
	}
}
