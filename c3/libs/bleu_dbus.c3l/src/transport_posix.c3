<*
 The only place that talks to the operating system for D-Bus: Unix domain
 sockets, non-blocking I/O, descriptor passing and readiness waits.

 The C declarations are written here rather than taken from `std` because
 `std` does not expose `sendmsg`, `recvmsg` or `msghdr`, and because the layouts
 of `msghdr`, `cmsghdr` and `sockaddr_un` differ between Linux and Apple.
 Everything above this module is platform-neutral; on Windows the file
 `transport_win.c3` provides the same names and raises UNSUPPORTED.

 Sources for every constant and layout (each checked against a second source):
 * Linux: `struct msghdr` with `size_t msg_iovlen`, `size_t msg_controllen`;
   `struct cmsghdr { size_t cmsg_len; int cmsg_level; int cmsg_type; }` aligned
   to `size_t`; `sockaddr_un { sa_family_t; char sun_path[108]; }`; `SOL_SOCKET 1`,
   `O_NONBLOCK 0x800`, `MSG_CTRUNC 0x8`, `MSG_NOSIGNAL 0x4000`.
   Sources: the Linux man pages unix(7), cmsg(3), and the libc crate 0.2.191
   src/unix/linux_like/mod.rs (MSG_CTRUNC, MSG_NOSIGNAL, CMSG_ALIGN) and
   src/unix/linux_like/linux/gnu/mod.rs (msghdr).
 * Apple (macOS, BSD): `msghdr` with `socklen_t` lengths and `int msg_iovlen`,
   `cmsghdr` of `socklen_t` length, `CMSG_ALIGN` 4; `sockaddr_un { u8 sun_len;
   u8 sun_family; char sun_path[104]; }`; `SOL_SOCKET 0xffff`, `O_NONBLOCK 0x4`,
   `MSG_CTRUNC 0x20`, `MSG_NOSIGNAL 0x80000`, `SO_NOSIGPIPE 0x1022`.
   Sources: the libc crate 0.2.191 src/unix/bsd/mod.rs (msghdr, cmsghdr),
   src/unix/bsd/apple/mod.rs (CMSG_* macros with __DARWIN_ALIGN32, constants).
 * `SCM_RIGHTS 1`, `POLL*` values and `F_SETFD 2`, `FD_CLOEXEC 1` agree on both
   (libc crate src/unix/bsd/mod.rs and src/unix/linux_like/mod.rs).
*>
module bleu::dbus::transport @feat(POSIX);
import bleu::error, std::time, std::collections::list, libc;

<* Address family of Unix domain sockets (AF_UNIX on both platforms). *>
const int AF_UNIX = 1;

<* Stream socket type. *>
const int SOCK_STREAM = 1;

<* `fcntl` command setting the descriptor flags, and the flag that closes on exec. *>
const int F_SETFD = 2;
const int FD_CLOEXEC = 1;

<* `fcntl` command setting the status flags. *>
const int F_SETFL = 4;

<* Non-blocking I/O status flag. *>
const int O_NONBLOCK = env::LINUX ? 0x800 : 0x4;

<* Socket level and the descriptor-passing control message type. *>
const int SOL_SOCKET = env::LINUX ? 1 : 0xffff;
const int SCM_RIGHTS = 1;

<* `recvmsg` flag: the control data did not fit and was truncated. *>
const int MSG_CTRUNC = env::LINUX ? 0x8 : 0x20;

<* `sendmsg` flag: do not raise SIGPIPE when the peer has gone. *>
const int MSG_NOSIGNAL = env::LINUX ? 0x4000 : 0x80000;

<* Apple: socket option that suppresses SIGPIPE on this socket. *>
const int SO_NOSIGPIPE = 0x1022;

<* `poll` event bits, the same on both platforms. *>
const short POLLIN = 0x1;
const short POLLOUT = 0x4;
const short POLLERR = 0x8;
const short POLLHUP = 0x10;
const short POLLNVAL = 0x20;

