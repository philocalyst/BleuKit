<*
 POSIX poller: poll(2) over the wake-up and every registered source.

 Sources:
 - poll(2), https://man7.org/linux/man-pages/man2/poll.2.html (POSIX.1-2008 poll)
 - struct pollfd { int fd; short events; short revents; } and the POLL* values:
 XNU bsd/sys/poll.h (https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/sys/poll.h)
 POLLIN 0x0001, POLLPRI 0x0002, POLLOUT 0x0004, POLLERR 0x0008, POLLHUP 0x0010, POLLNVAL 0x0020
 and the same values in the libc 0.2.170 crate, src/unix/linux_like/mod.rs:1342-1347
 - nfds_t: `unsigned long` on glibc (libc crate, src/unix/linux_like/linux/mod.rs:16),
 `unsigned int` on XNU (xnu bsd/sys/poll.h line 102; libc crate src/unix/bsd/mod.rs:9)
 - EINTR is retried with the remaining time, as poll(2) advises when a signal
 handler ran ("EINTR ... the call may be retried").
*>
module bleu::rt::poller @feat(POSIX);
import libc, std::time, bleu::rt, bleu::deadline, bleu::error, bleu::rt::unix;

<* `struct pollfd` as laid out by poll(2). *>
struct NativeWait
{
	CInt fd;
	CShort events;
	CShort revents;
}

// nfds_t width differs between glibc and Darwin (see the sources above).
alias NfdsT @feat(LINUX) = CULong;
alias NfdsT @feat(!LINUX) = CUInt;

const CShort POLLIN   = 0x0001;
const CShort POLLPRI  = 0x0002;
const CShort POLLOUT  = 0x0004;
const CShort POLLERR  = 0x0008;
const CShort POLLHUP  = 0x0010;
const CShort POLLNVAL = 0x0020;

// poll(2) with the timeout in milliseconds, -1 meaning forever.
extern fn CInt sys_poll(NativeWait* fds, NfdsT count, CInt timeout_ms) @cname("poll");

fn void? native_check_limits(usz capacity, bool window_messages) @private
{
	if (window_messages)
	{
		return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "window messages exist only on Windows")~;
	}
}

fn usz? native_wait(Poller* self, Deadline deadline) @private
{
	self.entries[0] = { .fd = self.wakeup.read_end, .events = POLLIN, .revents = 0 };
	for (usz i = 0; i < self.count; i++)
	{
		Source source = self.sources[i];
		CShort events = 0;
		if (source.interest.readable) events |= POLLIN;
		if (source.interest.writable) events |= POLLOUT;
		self.entries[i + 1] = { .fd = source.handle, .events = events, .revents = 0 };
	}
	while (true)
	{
		CInt rc = sys_poll(self.entries.ptr, (NfdsT)(self.count + 1), poll_timeout_ms(deadline));
		if (rc < 0)
		{
			if (libc::errno() == EINTR) continue;
			return unix::errno_fault("poll", libc::errno())~;
		}
		if (rc == 0)
		{
			if (deadline.expired()) return TIMEOUT~;
			continue;
		}
		return collect_ready(self);
	}
}

// Remaining time in milliseconds for poll(2). Infinite waits map to -1.
fn CInt poll_timeout_ms(Deadline deadline) @private
{
	Duration left = deadline.remaining();
	if (left == time::FOREVER) return -1;
	return (CInt)min(duration_ceil_ms(left), (long)CInt::max);
}

// Translate the revents of every entry into `Ready` values, wake-up first.
fn usz collect_ready(Poller* self) @private
{
	usz n = 0;
	for (usz i = 0; i <= self.count; i++)
	{
		CShort seen = self.entries[i].revents;
		if (!seen) continue;
		Interest events;
		events.readable = (seen & (POLLIN | POLLPRI)) != 0;
		events.writable = (seen & POLLOUT) != 0;
		events.hangup = (seen & POLLHUP) != 0;
		events.failed = (seen & (POLLERR | POLLNVAL)) != 0;
		usz tag = i == 0 ? WAKEUP_TAG : self.sources[i - 1].tag;
		self.ready[n++] = { .tag = tag, .events = events };
	}
	return n;
}