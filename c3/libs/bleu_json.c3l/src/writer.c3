<*
 Streaming JSON writer: the output side of Bleu's wire format.

 A `JsonWriter` produces RFC 8259 text one token at a time, into a `DString` or
 into a caller-owned byte buffer. It never builds a tree and allocates nothing
 for ordinary values. Every call checks where it stands in the document: a key
 outside an object, a second top-level value, a close that does not match its
 open, a document left unfinished are all refused with `error::INVALID_STATE`
 at the offending call, so the writer cannot emit text that is not JSON.

 Once a call fails the writer is poisoned only when the failure was a full
 buffer; structural misuse leaves the writer unchanged, so the caller may
 correct the call and continue.
*>
module bleu::json;
import bleu::error;

<* Deepest container nesting the writer accepts. *>
const usz MAX_DEPTH = 64;

<* One open container. `key_open` is set between a `key` and the value it names. *>
struct Frame
{
	bool is_object;
	bool has_items;
	bool key_open;
}

<*
 A streaming JSON writer. Initialise it with `init_dstring` or `init_buffer`,
 write exactly one JSON value, then call `finish`.

 `indent` is the number of spaces per nesting level; 0 writes the compact form.
*>
struct JsonWriter
{
	DString* target; // when set, the output is appended here
	char[] buffer; // otherwise the output is written here from index 0
	sz used; // bytes written into `buffer`
	int indent;
	int depth; // containers currently open
	bool top_done; // one complete top-level value has been written
	bool failed; // a write ran out of buffer space; the output is no longer usable
	Frame[MAX_DEPTH] frames;
}

<* Largest accepted indentation, in spaces per nesting level. *>
const int MAX_INDENT = 8;

<*
 Start a writer that appends to `target`. The caller owns `target` and must
 keep it alive while the writer is in use.

 @param target : "Where the output is appended"
 @param indent : "Spaces per nesting level, 0 for compact output"
 @require indent >= 0 && indent <= MAX_INDENT : "Indentation must be 0 to 8 spaces"
*>
fn void JsonWriter.init_dstring(&self, DString* target, int indent = 0)
{
	*self = { .target = target, .indent = indent };
}

<*
 Start a writer that writes into `buffer` from index 0. A write that does not
 fit fails with `error::OUT_OF_RANGE` and poisons the writer.

 @param buffer : "Caller-owned storage for the output"
 @param indent : "Spaces per nesting level, 0 for compact output"
 @require indent >= 0 && indent <= MAX_INDENT : "Indentation must be 0 to 8 spaces"
*>
fn void JsonWriter.init_buffer(&self, char[] buffer, int indent = 0)
{
	*self = { .buffer = buffer, .indent = indent };
}

<* The output written so far. Valid until the writer is written to again. *>
fn String JsonWriter.written(&self)
{
	if (self.target) return self.target.str_view();
	return (String)self.buffer[0:self.used];
}

<* True when exactly one complete value has been written and no container is open. *>
fn bool JsonWriter.is_complete(&self) @inline => self.top_done && self.depth == 0;

<*
 Check that the document is complete: one value written, every container
 closed.

 @return? error::INVALID_STATE : "No value was written, or a container is still open"
*>
fn void? JsonWriter.finish(&self)
{
	if (self.depth > 0) return misuse("a container is still open")~;
	if (!self.top_done) return misuse("no value was written")~;
}

<* Refusal of a call that does not fit the document so far. *>
fn fault misuse(String what) @inline
{
	return error::raise(error::INVALID_STATE, error::Domain.INTERNAL, 0, "json writer: %s", what);
}

<* Refuse further writes once a buffer has overflowed. *>
fn void? JsonWriter.ready(&self)
{
	if (self.failed) return misuse("an earlier write ran out of buffer space")~;
}

<*
 Append raw bytes to the output. A full fixed buffer is reported and poisons the writer.

 @require text.len >= 0 : "A string has a length"
*>
fn void? JsonWriter.emit(&self, String text)
{
	if (text.len == 0) return;
	if (self.target)
	{
		self.target.append_string(text);
		return;
	}
	if (text.len > self.buffer.len - self.used)
	{
		self.failed = true;
		return error::raise(error::OUT_OF_RANGE, error::Domain.INTERNAL, 0, "json buffer of %d bytes is full", self.buffer.len)~;
	}
	mem::copy(&self.buffer[self.used], text.ptr, text.len);
	self.used += text.len;
}

