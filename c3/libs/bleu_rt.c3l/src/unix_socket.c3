<*
 AF_UNIX stream and seqpacket sockets, with SCM_RIGHTS file-descriptor passing.

 Layouts and constants that differ between Linux and macOS (struct msghdr,
 struct cmsghdr and its alignment, struct sockaddr_un, peer credentials) live in
 `unix_linux.c3` and `unix_darwin.c3`; everything here is the same on both.

 Sources common to both systems:
 - socket(2), sendmsg(2), recvmsg(2), unix(4):
 https://man7.org/linux/man-pages/man7/unix.7.html and the XNU sources below
 - AF_UNIX 1: include/linux/socket.h line 205
 (https://raw.githubusercontent.com/torvalds/linux/master/include/linux/socket.h)
 and XNU bsd/sys/socket.h line 387 (https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/sys/socket.h)
 - SOCK_STREAM 1, SOCK_SEQPACKET 5: include/linux/net.h lines 108 and 112
 (https://raw.githubusercontent.com/torvalds/linux/master/include/linux/net.h)
 and XNU bsd/sys/socket.h lines 113 and 119
 - struct iovec { void *base; size_t len; }: include/uapi/linux/uio.h and XNU bsd/sys/uio.h
 - SCM_RIGHTS 0x01: XNU bsd/sys/socket.h line 726 and Linux include/linux/socket.h line 192
*>
module bleu::rt::unix @feat(POSIX);
import libc, bleu::rt, bleu::error;

<* Stream or sequenced-packet semantics. *>
enum SocketKind : char
{
	STREAM,
	SEQPACKET,
}

// Socket domain and types (sources above).
const CInt AF_UNIX_FAMILY      = 1;
const CInt SOCK_STREAM_TYPE    = 1;
const CInt SOCK_SEQPACKET_TYPE = 5;


<*
 socklen_t: an unsigned 32-bit length on both Linux and Darwin (socket(2) man pages, XNU bsd/sys/_types/_socklen_t.h).
*>
alias SockLen = CUInt;

// Offset of sun_path in struct sockaddr_un on both platforms (a 2-byte family
// field or sun_len+sun_family), see the platform files.
const usz SUN_PATH_OFFSET = 2;

// Round a control-message length up to the platform's cmsg alignment.
fn usz cmsg_align(usz length) @inline => (length + CMSG_ALIGN_MASK) & ~CMSG_ALIGN_MASK;

// The C library entry points used here; `sys_` names keep them apart from the
// wrappers below.
extern fn CInt sys_socket(CInt domain, CInt type, CInt protocol) @cname("socket");
extern fn CInt sys_socketpair(CInt domain, CInt type, CInt protocol, CInt* pair) @cname("socketpair");
extern fn CInt sys_bind(CInt fd, SockAddrUn* addr, SockLen len) @cname("bind");
extern fn CInt sys_listen(CInt fd, CInt backlog) @cname("listen");
extern fn CInt sys_connect(CInt fd, SockAddrUn* addr, SockLen len) @cname("connect");
extern fn CInt sys_getsockopt(CInt fd, CInt level, CInt name, void* value, SockLen* len) @cname("getsockopt");
extern fn sz sys_sendmsg(CInt fd, MsgHdr* msg, CInt flags) @cname("sendmsg");
extern fn sz sys_recvmsg(CInt fd, MsgHdr* msg, CInt flags) @cname("recvmsg");


<*
 Credentials of the process at the other end of a connected socket. `pid` is
 the process id, or -1 when the platform cannot tell.
*>
struct PeerCredentials
{
	int pid;
	uint uid;
	uint gid;
}

<*
 A connected or listening AF_UNIX socket. Owns its descriptor.
*>
struct UnixSocket
{
	Fd fd;
	SocketKind kind;
}

<* The two ends of a socket pair. *>
struct SocketPair
{
	UnixSocket first;
	UnixSocket second;
}


<*
 The socket(2) type value of a kind.
*>
fn CInt SocketKind.native_type(self)
{
	switch (self)
	{
		case STREAM: return SOCK_STREAM_TYPE;
		case SEQPACKET: return SOCK_SEQPACKET_TYPE;
	}
}

<*
 Connect to the listening socket at `path`. Linux also accepts abstract names:
 a leading '@' or a leading NUL byte. Elsewhere those are UNSUPPORTED.

 @param path : "Filesystem path or abstract name"
 @return? error::UNSUPPORTED : "Abstract name on a platform without them"
 @return? error::INVALID_ARGUMENT : "Empty or too long path"
 @return? error::PERMISSION_DENIED, error::DISCONNECTED, NOT_FOUND, error::BACKEND_FAILURE : "connect(2) failed"
*>
fn UnixSocket? connect(String path, SocketKind kind)
{
	Fd fd = new_socket(kind)!;
	defer (void)fd.close();
	SockAddrUn addr;
	SockLen len = socket_address(&addr, path)!;
	if (sys_connect(fd.raw(), &addr, len) != 0) return errno_fault("connect", libc::errno())~;
	return adopt_socket(&fd, kind);
}

<*
 Bind and listen on `path`. A stale socket file is not removed: that is the
 caller's decision.

 @param backlog : "Pending connections the kernel queues (listen(2))"
 @require backlog > 0 : "A listening socket needs a positive backlog"
 @return? error::BACKEND_FAILURE : "bind(2) failed, EADDRINUSE when the path already exists"
*>
fn UnixSocket? listen(String path, SocketKind kind, CInt backlog)
{
	Fd fd = new_socket(kind)!;
	defer (void)fd.close();
	SockAddrUn addr;
	SockLen len = socket_address(&addr, path)!;
	if (sys_bind(fd.raw(), &addr, len) != 0) return errno_fault("bind", libc::errno())~;
	if (sys_listen(fd.raw(), backlog) != 0) return errno_fault("listen", libc::errno())~;
	return adopt_socket(&fd, kind);
}

<*
 Two connected sockets, one per end: what one sends the other receives.
*>
fn SocketPair? socket_pair(SocketKind kind)
{
	CInt[2] raw;
	if (sys_socketpair(AF_UNIX_FAMILY, kind.native_type() | SOCKET_CLOEXEC, 0, &raw[0]) != 0)
	{
		return errno_fault("socketpair", libc::errno())~;
	}
	Fd first  = { .value = raw[0] };
	Fd second = { .value = raw[1] };
	defer (void)first.close();
	defer (void)second.close();
	configure_socket(&first)!;
	configure_socket(&second)!;
	return { .first = adopt_socket(&first, kind), .second = adopt_socket(&second, kind) };
}

<*
 Take the next connection from a listening socket. Blocks unless the socket is
 non-blocking. The new socket is close-on-exec.

 @return? error::BUSY : "The socket is non-blocking and no connection is waiting"
 @return? error::INVALID_ARGUMENT : "The socket is not listening"
*>
fn UnixSocket? UnixSocket.accept(&self)
{
	CInt raw;
	while (true)
	{
		raw = accept_raw(self.fd.raw());
		if (raw >= 0) break;
		if (libc::errno() == EINTR) continue;
		return errno_fault("accept", libc::errno())~;
	}
	Fd fd = { .value = raw };
	defer (void)fd.close();
	configure_socket(&fd)!;
	return adopt_socket(&fd, self.kind);
}

<*
 The credentials of the process at the other end of a connected socket.

 @return? error::BACKEND_FAILURE, error::PERMISSION_DENIED : "The OS does not report them"
*>
fn PeerCredentials? UnixSocket.peer_credentials(&self) => read_peer_credentials(self.fd.raw());

<* Close the socket. Its descriptor is released even if the close reports an error. *>
fn void? UnixSocket.close(&self) @maydiscard => self.fd.close();

// Give up ownership of `fd` and wrap the descriptor as a socket of `kind`.
fn UnixSocket adopt_socket(Fd* fd, SocketKind kind) @private
{
	return { .fd = { .value = fd.release() }, .kind = kind };
}

// A new socket of the requested kind, configured for Bleu's use.
fn Fd? new_socket(SocketKind kind) @private
{
	CInt raw = sys_socket(AF_UNIX_FAMILY, kind.native_type() | SOCKET_CLOEXEC, 0);
	if (raw < 0) return errno_fault("socket", libc::errno())~;
	Fd fd = { .value = raw };
	defer (void)fd.close();
	configure_socket(&fd)!;
	return { .value = fd.release() };
}

// Copy descriptors from the ancillary data into `out`, closing those that do not
// fit. Returns how many descriptors arrived in total.