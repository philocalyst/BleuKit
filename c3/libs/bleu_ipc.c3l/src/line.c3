<*
 Splits a byte stream into newline-terminated lines for a reader on a socket.

 Bytes arrive in arbitrary pieces: one read may hold several lines, or the
 middle of one. `reserve` hands out room to read into, `commit` records how many
 bytes arrived, and `next_line` returns each complete line in turn.

 A line longer than `max_line` bytes (newline not counted) is refused with
 OUT_OF_RANGE, both when its newline has arrived and while it is still growing.
 The stream cannot be resynchronised after that, so the caller must close it.

 Not thread-safe: one reader owns a buffer.
*>
module bleu::ipc::line @feat(POSIX);
import bleu::error, bleu::ipc::wire;

<*
 The buffer. `data[start..end]` holds bytes not yet returned as lines;
 `data[start..scan]` is known to hold no newline.
*>
struct LineBuffer
{
	Allocator allocator;
	char[] data;
	usz start;
	usz end;
	usz scan;
	usz max_line;
}

<*
 Create an empty buffer.

 @param allocator : "Allocator for the buffer, which grows as needed"
 @param max_line : "Longest line accepted, in bytes, not counting its newline"
 @require max_line > 0 : "A line must be allowed at least one byte"
*>
fn void LineBuffer.init(&self, Allocator allocator, usz max_line)
{
	self.allocator = allocator;
	self.max_line = max_line;
	self.data = alloc::new_array(allocator, char, (sz)wire::READ_CHUNK);
}

<* Release the storage. Lines previously returned are no longer valid. *>
fn void LineBuffer.free(&self)
{
	alloc::free(self.allocator, self.data.ptr);
	*self = { };
}

<*
 Room for the next read: at least `wire::READ_CHUNK` bytes at the end of the
 buffer. Unread bytes are moved to the front, or the storage grows, when needed.
 The slice is valid until the next call of `reserve`.
*>
fn char[] LineBuffer.reserve(&self)
{
	if (self.end + wire::READ_CHUNK > (usz)self.data.len)
	{
		if (self.start > 0)
		{
			usz unread = self.end - self.start;
			if (unread > 0) mem::move(self.data.ptr, &self.data[(sz)self.start], (sz)unread);
			self.scan -= self.start;
			self.end = unread;
			self.start = 0;
		}
		if (self.end + wire::READ_CHUNK > (usz)self.data.len)
		{
			usz size = self.end + wire::READ_CHUNK;
			if (size < (usz)self.data.len * 2) size = (usz)self.data.len * 2;
			char[] bigger = alloc::new_array(self.allocator, char, (sz)size);
			if (self.end > 0) mem::copy(bigger.ptr, self.data.ptr, (sz)self.end);
			alloc::free(self.allocator, self.data.ptr);
			self.data = bigger;
		}
	}
	return self.data[(sz)self.end:(sz)wire::READ_CHUNK];
}

<*
 Record that `count` bytes were written into the slice `reserve` returned.

 @require self.end + count <= self.data.len : "Only bytes that were reserved can be committed"
*>
fn void LineBuffer.commit(&self, usz count)
{
	self.end += count;
}

<*
 The next complete line, without its newline and without a carriage return
 before that newline. The view is valid until the next call of this method or
 of `reserve`.

 @return? NO_MORE_ELEMENT : "No complete line is buffered yet"
 @return? error::OUT_OF_RANGE : "A line is longer than `max_line`; the stream must be closed"
*>
fn String? LineBuffer.next_line(&self)
{
	usz newline = self.end;
	for (usz i = self.scan; i < self.end; i++)
	{
		if (self.data[(sz)i] == '\n')
		{
			newline = i;
			break;
		}
	}
	if (newline == self.end)
	{
		self.scan = self.end;
		if (self.end - self.start > self.max_line)
		{
			return error::raise(
				error::OUT_OF_RANGE,
				error::Domain.INTERNAL,
				0,
				"request line exceeds %d bytes",
				self.max_line
			)~;
		}
		return NO_MORE_ELEMENT~;
	}
	if (newline - self.start > self.max_line)
	{
		return error::raise(
			error::OUT_OF_RANGE,
			error::Domain.INTERNAL,
			0,
			"request line exceeds %d bytes",
			self.max_line
		)~;
	}
	String line = (String)self.data[(sz)self.start:(sz)(newline - self.start)];
	if (line.len > 0 && line[line.len - 1] == '\r') line = line[0:line.len - 1];
	self.start = newline + 1;
	self.scan = self.start;
	return line;
}