<*
 Most descriptors one message may carry. The kernel limit SCM_MAX_FD is 253
 on Linux; the same bound is used everywhere.
*>
const MAX_DESCRIPTORS = 253;

<* Size of one descriptor in the control data: a C `int`, 32 bits on every target. *>
const DESCRIPTOR_BYTES = 4;

<* Control buffer big enough for `MAX_DESCRIPTORS` descriptors on either platform. *>
const CONTROL_CAPACITY = 1100;

<* Size of the `sun_path` field: 108 on Linux, 104 on Apple. *>
const SUN_PATH_CAPACITY = env::LINUX ? 108 : 104;

<* Room for any `sockaddr_un` (its family, then the path). *>
const SOCKADDR_CAPACITY = 110;

// `struct msghdr`. Linux and Apple place these fields at the same offsets (56
// bytes); Apple's `int` and `socklen_t` lengths sit in the low half of the
// 8-byte `usz` fields used here, with zero padding above them.
struct Msghdr
{
	void* name;
	uint namelen;
	Iovec* iov;
	usz iovlen;
	void* control;
	usz controllen;
	int flags;
}

// `struct cmsghdr` on Linux: `size_t` length, then level and type (16 bytes).
struct LinuxCmsghdr
{
	usz len;
	int level;
	int type;
}

// `struct cmsghdr` on Apple: `socklen_t` length, then level and type (12 bytes).
struct AppleCmsghdr
{
	uint len;
	int level;
	int type;
}

// `struct sockaddr_un` on Linux: `sa_family_t` (u16) then the path.
struct LinuxSockaddr
{
	ushort family;
	char[SUN_PATH_CAPACITY] path;
}

// `struct sockaddr_un` on Apple: `u8 sun_len`, `u8 sun_family`, then the path.
struct AppleSockaddr
{
	char len;
	char family;
	char[SUN_PATH_CAPACITY] path;
}

struct Iovec
{
	void* base;
	usz len;
}

struct Pollfd
{
	int fd;
	short events;
	short revents;
}

extern fn int socket(int domain, int type, int protocol);
extern fn int connect(int fd, void* address, uint address_len);
extern fn int close(int fd);
extern fn int fcntl(int fd, int command, ...);
extern fn int setsockopt(int fd, int level, int name, void* value, uint length);
extern fn sz sendmsg(int fd, Msghdr* message, int flags);
extern fn sz recvmsg(int fd, Msghdr* message, int flags);
// `nfds_t` is unsigned long on Linux and unsigned int on Apple. Declaring it as
// usz is ABI-safe for both: a 32-bit callee reads only the low half of the register.
extern fn int poll(Pollfd* fds, usz count, int timeout_ms);
extern fn uint getuid();

<*
 Open a connected Unix domain stream socket to `path`, with close-on-exec set
 and non-blocking mode on. Abstract names (Linux only) are given without the
 leading NUL.

 @param path : "Filesystem path, or abstract name when `abstract` is set"
 @return? error::UNSUPPORTED : "Abstract sockets are only available on Linux"
 @return? error::INVALID_ARGUMENT : "The path is empty or longer than the address can hold"
 @return? error::UNAVAILABLE : "No server is listening at the address (ENOENT, ECONNREFUSED)"
 @return? error::BACKEND_FAILURE : "Any other failure of the socket calls"
*>
fn int? connect_unix(String path, bool abstract)
{
	if (abstract && !env::LINUX) return error::UNSUPPORTED~;
	if (path.len == 0 || path.len > SUN_PATH_CAPACITY - 1) return error::INVALID_ARGUMENT~;
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) return failure("socket")~;
	char[SOCKADDR_CAPACITY] addr;
	uint address_len = fill_address(&addr, path, abstract);
	if (connect(fd, &addr, address_len) < 0)
	{
		close_fd(fd);
		return failure("connect")~;
	}
	if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 || fcntl(fd, F_SETFL, O_NONBLOCK) < 0)
	{
		close_fd(fd);
		return failure("fcntl")~;
	}
	$if env::DARWIN:
	int one = 1;
	setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, DESCRIPTOR_BYTES);
	$endif
	return fd;
}

