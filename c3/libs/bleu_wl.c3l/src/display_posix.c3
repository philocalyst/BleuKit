<*
 POSIX half of `bleu::wl::display`: the socket and descriptor operations. Everything is
 delegated to `bleu::rt::unix`, which owns the sendmsg(2)/recvmsg(2) layouts for Linux
 and macOS and the SCM_RIGHTS handling; see that module for the sources.
*>
module bleu::wl::display @feat(POSIX);
import bleu::rt, bleu::rt::unix, bleu::error, bleu::wl::wire;

<* A copy of `fd` that the caller owns, close-on-exec (`Fd.dup_cloexec`). *>
fn rt::Native? native_dup(rt::Native fd)
{
	unix::Fd source = { .value = fd };
	unix::Fd copy   = source.dup_cloexec()!;
	return copy.release();
}

<* Close a descriptor. Errors are ignored: there is nothing to do about a failed close. *>
fn void native_close(rt::Native fd)
{
	unix::Fd owned = { .value = fd };
	(void)owned.close();
}

<*
 Send `bytes` with the descriptors in `fds` attached to the first byte. `accepted`
 receives how many bytes the kernel took, which may be fewer than offered.

 @return? error::BUSY : "The socket is non-blocking and full; nothing was sent"
 @return? error::DISCONNECTED : "The peer closed the connection"
*>
fn void? native_send(rt::Native fd, char[] bytes, rt::Native[] fds, usz* accepted)
{
	unix::UnixSocket socket = { .fd = { .value = fd }, .kind = unix::SocketKind.STREAM };
	unix::Fd[wire::MAX_FDS_PER_MESSAGE] wrapped;
	for (usz i = 0; i < fds.len; i++) wrapped[i] = { .value = fds[i] };
	*accepted = socket.send(bytes, wrapped[0:fds.len])!;
}

<*
 Receive into `buffer`, storing the descriptors that arrive in `fds`. Each one is
 close-on-exec and owned by the caller.

 @return? error::BUSY : "The socket is non-blocking and nothing is waiting"
 @return? error::DISCONNECTED : "The peer closed the connection"
 @return? error::PROTOCOL : "Descriptors or data were truncated"
*>
fn void? native_recv(rt::Native fd, char[] buffer, rt::Native[] fds, Received* out)
{
	unix::UnixSocket socket = { .fd = { .value = fd }, .kind = unix::SocketKind.STREAM };
	unix::Fd[wire::MAX_FDS_PER_MESSAGE] wrapped;
	unix::RecvResult got    = socket.recv(buffer, wrapped[..])!;
	for (usz i = 0; i < got.fds; i++) fds[i] = wrapped[i].value;
	*out = { .bytes = got.bytes, .fds = got.fds };
}

<*
 Switch the descriptor between blocking and non-blocking.

 @return? error::BACKEND_FAILURE, error::PERMISSION_DENIED : "fcntl(2) failed"
*>
fn void? native_set_nonblocking(rt::Native fd, bool non_blocking)
{
	unix::Fd owned = { .value = fd };
	owned.set_nonblocking(non_blocking)!;
}

<*
 Connect to the compositor socket at `path` (a filesystem path, or an abstract name
 on Linux). The returned descriptor is owned by the caller.

 @return? NOT_FOUND, error::PERMISSION_DENIED, error::DISCONNECTED, error::BACKEND_FAILURE : "connect(2) failed"
*>
fn rt::Native? native_connect(String path)
{
	unix::UnixSocket socket = unix::connect(path, unix::SocketKind.STREAM)!;
	return socket.fd.release();
}