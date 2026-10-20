<*
 Byte-level framing shared by the three protocols: a bounded buffer that takes
 partial reads and yields complete lines or exact-length messages, the comma
 field rule of Hyprland events, and checks on ids that go into commands.
*>
module bleu::compositor::wire @feat(POSIX);
import bleu::error;

<*
 A bounded accumulator for stream input. `feed` takes what fits, `take_line`
 and `peek_exact` hand out complete units. A unit larger than `capacity` can
 never be taken, so a peer that sends one is a PROTOCOL error, not a growing
 buffer.

 Views returned by `take_line` and `peek_exact` stay valid until the next `feed`, `tail` or `consume`.
*>
struct Buffer
{
	Allocator allocator;
	char[] data;
	usz capacity;
	usz start; // First unread byte.
	usz filled; // One past the last byte received.
	usz scanned; // Unread bytes before this offset are known to hold no newline.
}

<*
 Allocate the storage. Call once, before any other method.

 @param allocator : "Long-lived allocator for the storage"
 @require capacity > 0 : "A buffer needs room for at least one byte"
*>
fn void Buffer.init(&self, Allocator allocator, usz capacity)
{
	self.allocator = allocator;
	self.data = alloc::new_array(allocator, char, (sz)capacity);
	self.capacity = capacity;
	self.start = 0;
	self.filled = 0;
	self.scanned = 0;
}

<* Release the storage. The buffer must not be used afterwards. *>
fn void Buffer.free(&self)
{
	alloc::free(self.allocator, self.data.ptr);
	self.data = { };
}

<* Bytes received but not yet taken. *>
fn usz Buffer.pending(&self) @inline => self.filled - self.start;

<*
 Accept as many of `bytes` as fit. Consumed space is reclaimed first.

 @return "How many bytes were accepted; the rest must be fed again after taking units"
 @return? error::PROTOCOL : "The buffer is full of unfinished data: the unit exceeds its capacity"
*>
fn usz? Buffer.feed(&self, char[] bytes)
{
	char[] room = self.tail()!;
	usz taken   = min((usz)room.len, (usz)bytes.len);
	if (taken > 0) mem::copy(room.ptr, bytes.ptr, (sz)taken);
	self.commit(taken);
	return taken;
}

<*
 The next complete line, without its newline. A line ends at "\n"; a carriage
 return before it is part of the line and the caller strips it.

 @return "The line"
 @return? NOT_FOUND : "No complete line is buffered yet"
*>
fn String? Buffer.take_line(&self)
{
	// Resume where the last search stopped, so a line that arrives in pieces is scanned once.
	usz from = self.scanned > self.start ? self.scanned : self.start;
	for (usz i = from; i < self.filled; i++)
	{
		if (self.data[i] != '\n') continue;
		String line = (String)self.data[self.start:i - self.start];
		self.start = i + 1;
		return line;
	}
	self.scanned = self.filled;
	return NOT_FOUND~;
}

<*
 The next `count` bytes, without taking them: a view that stays valid until the
 next `feed`, `tail` or `consume`.

 @return? NOT_FOUND : "Fewer than `count` bytes are buffered yet"
*>
fn String? Buffer.peek_exact(&self, usz count)
{
	if (self.pending() < count) return NOT_FOUND~;
	return (String)self.data[self.start:count];
}

<* Drop `count` unread bytes. They must have been peeked. *>
fn void Buffer.consume(&self, usz count) @inline
{
	self.start += count;
}

<*
 The free room after the unread bytes, into which a socket receives directly.
 Follow with `commit` for the number of bytes received.

 @return? error::PROTOCOL : "The buffer is full: the unit being read exceeds its capacity"
*>
fn char[]? Buffer.tail(&self)
{
	self.compact();
	if (self.filled == self.capacity)
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "message exceeds %d bytes", self.capacity)~;
	}
	return self.data[self.filled:self.capacity - self.filled];
}

<* Record that `count` bytes were written into the `tail` slice. *>
fn void Buffer.commit(&self, usz count) @inline
{
	self.filled += count;
}

// Move the unread bytes to the front, so that `feed` has the whole free tail.
fn void Buffer.compact(&self)
{
	if (self.start == 0) return;
	usz pending = self.pending();
	for (usz i = 0; i < pending; i++) self.data[i] = self.data[self.start + i];
	self.scanned = self.scanned > self.start ? self.scanned - self.start : 0;
	self.start = 0;
	self.filled = pending;
}

<*
 Split `data` on ',' into at most `count` fields; the last field keeps any commas
 it contains. Hyprland event payloads are read this way: `title` may contain
 commas, and it is always the last field of its event.

 @param index : "Zero-based field to return"
 @require index < count : "The field must be one of the `count` fields"
 @return? NOT_FOUND : "The payload has fewer than `index + 1` fields"
*>
fn String? nth_field(String data, usz index, usz count)
{
	usz field = 0;
	usz start = 0;
	for (usz i = 0; i < data.len && field < count - 1; i++)
	{
		if (data[i] != ',') continue;
		if (field == index) return data[start:i - start];
		field++;
		start = i + 1;
	}
	if (field == index) return data[start:data.len - start];
	return NOT_FOUND~;
}

<*
 True when `text` is a non-empty run of ASCII digits, the only form niri and
 sway ids take in commands. Keeps a crafted id from adding command words.
*>
fn bool is_decimal(String text)
{
	if (text.len == 0) return false;
	foreach (c : text)
	{
		if (c < '0' || c > '9') return false;
	}
	return true;
}

<*
 True when `text` is non-empty and holds no whitespace, comma or control byte.
 Hyprland dispatch strings are split on spaces and commas, so ids with either
 would change the meaning of the command.
*>
fn bool is_token(String text)
{
	if (text.len == 0) return false;
	foreach (c : text)
	{
		if (c <= ' ' || c == ',' || c == 0x7f) return false;
	}
	return true;
}

<*
 True when `text` can be placed between double quotes in a sway command: no
 double quote, backslash or control byte.
*>
fn bool is_quotable(String text)
{
	foreach (c : text)
	{
		if (c == '"' || c == '\\' || c < ' ' || c == 0x7f) return false;
	}
	return true;
}