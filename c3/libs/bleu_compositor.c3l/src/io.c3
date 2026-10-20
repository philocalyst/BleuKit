<*
 Socket reads shared by the three clients: receive into a bounded buffer, read a
 reply to end-of-stream or to a line, and wait for one complete unit.

 Every function here is POSIX only: it is built on `bleu::rt::unix`.
*>
module bleu::compositor::io @feat(POSIX);
import bleu::rt::unix, bleu::error, bleu::compositor::wire, bleu::compositor::i3ipc, std::io;

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
 Receive once into the buffer's free room. On a non-blocking socket with nothing
 to read this returns 0 rather than waiting.

 @return "Bytes received; 0 when nothing was waiting"
 @return? error::DISCONNECTED : "The peer closed the connection"
 @return? error::PROTOCOL : "The buffer is full of an unfinished unit"
*>
fn usz? fill(unix::UnixSocket* socket, wire::Buffer* buffer)
{
	char[] room     = buffer.tail()!;
	Fd[] no_fds     = { };
	RecvResult? got = socket.recv(room, no_fds);
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

 @return? error::PROTOCOL : "The reply is longer than REPLY_BUFFER_BYTES"
 @return? error::BACKEND_FAILURE : "recv(2) failed"
*>
fn String? read_to_end(unix::UnixSocket* socket)
{
	DString text;
	text.init(tmem);
	char[READ_CHUNK_BYTES] chunk;
	Fd[] no_fds = { };
	while (true)
	{
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

 @return? error::DISCONNECTED : "The peer closed the connection first"
*>
fn String? await_line(unix::UnixSocket* socket, wire::Buffer* buffer)
{
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
		fill(socket, buffer)!;
	}
}

<*
 Wait until `buffer` holds one complete i3-ipc message, and take it. The payload
 is valid until the buffer is next fed.

 @return? error::DISCONNECTED : "The peer closed the connection first"
 @return? error::PROTOCOL : "The message is malformed or longer than the buffer"
*>
fn i3ipc::Frame? await_frame(unix::UnixSocket* socket, wire::Buffer* buffer)
{
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
		fill(socket, buffer)!;
	}
}