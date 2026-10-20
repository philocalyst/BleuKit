<*
 The Wayland wire format: message framing, the argument encoders, and a decoder that
 checks every length before it reads.

 This module is platform-neutral. It never touches a socket: file descriptors are
 values of `bleu::rt::Native` that travel in a side queue, as they do on the real
 transport (SCM_RIGHTS in `bleu::wl::display`).

 Sources (each fact checked against two of these):
 - Wayland book, chapter "Wire Protocol" (https://wayland.freedesktop.org/docs/book/Protocol.html):
 32-bit words, header of object id then `size << 16 | opcode`, a null string or
 array has length 0, strings include their NUL and are padded to 32 bits, interior
 NUL bytes are not permitted, a new_id without a fixed interface is preceded by the
 interface name and the version.
 - wayland-backend 0.3.11 src/rs/wire.rs (https://static.crates.io/crates/wayland-backend/wayland-backend-0.3.11.crate):
 `write_to_buffers` and `parse_message` give the same header layout, the same
 string and array encoding, and the descriptor FIFO. src/rs/socket.rs lines 21 and 23
 give `MAX_FDS_OUT = 28` and `MAX_BYTES_OUT = 4096`.
 - wayland.xml protocol/wayland.xml (the `fixed` type: 24.8 signed fixed point).

 Byte order: the protocol uses the host's byte order. Every target Bleu supports is
 little-endian, so the encoding here is explicitly little-endian.
*>
module bleu::wl::wire;
import bleu::error, bleu::rt;

<* Bytes in the message header: the object id and the size/opcode word. *>
const usz HEADER_SIZE = 8;

<* Largest message, header included (wayland-backend socket.rs:23, MAX_BYTES_OUT). *>
const usz MAX_MESSAGE_SIZE = 4096;

<* Most descriptors one message may carry (wayland-backend socket.rs:21, MAX_FDS_OUT). *>
const usz MAX_FDS_PER_MESSAGE = 28;

<* Descriptors received but not yet consumed by a message. More than this is a protocol error. *>
const usz MAX_QUEUED_FDS = 64;

<* Every field and string is aligned to this many bytes. *>
const usz WORD_SIZE = 4;

<* Bit position of the size in the second header word. *>
const uint SIZE_SHIFT = 16;

<* Mask of the opcode in the second header word. *>
const uint OPCODE_MASK = 0xFFFF;

<* `fixed` argument: a signed 24.8 fixed-point number, stored as an int. *>
typedef Fixed = inline int;

<* Scale of the 24.8 format: 8 fraction bits. *>
const double FIXED_SCALE = 256.0;

<* The value as a double. *>
fn double Fixed.to_double(self) => (double)(int)self / FIXED_SCALE;

<*
 Fixed-point from a double, rounded to the nearest 1/256.

 @param value : "The number to convert; the result saturates to the int range"
*>
fn Fixed fixed_from_double(double value)
{
	double scaled = value * FIXED_SCALE;
	return (Fixed)(int)(scaled < 0 ? scaled - 0.5 : scaled + 0.5);
}

<* Round `n` up to a multiple of `WORD_SIZE`. *>
fn usz pad_word(usz n) @inline => ((n + WORD_SIZE - 1) / WORD_SIZE) * WORD_SIZE;

<* Store `value` at the start of `dst` in little-endian order. `dst` holds at least 4 bytes. *>
fn void store_u32(char[] dst, uint value) @inline
{
	dst[0] = (char)value;
	dst[1] = (char)(value >> 8);
	dst[2] = (char)(value >> 16);
	dst[3] = (char)(value >> 24);
}

<* Read a little-endian word from the start of `src`, which holds at least 4 bytes. *>
fn uint load_u32(char[] src) @inline
{
	return (uint)src[0] | ((uint)src[1] << 8) | ((uint)src[2] << 16) | ((uint)src[3] << 24);
}

<*
 A message being built. Call `begin`, then one `put_*` per argument in wire order,
 then send it. Nothing is allocated: the storage lives in the struct.

 Every `put_*` checks that the message still fits, so a request that is too large
 fails with an error and no bytes are written past the limit.
*>
struct Writer
{
	char[MAX_MESSAGE_SIZE] buf;
	usz len;
	uint object;
	ushort opcode;
	rt::Native[MAX_FDS_PER_MESSAGE] fds;
	usz fd_count;
}

<*
 Start a message to `object` with request or event number `opcode`.
*>
fn void Writer.begin(&self, uint object, ushort opcode)
{
	self.len = HEADER_SIZE;
	self.object = object;
	self.opcode = opcode;
	self.fd_count = 0;
}

<*
 Write the header and return the finished message. The slice points into the
 writer and is valid until the writer is begun again.
*>
fn char[] Writer.finish(&self)
{
	store_u32(self.buf[0:4], self.object);
	store_u32(self.buf[4:4], ((uint)self.len << SIZE_SHIFT) | ((uint)self.opcode & OPCODE_MASK));
	return self.buf[0:self.len];
}

<* The descriptors attached to the finished message, in order. *>
fn rt::Native[] Writer.descriptors(&self) => self.fds[0:self.fd_count];

<*
 Reserve `n` bytes at the end of the message.

 @return? error::INVALID_ARGUMENT : "The message would exceed MAX_MESSAGE_SIZE bytes"
*>
fn usz? Writer.reserve(&self, usz n)
{
	if (self.len + n > MAX_MESSAGE_SIZE)
	{
		return error::raise(
			error::INVALID_ARGUMENT,
			error::Domain.INTERNAL,
			0,
			"message of %d bytes exceeds the %d byte limit",
			self.len + n,
			MAX_MESSAGE_SIZE
		)~;
	}
	usz at = self.len;
	self.len += n;
	return at;
}

<*
 Append a 32-bit word: uint, int, object id, new_id, enum values and fixed all use it.

 @return? error::INVALID_ARGUMENT : "The message would exceed MAX_MESSAGE_SIZE bytes"
*>
fn void? Writer.put_uint(&self, uint value)
{
	usz at = self.reserve(WORD_SIZE)!;
	store_u32(self.buf[at:WORD_SIZE], value);
}

<* Append a signed 32-bit word. *>
fn void? Writer.put_int(&self, int value) => self.put_uint((uint)value);

<* Append a 24.8 fixed-point value. *>
fn void? Writer.put_fixed(&self, Fixed value) => self.put_uint((uint)(int)value);

<* Append an object id. Zero is the null object. *>
fn void? Writer.put_object(&self, uint id) => self.put_uint(id);

<* Append the id of a new object the request creates. *>
fn void? Writer.put_new_id(&self, uint id) => self.put_uint(id);

<*
 Append a string. The wire form is the length including the NUL, then the bytes,
 the NUL, and padding to a 32-bit boundary.

 @return? error::INVALID_ARGUMENT : "The message would exceed MAX_MESSAGE_SIZE bytes"
*>
fn void? Writer.put_string(&self, String value)
{
	self.put_array_with_nul(value, value.len + 1)!;
}

<*
 Append a string that may be null. An empty string is sent as the null string
 (length 0); a non-empty one is sent as `put_string` sends it.

 @return? error::INVALID_ARGUMENT : "The message would exceed MAX_MESSAGE_SIZE bytes"
*>
fn void? Writer.put_nullable_string(&self, String value)
{
	if (value.len == 0)
	{
		self.put_uint(0)!;
		return;
	}
	self.put_string(value)!;
}

<*
 Append an array of bytes: the length, the bytes, padding to a 32-bit boundary.

 @return? error::INVALID_ARGUMENT : "The message would exceed MAX_MESSAGE_SIZE bytes"
*>
fn void? Writer.put_array(&self, char[] bytes)
{
	self.put_array_with_nul(bytes, bytes.len)!;
}

// Shared body of put_string and put_array: a length word, then `count` bytes of `bytes`,
// a NUL byte when `count` is one more than `bytes` holds, then zero padding.
fn void? Writer.put_array_with_nul(&self, char[] bytes, usz count)
{
	self.put_uint((uint)count)!;
	usz padded = pad_word(count);
	usz at     = self.reserve(padded)!;
	for (usz i = 0; i < padded; i++)
	{
		self.buf[at + i] = i < bytes.len ? bytes[i] : 0;
	}
}

<*
 Attach a file descriptor. The message carries no bytes for it; the descriptor is sent
 out of band with the message. The writer does not own it: the display duplicates it
 when the message is queued.

 @return? error::INVALID_ARGUMENT : "More than MAX_FDS_PER_MESSAGE descriptors"
*>
fn void? Writer.put_fd(&self, rt::Native fd)
{
	if (self.fd_count == MAX_FDS_PER_MESSAGE)
	{
		return error::raise(
			error::INVALID_ARGUMENT,
			error::Domain.INTERNAL,
			0,
			"a message carries at most %d descriptors",
			MAX_FDS_PER_MESSAGE
		)~;
	}
	self.fds[self.fd_count++] = fd;
}

<*
 Descriptors received from the peer, oldest first. The protocol uses them in the order
 the messages that name them arrive, so a plain FIFO matches them up. The queue does not
 own what it holds: whoever pops a descriptor owns it.
*>
struct FdQueue
{
	rt::Native[MAX_QUEUED_FDS] fds;
	usz head;
	usz count;
}

<*
 Append a received descriptor.

 @return? error::PROTOCOL : "More than MAX_QUEUED_FDS descriptors are waiting to be used"
*>
fn void? FdQueue.push(&self, rt::Native fd)
{
	if (self.count == MAX_QUEUED_FDS)
	{
		return error::raise(
			error::PROTOCOL,
			error::Domain.INTERNAL,
			0,
			"more than %d descriptors in flight",
			MAX_QUEUED_FDS
		)~;
	}
	self.fds[(self.head + self.count) % MAX_QUEUED_FDS] = fd;
	self.count++;
}

<*
 Take the oldest descriptor.

 @return? error::PROTOCOL : "The message expects a descriptor that never arrived"
*>
fn rt::Native? FdQueue.pop(&self)
{
	if (self.count == 0)
	{
		return error::raise(
			error::PROTOCOL,
			error::Domain.INTERNAL,
			0,
			"message expects a descriptor that did not arrive"
		)~;
	}
	rt::Native fd = self.fds[self.head];
	self.head = (self.head + 1) % MAX_QUEUED_FDS;
	self.count--;
	return fd;
}

<*
 The header of one message in a receive buffer.

 `complete` is false when the buffer ends before the whole message: the caller keeps
 the bytes and reads more. `size` is the full length including the header.
*>
struct Frame
{
	uint object;
	ushort opcode;
	usz size;
	bool complete;
}

<*
 Read the header of the message at the start of `available`. Nothing is consumed.

 @param available : "Received bytes, starting at a message boundary"
 @return "The header; `complete` says whether the whole message is present"
 @return? error::PROTOCOL : "The size is below the header, above the limit, or not a multiple of 4"
*>
fn Frame? read_frame(char[] available)
{
	if (available.len < HEADER_SIZE) return { .complete = false };
	uint word = load_u32(available[4:4]);
	usz size  = (usz)(word >> SIZE_SHIFT);
	if (size < HEADER_SIZE || size > MAX_MESSAGE_SIZE || size % WORD_SIZE != 0)
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, (int)size, "message size %d is invalid", size)~;
	}
	return {
		.object = load_u32(available[0:4]),
		.opcode = (ushort)(word & OPCODE_MASK),
		.size = size,
		.complete = (usz)available.len >= size,
	};
}

