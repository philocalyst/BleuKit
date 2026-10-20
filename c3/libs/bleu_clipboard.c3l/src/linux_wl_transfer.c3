<*
 Pipe transfers of the Wayland data-control protocol.

 Reading an offer: `receive(mime, fd)` asks the owner to write into the write end of a pipe.
 The read end is non-blocking and sits in the poller, so the owner can be slow or stalled
 without holding up this service. Each transfer has a size cap and a deadline; a transfer
 that exceeds either is abandoned. Serving our own source is the opposite direction and is
 done synchronously, bounded by the same timeout (the bytes are already in memory).

 Descriptors: pipe2(2) with O_CLOEXEC and O_NONBLOCK. The write end is closed right after
 `receive` is sent, because the display duplicates descriptors when it writes a message.
*>
module bleu::clipboard::linux_wl @feat(LINUX);
import bleu::clipboard, bleu::deadline, bleu::error, bleu::operation, bleu::rt, bleu::rt::unix, bleu::wl::display, libc, std::time;

// libc entry points. Signatures from the Linux man pages: pipe2(2), read(2), write(2), poll(2).
extern fn CInt sys_pipe2(CInt* fds, CInt flags) @cname("pipe2");
extern fn sz sys_read(CInt fd, void* buf, usz count) @cname("read");
extern fn sz sys_write(CInt fd, void* buf, usz count) @cname("write");
extern fn CInt sys_poll(PollFd* fds, usz count, CInt timeout_ms) @cname("poll");

<* `struct pollfd` from poll(2). *>
struct PollFd
{
	CInt fd;
	short events;
	short revents;
}

// Values from the Linux uapi headers: fcntl.h O_CLOEXEC 02000000 and O_NONBLOCK 04000 (same on x86-64 and aarch64).
const CInt O_CLOEXEC  = 0x80000;
const CInt O_NONBLOCK = 0x800;
// poll.h POLLOUT.
const short POLLOUT = 0x0004;
// Bytes read per `read` call.
const usz READ_CHUNK = 4096;

<*
 One pipe being read. `operation` is a retained `Operation{Bytes}*` for a FETCH, and null for a
 CAPTURE, which feeds the board instead.
*>
struct WlTransfer
{
	bool active;
	rt::Native fd;
	Slot slot;
	ulong seq;
	String mime;
	DString data;
	Deadline deadline;
	void* operation;
}

// The index of a free transfer slot.
fn usz? WlSession.free_transfer(&self)
{
	for (usz i = 0; i < MAX_TRANSFERS; i++)
	{
		if (!self.transfers[i].active) return i;
	}
	return error::BUSY~;
}

<*
 Ask the owner of `offer` for `mime` through a new pipe. The bytes arrive in a later `pump`: a
 CAPTURE stores them on the board for `slot` at `seq`; a FETCH completes `operation`.

 @param operation : "A retained `Operation{Bytes}*` that the transfer takes over, or null"
 @return? error::BUSY : "Every transfer slot is in use"
 @return? error::BACKEND_FAILURE : "The pipe or the request failed"
*>
fn void? WlSession.start_receive(&self, WlOffer* offer, Slot slot, ulong seq, String mime, void* operation)
{
	usz index = self.free_transfer()!;
	CInt[2] ends;
	if (sys_pipe2(&ends[0], O_CLOEXEC | O_NONBLOCK) != 0)
	{
		return error::raise(error::BACKEND_FAILURE, error::Domain.ERRNO, libc::errno(), "pipe2 failed")~;
	}
	rt::Native read_end  = ends[0];
	rt::Native write_end = ends[1];
	if (catch err = proto_receive(self.kind, offer.object, mime, write_end))
	{
		display::native_close(read_end);
		display::native_close(write_end);
		return err~;
	}
	display::native_close(write_end);
	WlTransfer* transfer = &self.transfers[index];
	transfer.active = true;
	transfer.fd = read_end;
	transfer.slot = slot;
	transfer.seq = seq;
	transfer.mime = mime.copy(self.allocator);
	transfer.data.init(self.allocator);
	transfer.deadline = deadline::after(self.timeout);
	transfer.operation = operation;
}

<*
 Read what is available from transfer `index`. End of file completes it; an error, an
 oversize payload or a read that fails outright abandons it. EAGAIN means "later".
