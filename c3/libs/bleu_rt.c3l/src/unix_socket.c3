<*
 AF_UNIX stream and seqpacket sockets, with SCM_RIGHTS file-descriptor passing.

 Layouts and constants that differ between Linux and macOS (struct msghdr,
 struct cmsghdr and its alignment, struct sockaddr_un, peer credentials) live in
 `unix_linux.c3` and `unix_darwin.c3`; everything here is the same on both.

 Sources common to both systems:
   - socket(2), sendmsg(2), recvmsg(2), unix(4):
     https://man7.org/linux/man-pages/man7/unix.7.html and the XNU sources below
   - AF_UNIX 1: include/linux/socket.h (https://raw.githubusercontent.com/torvalds/linux/master/include/uapi/linux/socket.h)
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
const CInt AF_UNIX_FAMILY = 1;
const CInt SOCK_STREAM_TYPE = 1;
const CInt SOCK_SEQPACKET_TYPE = 5;

<*
 Most file descriptors one message may carry. Bleu never sends more than this,
 and a receiver with a smaller buffer closes what does not fit.
*>
const usz MAX_FDS_PER_MESSAGE = 16;

<*
 Ancillary-data buffer for one message. It holds `MAX_FDS_PER_MESSAGE`
 descriptors with the header and alignment of both platforms, with room to spare.
*>
const usz CONTROL_BUFFER_SIZE = 256;

// Offset of sun_path in struct sockaddr_un on both platforms (a 2-byte family
// field or sun_len+sun_family), see the platform files.
const usz SUN_PATH_OFFSET = 2;

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

<* `struct iovec`: one buffer of a scatter/gather list. *>
struct IoVec
{
	void* base;
	usz len;
}

<*
 Credentials of the process at the other end of a connected socket.

 @param pid : "Process id; -1 when the platform cannot tell"
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

<* What one `recv` delivered. `fds` descriptors were written into the buffer given. *>
struct RecvResult
{
	usz bytes;
	usz fds;
}

<*
 The socket(2) type value of a kind.
*>
fn CInt SocketKind.native_type(self)
{
	switch (self)
	{
		case STREAM:    return SOCK_STREAM_TYPE;
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
 @return? error::ADDRESS_IN_USE : "Bind failed because the path already exists"
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
	Fd first = { .value = raw[0] };
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
 Send up to `bytes.len` bytes in one sendmsg(2) call, attaching `fds` to them.
 Stream sockets may accept fewer bytes than offered: the return value is what
 was accepted. The descriptors are sent with the first byte accepted, so they
 are only sent when this call accepts at least one byte.

 The descriptors stay owned by the caller; the kernel holds its own reference
 to each one it accepted, so the caller may close them afterwards.

 @param fds : "Descriptors to pass, at most `MAX_FDS_PER_MESSAGE`"
 @return "Bytes accepted by the kernel"
 @return? error::BUSY : "Non-blocking socket is full; nothing was sent"
 @return? error::DISCONNECTED : "The peer has closed the connection"
*>
fn usz? UnixSocket.send(&self, char[] bytes, Fd[] fds = {})
{
	if (fds.len > MAX_FDS_PER_MESSAGE)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "at most %d descriptors per message", MAX_FDS_PER_MESSAGE)~;
	}
	char[CONTROL_BUFFER_SIZE] control;
	IoVec iov = { .base = bytes.ptr, .len = bytes.len };
	MsgHdr msg;
	msg.attach(&iov, 1, null, 0);
	if (fds.len > 0)
	{
		usz data_len = fds.len * CInt::size;
		CmsgHdr* header = (CmsgHdr*)control.ptr;
		header.set_rights(data_len);
		CInt* values = (CInt*)(control.ptr + cmsg_align(CMSG_HEADER_SIZE));
		for (usz i = 0; i < fds.len; i++) values[i] = fds[i].raw();
		msg.attach(&iov, 1, control.ptr, cmsg_align(CMSG_HEADER_SIZE) + cmsg_align(data_len));
	}
	while (true)
	{
		sz sent = sys_sendmsg(self.fd.raw(), &msg, SEND_FLAGS);
		if (sent >= 0) return (usz)sent;
		if (libc::errno() == EINTR) continue;
		return errno_fault("sendmsg", libc::errno())~;
	}
}

<*
 Send every byte, looping over partial sends. The descriptors go with the first
 piece. Requires a blocking socket: a non-blocking one that fills up midway fails
 with BUSY, and the bytes already accepted cannot be taken back.

 @return? error::BUSY : "The socket filled up midway through the message"
*>
fn void? UnixSocket.send_all(&self, char[] bytes, Fd[] fds = {})
{
	usz done = 0;
	Fd[] pending = fds;
	while (done < bytes.len)
	{
		usz accepted = self.send(bytes[done..], pending)!;
		if (accepted == 0) return error::raise(error::BUSY, error::Domain.INTERNAL, 0, "sendmsg accepted no bytes")~;
		done += accepted;
		pending = {};
	}
}

<*
 Receive one message (one read for a stream) into `buffer`, and any descriptors
 that came with it into `fd_buffer`. Each received descriptor is close-on-exec
 and owned by the caller.

 If more descriptors arrive than `fd_buffer` holds, all of them are closed and
 the call fails. A message that does not fit `buffer` (sequenced-packet only) is
 also a failure: its data is gone, so the caller must not guess at it.

 @return "How many bytes and descriptors arrived"
 @return? error::DISCONNECTED : "The peer closed the connection"
 @return? error::PROTOCOL : "Descriptors or data were truncated, or too many descriptors arrived"
 @return? error::BUSY : "Non-blocking socket has nothing to read"
*>
fn RecvResult? UnixSocket.recv(&self, char[] buffer, Fd[] fd_buffer)
{
	char[CONTROL_BUFFER_SIZE] control;
	IoVec iov = { .base = buffer.ptr, .len = buffer.len };
	MsgHdr msg;
	msg.attach(&iov, 1, control.ptr, control.len);
	sz got;
	while (true)
	{
		got = sys_recvmsg(self.fd.raw(), &msg, MSG_CMSG_CLOEXEC_FLAG);
		if (got >= 0) break;
		if (libc::errno() == EINTR) continue;
		return errno_fault("recvmsg", libc::errno())~;
	}
	usz total = take_descriptors(control.ptr, msg.received_control_len(), fd_buffer);
	usz stored = min(total, fd_buffer.len);
	if (total > fd_buffer.len)
	{
		close_stored(fd_buffer[:stored]);
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "%d descriptors arrived, room for %d", total, fd_buffer.len)~;
	}
	if ((msg.received_flags() & MSG_CTRUNC_FLAG) != 0)
	{
		close_stored(fd_buffer[:stored]);
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "ancillary data was truncated")~;
	}
	if ((msg.received_flags() & MSG_TRUNC_FLAG) != 0)
	{
		close_stored(fd_buffer[:stored]);
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "message is longer than the buffer")~;
	}
	if (got == 0 && total == 0) return error::raise(error::DISCONNECTED, error::Domain.INTERNAL, 0, "peer closed the connection")~;
	return { .bytes = (usz)got, .fds = total };
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
fn usz take_descriptors(char* control, usz used, Fd[] out) @private
{
	usz total = 0;
	usz offset = 0;
	while (offset + CMSG_HEADER_SIZE <= used)
	{
		CmsgHdr* header = (CmsgHdr*)(control + offset);
		usz length = header.length();
		if (length < CMSG_HEADER_SIZE || offset + length > used) break;
		if (header.is_rights())
		{
			usz count = (length - cmsg_align(CMSG_HEADER_SIZE)) / CInt::size;
			CInt* values = (CInt*)(control + offset + cmsg_align(CMSG_HEADER_SIZE));
			for (usz i = 0; i < count; i++)
			{
				if (total < out.len)
				{
					out[total] = { .value = values[i] };
				}
				else
				{
					(void)libc::close(values[i]);
				}
				total++;
			}
		}
		offset += cmsg_align(length);
	}
	return total;
}

// Close the descriptors in `fds` and forget them.
fn void close_stored(Fd[] fds) @private
{
	foreach (&fd : fds) (void)fd.close();
}