<* The argument bytes of a complete message whose header was read from `available`. *>
fn char[] Frame.payload(self, char[] available) => available[HEADER_SIZE:self.size - HEADER_SIZE];

<*
 Decodes the arguments of one message, in wire order. Every read checks the bytes that
 remain. Strings and arrays are views into the message, valid until the buffer is
 reused. A descriptor argument takes the next one from the queue.
*>
struct Reader
{
	char[] data;
	usz pos;
	FdQueue* fds;
}

<* Bytes not yet read. *>
fn usz Reader.remaining(&self) => (usz)self.data.len - self.pos;

<*
 Read a 32-bit word.

 @return? error::PROTOCOL : "The message ends before the argument"
*>
fn uint? Reader.get_uint(&self)
{
	if (self.remaining() < WORD_SIZE)
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "message ends before an argument")~;
	}
	uint value = load_u32(self.data[self.pos:WORD_SIZE]);
	self.pos += WORD_SIZE;
	return value;
}

<* Read a signed 32-bit word. *>
fn int? Reader.get_int(&self) => (int)self.get_uint()!;

<* Read a 24.8 fixed-point value. *>
fn Fixed? Reader.get_fixed(&self) => (Fixed)(int)self.get_uint()!;

<* Read an object id. Zero is the null object. *>
fn uint? Reader.get_object(&self) => self.get_uint();

