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

<* `struct pollfd` of poll(2). Its layout is an int and two shorts on Linux and Darwin alike. *>
struct PollEntry
{
	CInt fd;
	CShort events;
	CShort revents;
}

const CShort POLLIN_EVENT  = 0x0001; // POLLIN, as in the sources of poller_posix.c3
const CShort POLLHUP_EVENT = 0x0010; // POLLHUP, reported in revents when the peer has closed

// poll(2) for one descriptor and a zero timeout: only the hang-up check uses it.
extern fn CInt sys_poll_hup(PollEntry* fds, PollCount count, CInt timeout_ms) @cname("poll");

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
 @return? error::INVALID_ARGUMENT : "Too many descriptors, or descriptors with no data to travel with"
 @return? error::BUSY : "Non-blocking socket is full; nothing was sent"
 @return? error::DISCONNECTED : "The peer has closed the connection"
*>
fn usz? UnixSocket.send(&self, char[] bytes, Fd[] fds = { })
{
	check_descriptor_count(bytes, fds)!;
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

 @return? error::INVALID_ARGUMENT : "Descriptors with no data to travel with, or too many of them"
 @return? error::BUSY : "The socket filled up midway through the message"
*>
fn void? UnixSocket.send_all(&self, char[] bytes, Fd[] fds = { })
{
	check_descriptor_count(bytes, fds)!;
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

 A zero-length message on a sequenced-packet socket is a message, returned with
 `bytes == 0`. Zero bytes on a stream socket, and zero bytes on a sequenced-packet
 socket whose peer has hung up, mean the peer closed the connection.

 @param buffer : "Receives the data; must not be empty"
 @return "How many bytes and descriptors arrived"
 @return? error::DISCONNECTED : "The peer closed the connection"
 @return? error::PROTOCOL : "Descriptors or data were truncated, or too many descriptors arrived"
 @return? error::BUSY : "Non-blocking socket has nothing to read"
 @return? error::INVALID_ARGUMENT : "`buffer` is empty"
*>
fn RecvResult? UnixSocket.recv(&self, char[] buffer, Fd[] fd_buffer)
{
	if (buffer.len == 0)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "receive buffer is empty")~;
	}
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
	// Zero bytes and no descriptors: end of stream, or on a sequenced-packet socket either
	// that or a zero-length message. Only a hang-up tells them apart.
	if (got == 0 && total == 0 && (self.kind == STREAM || self.peer_hung_up()))
	{
		return error::raise(error::DISCONNECTED, error::Domain.INTERNAL, 0, "peer closed the connection")~;
	}
	return { .bytes = (usz)got, .fds = total };
}

// True when the peer has closed its end of the connection. recvmsg(2) returns 0 for a
// closed peer and for a zero-length sequenced-packet message alike; poll(2) reports
// POLLHUP only for the closed peer.
fn bool UnixSocket.peer_hung_up(&self)
{
	PollEntry entry = { .fd = self.fd.raw(), .events = POLLIN_EVENT, .revents = 0 };
	if (sys_poll_hup(&entry, (PollCount)1, 0) <= 0) return false;
	return ((CInt)entry.revents & (CInt)POLLHUP_EVENT) != 0;
}

// Refuse descriptors that have no data to travel with: the kernel would drop them, and the
// receiver would wait for descriptors that never come. Also bounds the count.
fn void? check_descriptor_count(char[] bytes, Fd[] fds) @private
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
	if (bytes.len == 0 && fds.len > 0)
	{
		return error::raise(
			error::INVALID_ARGUMENT,
			error::Domain.INTERNAL,
			0,
			"descriptors need at least one byte of data"
		)~;
	}
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