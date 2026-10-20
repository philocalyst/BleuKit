<*
 Messages over AF_UNIX sockets: byte streams or datagrams, with SCM_RIGHTS
 file-descriptor passing, the partial-write and EAGAIN handling, and the
 receive-side checks that stop a truncated message from being half-trusted.

 Sources: sendmsg(2), recvmsg(2), cmsg(3) (https://man7.org/linux/man-pages/),
 and the layouts in `unix_linux.c3` and `unix_darwin.c3`.
*>
module bleu::rt::unix @feat(POSIX);
import libc, bleu::rt, bleu::error;

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

<* `struct iovec`: one buffer of a scatter/gather list. *>
struct IoVec
{
	void* base;
	usz len;
}

<* What one `recv` delivered. `fds` descriptors were written into the buffer given. *>
struct RecvResult
{
	usz bytes;
	usz fds;
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
fn usz? UnixSocket.send(&self, char[] bytes, Fd[] fds = { })
{
	if ((usz)fds.len > MAX_FDS_PER_MESSAGE)
	{
		return error::raise(
			error::INVALID_ARGUMENT,
			error::Domain.INTERNAL,
			0,
			"at most %d descriptors per message",
			MAX_FDS_PER_MESSAGE
		)~;
	}
	char[CONTROL_BUFFER_SIZE] control_storage;
	char[] control = control_storage[..];
	IoVec iov      = { .base = bytes.ptr, .len = bytes.len };
	MsgHdr msg;
	msg.attach(&iov, 1, null, 0);
	if (fds.len > 0)
	{
		usz data_len    = (usz)fds.len * CInt::size;
		CmsgHdr* header = (CmsgHdr*)control.ptr;
		header.set_rights(data_len);
		CInt* values = (CInt*)(control.ptr + cmsg_align(CMSG_HEADER_SIZE));
		for (usz i = 0; i < (usz)fds.len; i++) values[i] = fds[i].raw();
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
fn void? UnixSocket.send_all(&self, char[] bytes, Fd[] fds = { })
{
	usz done     = 0;
	Fd[] pending = fds;
	while (done < (usz)bytes.len)
	{
		usz accepted = self.send(bytes[done..], pending)!;
		if (accepted == 0) return error::raise(error::BUSY, error::Domain.INTERNAL, 0, "sendmsg accepted no bytes")~;
		done += accepted;
		pending = { };
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
	char[CONTROL_BUFFER_SIZE] control_storage;
	char[] control = control_storage[..];
	IoVec iov      = { .base = buffer.ptr, .len = buffer.len };
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
	usz total    = take_descriptors(control.ptr, msg.received_control_len(), fd_buffer);
	usz capacity = (usz)fd_buffer.len;
	usz stored   = min(total, capacity);
	foreach (&fd : fd_buffer[:stored])
	{
		if (catch err = configure_received_fd(fd))
		{
			close_stored(fd_buffer[:stored]);
			return err~;
		}
	}
	if (total > capacity)
	{
		close_stored(fd_buffer[:stored]);
		return error::raise(
			error::PROTOCOL,
			error::Domain.INTERNAL,
			0,
			"%d descriptors arrived, room for %d",
			total,
			capacity
		)~;
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
	if (got == 0 && total == 0) return error::raise(
		error::DISCONNECTED,
		error::Domain.INTERNAL,
		0,
		"peer closed the connection"
	)~;
	return { .bytes = (usz)got, .fds = total };
}

fn usz take_descriptors(char* control, usz used, Fd[] out) @private
{
	usz total  = 0;
	usz offset = 0;
	while (offset + CMSG_HEADER_SIZE <= used)
	{
		CmsgHdr* header = (CmsgHdr*)(control + offset);
		usz length      = header.length();
		if (length < CMSG_HEADER_SIZE || offset + length > used) break;
		if (header.is_rights())
		{
			usz count    = (length - cmsg_align(CMSG_HEADER_SIZE)) / CInt::size;
			CInt* values = (CInt*)(control + offset + cmsg_align(CMSG_HEADER_SIZE));
			for (usz i = 0; i < count; i++)
			{
				if (total < (usz)out.len)
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