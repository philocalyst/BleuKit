<*
 The Linux i2c-dev transport: DDC/CI over `/dev/i2c-N`, behind
 `bleu::ddc::transport::Transport`.

 Opening a bus: `open(O_RDWR | O_CLOEXEC)`, then `ioctl(I2C_SLAVE, 0x37)` to address the DDC/CI slave.
 The exclusive `flock(LOCK_EX | LOCK_NB)` is taken per DDC transaction (`lock_exclusive` and
 `unlock_exclusive`, called by the display around each request), so other tools can use the
 bus between requests; a lock that another process holds is retried briefly, then BUSY.
 Every transfer is plain `write` and `poll`+`read`.

 Sources: Documentation/i2c/dev-interface.rst (`I2C_SLAVE` 0x0703, the
 `/dev/i2c-N` node, and that the `i2c-dev` module must be loaded); the
 `flock(2)` and `open(2)` man pages for the flag values (LOCK_EX 2, LOCK_NB 4,
 O_CLOEXEC 0x80000 on asm-generic/fcntl.h); `poll(2)` for POLLIN 0x001.
*>
module bleu::brightness::i2cdev @feat(LINUX);
import std::thread, std::time, bleu::ddc::packet, bleu::ddc::transport, bleu::error, libc;

const int O_RDWR      = 2;
const int O_CLOEXEC   = 0x80000;
const int I2C_SLAVE   = 0x0703;
const int LOCK_EX     = 2;
const int LOCK_NB     = 4;
const int LOCK_UN     = 8;
const short POLLIN    = 0x001;
const int EPERM       = 1;
const int ENOENT      = 2;
const int EINTR       = 4;
const int EACCES      = 13;
const int EWOULDBLOCK = 11;

<* How many times `flock` is tried before the bus counts as busy, and the pause between tries. *>
const int LOCK_TRIES      = 3;
const Duration LOCK_RETRY = (Duration)10_000;

<* The largest `poll` timeout in milliseconds: the C `int` the call takes. *>
const long MAX_POLL_MS = 0x7FFF_FFFF;

extern fn int open(char* path, int flags, ...);
extern fn int close(int fd);
extern fn int ioctl(int fd, ulong request, ...);
extern fn int flock(int fd, int operation);
extern fn int poll(Pollfd* fds, usz count, int timeout_ms);
extern fn sz read(int fd, void* buffer, usz count);
extern fn sz write(int fd, void* buffer, usz count);

struct Pollfd
{
	int fd;
	short events;
	short revents;
}

<*
 An open DDC/CI bus. Owned by one DDC display; close it when the display goes.
 A bus is not thread-safe: it is used on the worker thread.
*>
struct I2cBus (Transport)
{
	int fd;
}

<*
 Open `/dev/i2c-N` (or `path`) and address the DDC/CI slave on it.

 @return? error::PERMISSION_DENIED : "The bus exists but this process may not open it (group `i2c`)"
 @return? NOT_FOUND : "There is no such bus; the i2c-dev module may not be loaded"
 @return? error::BACKEND_FAILURE : "The bus could not be opened or addressed"
*>
fn I2cBus? open_device(String path)
{
	@pool()
	{
		int fd = open(path.zstr_tcopy(), O_RDWR | O_CLOEXEC);
		if (fd < 0) return errno_fault(path, "open")~;
		I2cBus bus = { .fd = fd };
		if (ioctl(fd, I2C_SLAVE, (ulong)packet::CHIP_ADDRESS) < 0)
		{
			fault failure = errno_fault(path, "ioctl(I2C_SLAVE)");
			(void)close(fd);
			return failure~;
		}
		return bus;
	};
}

<*
 Take the exclusive lock on the bus for one transaction, retrying briefly.

 @return? error::BUSY : "Another process holds the bus lock"
*>
fn void? I2cBus.lock_exclusive(&self)
{
	lock(self.fd)!;
}

<* Release the lock taken by `lock_exclusive`. Safe on a closed bus. *>
fn void I2cBus.unlock_exclusive(&self)
{
	if (self.fd >= 0) (void)flock(self.fd, LOCK_UN);
}

// Take the exclusive lock, retrying briefly.
fn void? lock(int fd) @private
{
	for (int attempt = 0; attempt < LOCK_TRIES; attempt++)
	{
		if (flock(fd, LOCK_EX | LOCK_NB) == 0) return;
		if (libc::errno() != EWOULDBLOCK) return errno_fault("bus", "flock")~;
		thread::sleep(LOCK_RETRY);
	}
	return error::raise(error::BUSY, error::Domain.ERRNO, EWOULDBLOCK, "bus is locked by another process")~;
}

<* Close the descriptor. Safe to call twice. *>
fn void I2cBus.close(&self)
{
	if (self.fd < 0) return;
	(void)close(self.fd);
	self.fd = -1;
}

fn void? I2cBus.write(&self, char[] bytes) @dynamic
{
	usz done = 0;
	while (done < bytes.len)
	{
		sz n = write(self.fd, &bytes[done], bytes.len - done);
		if (n < 0)
		{
			if (libc::errno() == EINTR) continue;
			return errno_fault("i2c", "write")~;
		}
		// A write that accepts nothing would loop forever: the bus is not taking the bytes.
		if (n == 0) return error::raise(
			error::BACKEND_FAILURE,
			error::Domain.INTERNAL,
			0,
			"i2c write made no progress"
		)~;
		done += (usz)n;
	}
}

fn usz? I2cBus.read(&self, char[] buffer, Duration timeout) @dynamic
{
	Pollfd waiting    = { .fd = self.fd, .events = POLLIN, .revents = 0 };
	long milliseconds = (long)timeout / 1000;
	int ready         = poll(&waiting, 1, (int)(milliseconds > MAX_POLL_MS ? MAX_POLL_MS : milliseconds));
	if (ready < 0)
	{
		if (libc::errno() == EINTR) return 0;
		return errno_fault("i2c", "poll")~;
	}
	if (ready == 0) return 0;
	sz n = read(self.fd, buffer.ptr, buffer.len);
	if (n < 0)
	{
		if (libc::errno() == EINTR) return 0;
		return errno_fault("i2c", "read")~;
	}
	return (usz)n;
}

// The DDC/CI transfers need no extra wait between a write and its read.
fn Duration I2cBus.min_interval_after_write(&self) @dynamic => time::DURATION_ZERO;

<* The fault for a failed system call on `what`, with errno recorded. *>
fn fault errno_fault(String what, String call) @private
{
	int code      = (int)libc::errno();
	fault failure = code == EPERM || code == EACCES ? error::PERMISSION_DENIED
		: (code == ENOENT ? NOT_FOUND : error::BACKEND_FAILURE);
	return error::raise(failure, error::Domain.ERRNO, code, "%s: %s failed", what, call);
}