<* Append one byte to the output. Same overflow rule as `emit`. *>
fn void? JsonWriter.emit_char(&self, char c)
{
	if (self.target)
	{
		self.target.append_char(c);
		return;
	}
	if (self.used >= self.buffer.len)
	{
		self.failed = true;
		return error::raise(error::OUT_OF_RANGE, error::Domain.INTERNAL, 0, "json buffer of %d bytes is full", self.buffer.len)~;
	}
	self.buffer[self.used] = c;
	self.used++;
}

<*
 Start a new line and indent to `level` when the writer is indenting. Compact
 writers emit nothing.
*>
fn void? JsonWriter.newline(&self, int level)
{
	if (self.indent == 0) return;
	self.emit("\n")!;
	for (int i = 0; i < level * self.indent; i++)
	{
		self.emit_char(' ')!;
	}
}

<*
 Account for the start of a value. Inside an object the value must follow its
 key; inside an array it is separated from its predecessor; at the top level it
 may be the only value.
*>
fn void? JsonWriter.begin_value(&self)
{
	self.ready()!;
	if (self.depth == 0)
	{
		if (self.top_done) return misuse("a second top-level value")~;
		return;
	}
	Frame* frame = &self.frames[self.depth - 1];
	if (frame.is_object)
	{
		if (!frame.key_open) return misuse("a value inside an object needs a key first")~;
		frame.key_open = false;
		return;
	}
	if (frame.has_items) self.emit(",")!;
	frame.has_items = true;
	self.newline(self.depth)!;
}

<* Account for the end of a value: a top-level value completes the document. *>
fn void JsonWriter.end_value(&self)
{
	if (self.depth == 0) self.top_done = true;
}

<* Write a token that needs no escaping (numbers, `true`, `null`) as one value. *>
fn void? JsonWriter.put_token(&self, String token)
{
	self.begin_value()!;
	self.emit(token)!;
	self.end_value();
}

<* Write `null`. *>
fn void? JsonWriter.put_null(&self) => self.put_token("null");

<* Write `true` or `false`. *>
fn void? JsonWriter.put_bool(&self, bool value) => self.put_token(value ? "true" : "false");

<*
 Open a container of the given kind as a value.

 @return? error::OUT_OF_RANGE : "The document is nested deeper than MAX_DEPTH"
*>
fn void? open_container(JsonWriter* writer, bool is_object)
{
	writer.ready()!;
	if (writer.depth == (int)MAX_DEPTH) return error::raise(error::OUT_OF_RANGE, error::Domain.INTERNAL, 0, "json nesting deeper than %d", (int)MAX_DEPTH)~;
	writer.begin_value()!;
	writer.emit(is_object ? "{" : "[")!;
	writer.frames[writer.depth] = { .is_object = is_object };
	writer.depth++;
}

<* Close the innermost container, which must be of the given kind and not await a value. *>
fn void? close_container(JsonWriter* writer, bool is_object)
{
	writer.ready()!;
	if (writer.depth == 0) return misuse("no container is open")~;
	Frame* frame = &writer.frames[writer.depth - 1];
	if (frame.is_object != is_object) return misuse(is_object ? "end_object closes an array" : "end_array closes an object")~;
	if (frame.key_open) return misuse("a key has no value")~;
	writer.depth--;
	if (frame.has_items) writer.newline(writer.depth)!;
	writer.emit(is_object ? "}" : "]")!;
	writer.end_value();
}

<* Open an object as the next value. *>
fn void? JsonWriter.begin_object(&self) => open_container(self, true);

<* Close the innermost object. *>
fn void? JsonWriter.end_object(&self) => close_container(self, true);

<* Open an array as the next value. *>
fn void? JsonWriter.begin_array(&self) => open_container(self, false);

<* Close the innermost array. *>
fn void? JsonWriter.end_array(&self) => close_container(self, false);

<*
 Write the name of the next member of the innermost object. The next call
 must write that member's value. Names are written as given: this writer does
 not check that a name is unique.

 @param name : "The member name, any UTF-8 text"
 @return? error::INVALID_STATE : "Not inside an object, or the previous key has no value yet"
*>
fn void? JsonWriter.key(&self, String name)
{
	self.ready()!;
	if (self.depth == 0 || !self.frames[self.depth - 1].is_object) return misuse("a key is only allowed inside an object")~;
	Frame* frame = &self.frames[self.depth - 1];
	if (frame.key_open) return misuse("a key follows a key with no value")~;
	if (frame.has_items) self.emit(",")!;
	frame.has_items = true;
	self.newline(self.depth)!;
	self.emit_quoted(name)!;
	self.emit(self.indent > 0 ? ": " : ":")!;
	frame.key_open = true;
}