// Writes the sockaddr_un for `path` and returns the length the kernel should use.
fn uint fill_address(char[] addr, String path, bool abstract) @private
{
	usz offset = 0;
	$if env::LINUX:
	addr[0] = (char)AF_UNIX;
	addr[1] = 0;
	$else
	addr[0] = (char)(2 + path.len + (abstract ? 0 : 1));
	addr[1] = (char)AF_UNIX;
	$endif
	usz path_at = 2;
	if (abstract)
	{
		addr[path_at] = 0;
		path_at++;
	}
	for (usz i = 0; i < path.len; i++) addr[path_at + i] = path[i];
	usz terminator = abstract ? 0 : 1;
	return (uint)(path_at + path.len + terminator);
}

<* Close a descriptor. Errors on close are ignored: there is nothing to do about them. *>
fn void close_fd(int fd)
{
	// close(2) failing on a valid descriptor cannot be recovered from here.
	(void)close(fd);
}

<*
 Send as much of `bytes[offset:]` as the socket takes right now, without
 blocking. `descriptors` travel with the first byte, so they are only sent when
 `offset` is 0.

 @return "Number of bytes written; 0 when the socket would block"
 @return? error::DISCONNECTED : "The peer has closed the connection"
 @return? error::INVALID_ARGUMENT : "More descriptors than one message may carry"
*>
fn usz? send_some(int fd, String bytes, usz offset, int[] descriptors)
{
	if (descriptors.len > MAX_DESCRIPTORS) return error::INVALID_ARGUMENT~;
	char[CONTROL_CAPACITY] control;
	Iovec vec = { .base = &bytes[offset], .len = bytes.len - offset };
	Msghdr msg = { .iov = &vec, .iovlen = 1 };
	if (offset == 0 && descriptors.len > 0)
	{
		usz data_len = descriptors.len * DESCRIPTOR_BYTES;
		msg.control = &control;
		msg.controllen = control_space(data_len);
		write_cmsg_header(&control, data_len);
		int* out = (int*)((char*)&control + control_header_size());
		for (usz i = 0; i < descriptors.len; i++) out[i] = descriptors[i];
	}
	sz sent = sendmsg(fd, &msg, MSG_NOSIGNAL);
	if (sent >= 0) return (usz)sent;
	if (libc::errno() == EAGAIN || libc::errno() == EINTR) return 0;
	if (libc::errno() == EPIPE || libc::errno() == ECONNRESET) return error::DISCONNECTED~;
	return failure("sendmsg")~;
}

<*
 Receive what the socket has, without blocking, into `buffer[offset:]`. Any
 descriptors that came with the data are appended to `descriptors`; the caller
 owns them from then on.

 @return "Number of bytes read; 0 when nothing is available right now"
 @return? error::DISCONNECTED : "The peer closed the connection (end of stream)"
 @return? error::PROTOCOL : "Descriptors were truncated, so the stream cannot be trusted"
*>
fn usz? recv_some(int fd, char[] buffer, usz offset, List{int}* descriptors)
{
	char[CONTROL_CAPACITY] control;
	Iovec vec = { .base = &buffer[offset], .len = buffer.len - offset };
	Msghdr msg = { .iov = &vec, .iovlen = 1, .control = &control, .controllen = CONTROL_CAPACITY };
	sz got = recvmsg(fd, &msg, 0);
	if (got < 0)
	{
		if (libc::errno() == EAGAIN || libc::errno() == EINTR) return 0;
		if (libc::errno() == ECONNRESET) return error::DISCONNECTED~;
		return failure("recvmsg")~;
	}
	if (msg.flags & MSG_CTRUNC) return error::PROTOCOL~;
	take_descriptors(&control, (usz)msg.controllen, descriptors);
	if (got == 0) return error::DISCONNECTED~;
	return (usz)got;
}

