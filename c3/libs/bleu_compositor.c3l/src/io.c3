<*
 Socket reads shared by the three clients: receive into a bounded buffer, read a
 reply to end-of-stream or to a line, and wait for one complete unit.

 Command sockets are blocking. Every read on one first waits for data with a
 deadline (`await_readable`), so a compositor that stops answering fails its
 request with DISCONNECTED instead of holding the worker thread forever.

 Every function here is POSIX only: it is built on `bleu::rt::unix`.
*>
module bleu::compositor::io @feat(POSIX);
import libc, bleu::rt::unix, bleu::error, bleu::compositor::wire, bleu::compositor::i3ipc, bleu::deadline, std::io, std::time;

<*
 Largest reply accepted from a command socket: a whole window tree, a list of
 windows, or any other reply the compositors send.
*>
const usz REPLY_BUFFER_BYTES = 16 * 1024 * 1024;

<* Largest event line or message accepted on an event socket. *>
const usz EVENT_BUFFER_BYTES = 4 * 1024 * 1024;

<* Bytes requested from the kernel per `recv` when a reply is read to its end. *>
const usz READ_CHUNK_BYTES = 4096;

<*
 How long a command request may wait for its reply, in total. A compositor that is
 silent for longer fails the request with DISCONNECTED, so the connection is
 dropped and the worker, and the shutdown that joins it, go on.
*>
const Duration REPLY_TIMEOUT = (Duration)2_000_000;

// Microseconds in a millisecond: `Duration` is in microseconds, `poll(2)` takes milliseconds.
const long MICROS_PER_MILLI = 1_000;

// poll(2) over one descriptor. `struct pollfd` is { int fd; short events; short revents; }
// and nfds_t is `unsigned long` on glibc and `unsigned int` on Darwin, as bleu_rt's
// poller_posix.c3 records (its sources: poll(2), XNU bsd/sys/poll.h).
struct PollFd
{
	CInt fd;
	CShort events;
	CShort revents;
}

alias PollCount @feat(LINUX) = CULong;
alias PollCount @feat(!LINUX) = CUInt;

// POLLIN 0x0001 on Linux and Darwin (bleu_rt poller_posix.c3, same sources).
const CShort POLLIN = 0x0001;

extern fn CInt sys_poll(PollFd* fds, PollCount count, CInt timeout_ms) @cname("poll");

<*
 Wait until `socket` has data to read or its peer has closed it, for at most `timeout`.
 A signal that interrupts the wait is retried with the same timeout.

 @param timeout : "How long to wait; a finite duration"
 @require timeout != time::FOREVER : "A command socket is always read with a finite deadline"
 @return? error::DISCONNECTED : "Nothing arrived before the timeout"
 @return? error::BACKEND_FAILURE : "poll(2) failed"
*>
fn void? await_readable(unix::UnixSocket* socket, Duration timeout)
{
	PollFd watch = { .fd = socket.fd.raw(), .events = POLLIN };
	int millis   = (int)((long)timeout / MICROS_PER_MILLI);
	while (true)
	{
		CInt ready = sys_poll(&watch, (PollCount)1, (CInt)millis);
		if (ready > 0) return;
		if (ready == 0) return error::raise(
			error::DISCONNECTED,
			error::Domain.INTERNAL,
			0,
			"the compositor did not answer within %d ms",
			millis
		)~;
		if (libc::errno() != EINTR) return error::raise(
			error::BACKEND_FAILURE,
			error::Domain.ERRNO,
			libc::errno(),
			"poll(2) failed on a command socket"
		)~;
	}
}

<*
 Receive once into the buffer's free room. On a non-blocking socket with nothing
 to read this returns 0 rather than waiting.

 @return "Bytes received; 0 when nothing was waiting"
 @return? error::DISCONNECTED : "The peer closed the connection"
 @return? error::PROTOCOL : "The buffer is full of an unfinished unit"
*>
fn usz? fill(unix::UnixSocket* socket, wire::Buffer* buffer)
{
	char[] room       = buffer.tail()!;
	unix::Fd[] no_fds = { };
	RecvResult? got   = socket.recv(room, no_fds);
	if (catch err = got)
	{
		if (err == error::BUSY) return 0;
		return err~;
	}
	buffer.commit(got.bytes);
	return got.bytes;
}

<*
 Receive until the peer closes the connection and return everything it sent.
 Temporary memory: call inside a `@pool()`.

 @param timeout : "The most time the whole reply may take"
 @return? error::PROTOCOL : "The reply is longer than REPLY_BUFFER_BYTES"
 @return? error::DISCONNECTED : "The compositor did not answer within `timeout`"
 @return? error::BACKEND_FAILURE : "recv(2) failed"
*>
fn String? read_to_end(unix::UnixSocket* socket, Duration timeout)
{
	deadline::Deadline limit = deadline::after(timeout);
	DString text;
	text.init(tmem);
	char[READ_CHUNK_BYTES] chunk;
	unix::Fd[] no_fds = { };
	while (true)
	{
		await_readable(socket, limit.remaining())!;
		RecvResult? got = socket.recv(chunk[..], no_fds);
		if (catch err = got)
		{
			if (err == error::DISCONNECTED) return text.str_view();
			return err~;
		}
		if ((usz)text.len() + got.bytes > REPLY_BUFFER_BYTES)
		{
			return error::raise(
				error::PROTOCOL,
				error::Domain.INTERNAL,
				0,
				"reply exceeds %d bytes",
				REPLY_BUFFER_BYTES
			)~;
		}
		text.append_bytes(chunk[0:(sz)got.bytes]);
	}
}

<*
 Wait until `buffer` holds one complete line, and return it (without the newline).
 Temporary memory: call inside a `@pool()`.

 @param timeout : "The most time the whole line may take to arrive"
 @return? error::DISCONNECTED : "The peer closed the connection first, or stayed silent past `timeout`"
*>
fn String? await_line(unix::UnixSocket* socket, wire::Buffer* buffer, Duration timeout)
{
	deadline::Deadline limit = deadline::after(timeout);
	while (true)
	{
		String? line = buffer.take_line();
		if (catch err = line)
		{
			if (err != NOT_FOUND) return err~;
		}
		else
		{
			return line.copy(tmem);
		}
		await_readable(socket, limit.remaining())!;
		fill(socket, buffer)!;
	}
}

<*
 Wait until `buffer` holds one complete i3-ipc message, and take it. The payload
 is valid until the buffer is next fed.

 @param timeout : "The most time the whole message may take to arrive"
 @return? error::DISCONNECTED : "The peer closed the connection first, or stayed silent past `timeout`"
 @return? error::PROTOCOL : "The message is malformed or longer than the buffer"
*>
fn i3ipc::Frame? await_frame(unix::UnixSocket* socket, wire::Buffer* buffer, Duration timeout)
{
	deadline::Deadline limit = deadline::after(timeout);
	while (true)
	{
		i3ipc::Frame? frame = i3ipc::take_frame(buffer);
		if (catch err = frame)
		{
			if (err != NOT_FOUND) return err~;
		}
		else
		{
			return frame;
		}
		await_readable(socket, limit.remaining())!;
		fill(socket, buffer)!;
	}
}