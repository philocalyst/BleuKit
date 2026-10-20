<*
 Linux wake-up: one eventfd(2) counter.

 `signal` adds 1 to the counter, `drain` reads it back to zero. The counter is
 the coalescing: two signals read back as one drain.

 Sources:
 - eventfd(2), https://man7.org/linux/man-pages/man2/eventfd.2.html
 - Linux uapi, include/uapi/linux/eventfd.h:
 EFD_SEMAPHORE (1 << 0), EFD_CLOEXEC O_CLOEXEC, EFD_NONBLOCK O_NONBLOCK
 (https://raw.githubusercontent.com/torvalds/linux/master/include/uapi/linux/eventfd.h)
 - libc 0.2.170 crate, src/unix/linux_like/linux/gnu/b64/x86_64/mod.rs:
 EFD_CLOEXEC = 0x80000, EFD_NONBLOCK = 0x800, O_CLOEXEC = 0x80000, O_NONBLOCK = 2048
 (https://static.crates.io/crates/libc/libc-0.2.170.crate)
*>
module bleu::rt::wakeup @feat(LINUX);
import libc, bleu::error;

// eventfd flags from the Linux uapi header (see the source above).
const CInt EFD_CLOEXEC  = 0x80000;
const CInt EFD_NONBLOCK = 0x800;

// The eventfd counter is a 64-bit unsigned integer (eventfd(2), "Description").
const sz EVENTFD_COUNTER_SIZE = (sz)ulong::size;

extern fn CInt eventfd(CUInt initval, CInt flags);

fn void? native_open(Wakeup* self) @private
{
	CInt fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
	if (fd < 0) return error::raise(error::BACKEND_FAILURE, error::Domain.ERRNO, libc::errno(), "eventfd failed")~;
	self.read_end = fd;
	self.write_end = fd;
}

fn void native_close(Wakeup* self) @private
{
	// One descriptor serves both ends; close it exactly once.
	(void)libc::close(self.read_end);
}

fn void? native_signal(Wakeup* self) @private
{
	ulong one  = 1;
	sz written = libc::write(self.write_end, &one, (usz)EVENTFD_COUNTER_SIZE);
	// EAGAIN means the counter is at its maximum: a signal is already pending.
	if (written == EVENTFD_COUNTER_SIZE || libc::errno() == EAGAIN) return;
	return error::raise(error::BACKEND_FAILURE, error::Domain.ERRNO, libc::errno(), "eventfd signal failed")~;
}

fn void? native_drain(Wakeup* self) @private
{
	ulong counter;
	sz read = libc::read(self.read_end, &counter, (usz)EVENTFD_COUNTER_SIZE);
	// EAGAIN means nothing was pending, which is what a drain wants.
	if (read == EVENTFD_COUNTER_SIZE || libc::errno() == EAGAIN) return;
	return error::raise(error::BACKEND_FAILURE, error::Domain.ERRNO, libc::errno(), "eventfd drain failed")~;
}