// Appends every SCM_RIGHTS descriptor found in the control buffer. Each one is
// marked close-on-exec, since the kernel does not do it on every platform.
fn void take_descriptors(char* control, usz length, List{int}* descriptors) @private
{
	usz offset = 0;
	while (offset + control_header_size() <= length)
	{
		CmsgHeader header = read_cmsg_header(control + offset);
		usz len = header.len;
		if (len < control_header_size() || offset + len > length) return;
		if (header.level == SOL_SOCKET && header.type == SCM_RIGHTS)
		{
			usz count = (len - control_header_size()) / DESCRIPTOR_BYTES;
			int* fds = (int*)(control + offset + control_header_size());
			for (usz i = 0; i < count; i++)
			{
				(void)fcntl(fds[i], F_SETFD, FD_CLOEXEC);
				descriptors.push(fds[i]);
			}
		}
		offset += control_space(len - control_header_size());
	}
}

// A control message header, read the same way on both platforms.
struct CmsgHeader
{
	usz len;
	int level;
	int type;
}

// Writes the header of one SCM_RIGHTS control message carrying `data_len` bytes.
fn void write_cmsg_header(char* control, usz data_len) @private
{
	usz len = control_len(data_len);
	$if env::LINUX:
	LinuxCmsghdr* header = (LinuxCmsghdr*)control;
	header.len = len;
	header.level = SOL_SOCKET;
	header.type = SCM_RIGHTS;
	$else
	AppleCmsghdr* header = (AppleCmsghdr*)control;
	header.len = (uint)len;
	header.level = SOL_SOCKET;
	header.type = SCM_RIGHTS;
	$endif
}

// Reads the header of the control message at `control`.
fn CmsgHeader read_cmsg_header(char* control) @private
{
	$if env::LINUX:
	LinuxCmsghdr* header = (LinuxCmsghdr*)control;
	return { .len = header.len, .level = header.level, .type = header.type };
	$else
	AppleCmsghdr* header = (AppleCmsghdr*)control;
	return { .len = header.len, .level = header.level, .type = header.type };
	$endif
}

// sizeof(cmsghdr) on each platform.
fn usz control_header_size() @inline => env::LINUX ? 16 : 12;

// CMSG_ALIGN: 8 on Linux, 4 on Apple.
fn usz control_align(usz n) @inline => env::LINUX ? (n + 7) & ~(usz)7 : (n + 3) & ~(usz)3;

// CMSG_LEN: the header plus `data`, unpadded.
fn usz control_len(usz data) @inline => control_header_size() + data;

// CMSG_SPACE: the header plus `data`, padded.
fn usz control_space(usz data) @inline => control_header_size() + control_align(data);

<*
 Wait until `fd` is readable (or writable when `for_write`), or `timeout` passes.
 Errors and hang-ups count as ready, so the next read or write reports them.

 @return "true when the descriptor is ready, false on timeout"
*>
fn bool wait(int fd, bool for_write, Duration timeout)
{
	Pollfd pfd = { .fd = fd, .events = for_write ? POLLOUT : POLLIN };
	int ms = timeout == time::FOREVER ? -1 : (int)min((long)(timeout / 1000) + 1, 0x7fffffff);
	int result = poll(&pfd, 1, ms);
	if (result < 0) return libc::errno() == EINTR ? false : true;
	return result > 0;
}

<* The real user id of this process, which EXTERNAL authentication sends to the bus. *>
fn uint? current_uid() @inline => getuid();

// BACKEND_FAILURE carrying the current errno, for the named call.
fn fault failure(String what) @private
{
	return error::raise(error::BACKEND_FAILURE, error::Domain.ERRNO, (int)libc::errno(), "%s failed", what);
}