<* Read the id of a new object the event creates. *>
fn uint? Reader.get_new_id(&self) => self.get_uint();

<*
 Read a string. A null string (length 0) is returned as an empty string. The result has
 no NUL, and it is a view into the message.

 @return? error::PROTOCOL : "The length runs past the message, the string has no NUL at its end, or it holds an interior NUL"
*>
fn String? Reader.get_string(&self)
{
	uint length = self.get_uint()!;
	if (length == 0) return "";
	char[] raw = self.take(length)!;
	if (raw[length - 1] != 0)
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "string is not NUL-terminated")~;
	}
	for (usz i = 0; i + 1 < length; i++)
	{
		if (raw[i] == 0)
		{
			return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "string holds an interior NUL")~;
		}
	}
	return (String)raw[0:length - 1];
}

<*
 Read an array. The result is a view into the message.

 @return? error::PROTOCOL : "The length runs past the message"
*>
fn char[]? Reader.get_array(&self)
{
	uint length = self.get_uint()!;
	return self.take(length);
}

<*
 Take the next descriptor from the queue. The caller owns it and must close it.

 @return? error::PROTOCOL : "The message expects a descriptor that did not arrive"
*>
fn rt::Native? Reader.get_fd(&self) => self.fds.pop();

<*
 Check that every byte of the message was read. A message with trailing bytes does not
 match its signature, so it is an error rather than something to skip.

 @return? error::PROTOCOL : "Bytes remain after the last argument"
*>
fn void? Reader.expect_end(&self)
{
	if (self.remaining() != 0)
	{
		return error::raise(
			error::PROTOCOL,
			error::Domain.INTERNAL,
			0,
			"%d bytes after the last argument",
			self.remaining()
		)~;
	}
}

// Read `length` bytes padded to a word and return the unpadded bytes.
fn char[]? Reader.take(&self, uint length)
{
	usz padded = pad_word(length);
	if (padded > self.remaining())
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "%d bytes run past the message", length)~;
	}
	char[] view = self.data[self.pos:length];
	self.pos += padded;
	return view;
}