*>
fn void WlSession.service_transfer(&self, usz index)
{
	WlTransfer* transfer = &self.transfers[index];
	char[READ_CHUNK] chunk;
	while (true)
	{
		sz got = sys_read(transfer.fd, &chunk, READ_CHUNK);
		if (got == 0)
		{
			self.complete_transfer(index);
			return;
		}
		if (got < 0)
		{
			if (libc::errno() == (CInt)libc::Errno.EAGAIN) return;
			self.abort_transfer(index, error::BACKEND_FAILURE);
			return;
		}
		if (transfer.data.len() + got > (sz)self.board.payload_limit)
		{
			self.abort_transfer(index, error::OUT_OF_RANGE);
			return;
		}
		transfer.data.append_bytes(chunk[0:got]);
	}
}

<* Finish transfer `index` with what it read: store the text, or complete the fetch. *>
fn void WlSession.complete_transfer(&self, usz index)
{
	WlTransfer* transfer = &self.transfers[index];
	char[] bytes = (char[])transfer.data.str_view();
	if (transfer.operation != null)
	{
		Operation{Bytes}* op = (Operation{Bytes}*)transfer.operation;
		Bytes copy = bytes.len == 0 ? { } : alloc::clone_slice(op.allocator(), bytes);
		op.succeed(copy);
		op.release();
	}
	else
	{
		self.board.captured(transfer.slot, transfer.seq, transfer.mime, bytes);
	}
	self.release_transfer(index);
}

<* Abandon transfer `index`: a fetch fails with `failure`, a capture is dropped. *>
fn void WlSession.abort_transfer(&self, usz index, fault failure)
{
	WlTransfer* transfer = &self.transfers[index];
	if (transfer.operation != null)
	{
		Operation{Bytes}* op = (Operation{Bytes}*)transfer.operation;
		op.fail(failure);
		op.release();
	}
	self.release_transfer(index);
}

<* Abandon every transfer whose deadline has passed. *>
fn void WlSession.expire_transfers(&self)
{
	for (usz i = 0; i < MAX_TRANSFERS; i++)
	{
		if (self.transfers[i].active && self.transfers[i].deadline.expired())
		{
			self.abort_transfer(i, TIMEOUT);
		}
	}
}

// Close the pipe and free the transfer slot. The operation, if any, was already released.
fn void WlSession.release_transfer(&self, usz index)
{
	WlTransfer* transfer = &self.transfers[index];
	display::native_close(transfer.fd);
	transfer.data.free();
	if (transfer.mime.len > 0) alloc::free(self.allocator, transfer.mime.ptr);
	transfer.mime = "";
	transfer.operation = null;
	transfer.active = false;
}

<*
 Serve one of our sources: write the bytes of `mime` into `fd`, then close it. An unknown
 type just closes the descriptor, which the requester reads as an empty payload.
*>
fn void source_send(WlSource* source, String mime, rt::Native fd)
{
	defer display::native_close(fd);
	foreach (representation : source.representations)
	{
		if (representation.mime != mime) continue;
		// The requester only sees what was written; a failure ends the stream early.
		if (catch err = write_payload(fd, representation.bytes, source.session.timeout)) {}
		return;
	}
}

<*
 Write all of `bytes` into `fd`, waiting for the reader to make room, for at most `timeout`.

 @return? TIMEOUT : "The reader did not make room in time"
 @return? error::BACKEND_FAILURE : "The write failed"
*>
fn void? write_payload(rt::Native fd, char[] bytes, Duration timeout)
{
	unix::Fd sink = { .value = fd };
	sink.set_nonblocking(true)!;
	Deadline deadline = deadline::after(timeout);
	usz written = 0;
	while (written < (usz)bytes.len)
	{
		sz sent = sys_write(fd, (void*)&bytes[written], (usz)bytes.len - written);
		if (sent > 0)
		{
			written += (usz)sent;
			continue;
		}
		if (sent < 0 && libc::errno() != (CInt)libc::Errno.EAGAIN)
		{
			return error::raise(error::BACKEND_FAILURE, error::Domain.ERRNO, libc::errno(), "write to a requester failed")~;
		}
		if (deadline.expired()) return TIMEOUT~;
		wait_writable(fd, deadline.remaining())!;
	}
}

// Wait until `fd` is writable, or `timeout` passes.
fn void? wait_writable(rt::Native fd, Duration timeout)
{
	PollFd watch = { .fd = fd, .events = POLLOUT, .revents = 0 };
	long ms = (long)timeout / 1000;
	if (ms < 1) ms = 1;
	CInt ready = sys_poll(&watch, 1, (CInt)ms);
	if (ready < 0) return error::raise(error::BACKEND_FAILURE, error::Domain.ERRNO, libc::errno(), "poll failed")~;
	if (ready == 0) return TIMEOUT~;
}
