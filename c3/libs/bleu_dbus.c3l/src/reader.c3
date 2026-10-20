<*
 Reads marshalled values back, driven by the signature of the value.

 Every read checks, before touching a byte, that it stays inside the innermost
 container (an array's byte length, a struct's frame, the buffer itself). Every
 read of padding checks that the padding is NUL. Every string is checked for
 UTF-8 and its terminating NUL, and every object path and signature for its
 grammar. Malformed input returns `PROTOCOL`; the reader never reads outside
 `data`, whatever the bytes.

 Typical use:

     Reader r;
     r.init(body, "sa{sv}")!;
     String name = r.read_string()!;
     Value props = r.read_value(alloc)!;      // or read element by element
     r.finish()!;

 After a failed read the reader is in an undefined position: stop reading.
 Strings returned by the typed reads are slices of `data`; `read_value` copies
 everything it returns into its allocator.
*>
module bleu::dbus::marshal;
import bleu::error, bleu::dbus::signature, bleu::dbus::names, bleu::dbus::value;
import std::collections::list;

struct Reader
{
	String data;
	bool big_endian;
	usz pos;
	Frame[MAX_FRAMES] frames;
	uint depth;
}

<*
 Start reading `data`, which holds one value of `signature`. Offsets for
 alignment count from the first byte of `data`.

 @param data : "The bytes; alignment is relative to their first byte"
 @param signature : "A valid signature; must outlive the reader"
 @return? error::INVALID_ARGUMENT : "The signature is not valid"
*>
fn void? Reader.init(&self, String data, String signature, bool big_endian = false)
{
	if (!signature::valid(signature)) return error::INVALID_ARGUMENT~;
	self.data = data;
	self.big_endian = big_endian;
	self.pos = 0;
	self.frames[0] = { .kind = TOP, .sig = signature, .end = (usz)data.len };
	self.depth = 1;
}

<*
 True while the innermost level has another value: more of the signature for a
 struct or the top level, more bytes for an array.
*>
fn bool Reader.has_more(&self) @inline => more(self);

<* Byte offset of the next unread byte. *>
fn usz Reader.position(&self) @inline => self.pos;

<*
 Check that the whole value was read and nothing follows it.

 @return? error::INVALID_STATE : "Values are unread, or a container is still open"
 @return? error::PROTOCOL : "Bytes follow the last value"
*>
fn void? Reader.finish(&self)
{
	if (self.depth != 1 || self.frames[0].cursor != self.frames[0].sig.len) return error::INVALID_STATE~;
	if (self.pos != self.data.len) return malformed(self.pos, "trailing bytes")~;
}

<*
 The complete type of the next value, without reading it.

 @return? error::INVALID_STATE : "No value is left at this level"
*>
fn String? Reader.peek_type(&self)
{
	Frame* f = &self.frames[self.depth - 1];
	if (f.cursor >= f.sig.len) return error::INVALID_STATE~;
	usz end = signature::complete_end(f.sig, f.cursor)!;
	return f.sig[f.cursor:end];
}

<* BYTE (`y`). @return? error::PROTOCOL : "Truncated or misplaced data" *>
fn char? Reader.read_byte(&self)
{
	claim_read(self, "y")!;
	return (char)take(self, 1)!;
}

<* BOOLEAN (`b`). @return? error::PROTOCOL : "The value is neither 0 nor 1" *>
fn bool? Reader.read_bool(&self)
{
	claim_read(self, "b")!;
	align(self, signature::ALIGN_4)!;
	ulong v = take(self, 4)!;
	if (v > 1) return malformed(self.pos - 4, "boolean not 0 or 1")~;
	return v == 1;
}

<* INT16 (`n`). *>
fn short? Reader.read_i16(&self)
{
	claim_read(self, "n")!;
	align(self, signature::ALIGN_2)!;
	return (short)(ushort)take(self, 2)!;
}

<* UINT16 (`q`). *>
fn ushort? Reader.read_u16(&self)
{
	claim_read(self, "q")!;
	align(self, signature::ALIGN_2)!;
	return (ushort)take(self, 2)!;
}

<* INT32 (`i`). *>
fn int? Reader.read_i32(&self)
{
	claim_read(self, "i")!;
	align(self, signature::ALIGN_4)!;
	return (int)(uint)take(self, 4)!;
}

<* UINT32 (`u`). *>
fn uint? Reader.read_u32(&self)
{
	claim_read(self, "u")!;
	align(self, signature::ALIGN_4)!;
	return (uint)take(self, 4)!;
}

<* INT64 (`x`). *>
fn long? Reader.read_i64(&self)
{
	claim_read(self, "x")!;
	align(self, signature::ALIGN_8)!;
	return (long)take(self, 8)!;
}

<* UINT64 (`t`). *>
fn ulong? Reader.read_u64(&self)
{
	claim_read(self, "t")!;
	align(self, signature::ALIGN_8)!;
	return take(self, 8)!;
}

<* DOUBLE (`d`). *>
fn double? Reader.read_f64(&self)
{
	claim_read(self, "d")!;
	align(self, signature::ALIGN_8)!;
	return bitcast(take(self, 8)!, double);
}

<* UNIX_FD (`h`): the index into the message's descriptor array. *>
fn uint? Reader.read_unix_fd(&self)
{
	claim_read(self, "h")!;
	align(self, signature::ALIGN_4)!;
	return (uint)take(self, 4)!;
}

<*
 STRING (`s`), as a slice of the data.

 @return? error::PROTOCOL : "Not UTF-8, a NUL inside, a missing terminator, or truncated"
*>
fn String? Reader.read_string(&self) => read_text(self, "s", signature::ALIGN_4);

<*
 OBJECT_PATH (`o`), as a slice of the data.

 @return? error::PROTOCOL : "Not a valid object path, or truncated"
*>
fn String? Reader.read_object_path(&self) => read_text(self, "o", signature::ALIGN_4);

<*
 SIGNATURE (`g`), as a slice of the data.

 @return? error::PROTOCOL : "Not a valid signature, or truncated"
*>
fn String? Reader.read_signature(&self) => read_text(self, "g", signature::ALIGN_1);

<*
 Open the ARRAY next in line. Its elements are read with `has_more` and
 `read_*`, then `end_array` closes it.

 @return? error::INVALID_ARGUMENT : "The next value is not an array"
 @return? error::PROTOCOL : "The array length is over 2^26 bytes or runs past its container"
*>
fn void? Reader.begin_array(&self)
{
	String type = self.peek_type()!;
	if (type[0] != signature::ARRAY) return error::INVALID_ARGUMENT~;
	claim_read(self, type)!;
	align(self, signature::ALIGN_4)!;
	ulong length = take(self, 4)!;
	if (length > MAX_ARRAY_LENGTH) return malformed(self.pos - 4, "array longer than 2^26")~;
	String element = type[1:type.len];
	align(self, signature::alignment_of(element))!;
	if (length > limit(self) - self.pos) return malformed(self.pos, "array runs past its container")~;
	return push_read(self, ARRAY, element, self.pos + (usz)length);
}

<*
 Close the innermost array. Every byte of it must have been read.

 @return? error::INVALID_STATE : "The innermost container is not an array, or its bytes are unread"
*>
fn void? Reader.end_array(&self)
{
	Frame* f = top_read(self, ARRAY)!;
	if (self.pos != f.end) return error::INVALID_STATE~;
	self.depth--;
}

<*
 Open the STRUCT next in line.

 @return? error::INVALID_ARGUMENT : "The next value is not a struct"
*>
fn void? Reader.begin_struct(&self)
{
	String type = self.peek_type()!;
	if (type[0] != signature::STRUCT_OPEN) return error::INVALID_ARGUMENT~;
	claim_read(self, type)!;
	align(self, signature::ALIGN_8)!;
	return push_read(self, STRUCT, type[1:type.len - 1], limit(self));
}

<* Close the innermost struct; every field must have been read. *>
fn void? Reader.end_struct(&self)
{
	Frame* f = top_read(self, STRUCT)!;
	if (f.cursor != f.sig.len) return error::INVALID_STATE~;
	self.depth--;
}

<*
 Open the DICT_ENTRY next in line (an element of an array).

 @return? error::INVALID_ARGUMENT : "The next value is not a dict entry"
*>
fn void? Reader.begin_dict_entry(&self)
{
	String type = self.peek_type()!;
	if (type[0] != signature::DICT_OPEN) return error::INVALID_ARGUMENT~;
	claim_read(self, type)!;
	align(self, signature::ALIGN_8)!;
	return push_read(self, DICT_ENTRY, type[1:type.len - 1], limit(self));
}

<* Close the innermost dict entry; its key and value must have been read. *>
fn void? Reader.end_dict_entry(&self)
{
	Frame* f = top_read(self, DICT_ENTRY)!;
	if (f.cursor != f.sig.len) return error::INVALID_STATE~;
	self.depth--;
}

<*
 Open the VARIANT next in line. Its contents type is read from the variant's
 own signature and returned; read the contents, then `end_variant`.

 @return? error::INVALID_ARGUMENT : "The next value is not a variant"
 @return? error::PROTOCOL : "The contents signature is not a single complete type"
*>
fn String? Reader.begin_variant(&self)
{
	claim_read(self, "v")!;
	String contents = read_text_body(self, "g", signature::ALIGN_1)!;
	if (!signature::is_single(contents)) return malformed(self.pos, "variant signature is not a single type")~;
	push_read(self, VARIANT, contents, limit(self))!;
	return contents;
}

<* Close the innermost variant; its contents must have been read. *>
fn void? Reader.end_variant(&self)
{
	Frame* f = top_read(self, VARIANT)!;
	if (f.cursor != f.sig.len) return error::INVALID_STATE~;
	self.depth--;
}

<*
 Read the next value of any type into a `Value` tree, allocated from
 `allocator`. The result is independent of the reader's data.

 @return? error::PROTOCOL : "The data does not match the signature"
*>
fn Value? Reader.read_value(&self, Allocator allocator) => decode(self, true, allocator);

<* Advance past the next value of any type without building anything. *>
fn void? Reader.skip_value(&self)
{
	decode(self, false, mem)!;
}

// Reads the next value. With `keep` false it only validates and advances.
fn Value? decode(Reader* self, bool keep, Allocator allocator) @private
{
	String type = self.peek_type()!;
	Value v;
	switch (type[0])
	{
		case signature::BYTE: v = { .kind = BYTE, .bits = (ulong)self.read_byte()! };
		case signature::BOOLEAN: v = value::boolean(self.read_bool()!);
		case signature::INT16: v = value::i16(self.read_i16()!);
		case signature::UINT16: v = value::u16(self.read_u16()!);
		case signature::INT32: v = value::i32(self.read_i32()!);
		case signature::UINT32: v = value::u32(self.read_u32()!);
		case signature::INT64: v = value::i64(self.read_i64()!);
		case signature::UINT64: v = value::u64(self.read_u64()!);
		case signature::DOUBLE: v = value::float64(self.read_f64()!);
		case signature::UNIX_FD: v = value::unix_fd(self.read_unix_fd()!);
		case signature::STRING: v = { .kind = STRING, .sig = "s", .text = self.read_string()! };
		case signature::OBJECT_PATH: v = { .kind = OBJECT_PATH, .sig = "o", .text = self.read_object_path()! };
		case signature::SIGNATURE: v = { .kind = SIGNATURE, .sig = "g", .text = self.read_signature()! };
		case signature::ARRAY:
			self.begin_array()!;
			Value[] items = collect(self, keep, allocator)!;
			self.end_array()!;
			v = { .kind = ARRAY, .sig = type, .items = items };
		case signature::STRUCT_OPEN:
			self.begin_struct()!;
			Value[] fields = collect(self, keep, allocator)!;
			self.end_struct()!;
			v = { .kind = STRUCT, .sig = type, .items = fields };
		case signature::DICT_OPEN:
			self.begin_dict_entry()!;
			Value key = decode(self, keep, allocator)!;
			Value val = decode(self, keep, allocator)!;
			self.end_dict_entry()!;
			v = { .kind = DICT_ENTRY, .sig = type, .items = keep ? { key, val } : {} };
		case signature::VARIANT:
			self.begin_variant()!;
			Value inner = decode(self, keep, allocator)!;
			self.end_variant()!;
			v = { .kind = VARIANT, .sig = type, .items = keep ? { inner } : {} };
		default: return malformed(self.pos, "unknown type code")~;
	}
	if (keep)
	{
		v.sig = type.copy(allocator);
		if (v.text.len > 0 || v.kind == STRING || v.kind == OBJECT_PATH || v.kind == SIGNATURE)
		{
			v.text = v.text.copy(allocator);
		}
	}
	return v;
}

// Reads the elements of the innermost container. Without `keep` they are only
// skipped; with it they are copied out of temporary memory into `allocator`.
fn Value[]? collect(Reader* self, bool keep, Allocator allocator) @private
{
	if (!keep)
	{
		while (more(self)) decode(self, false, allocator)!;
		return {};
	}
	Value[] result;
	@pool()
	{
		List{Value} items;
		items.init(tmem);
		while (more(self)) items.push(decode(self, true, allocator)!);
		result = items.to_aligned_array(allocator);
	};
	return result;
}

// True while the innermost level has another value.
fn bool more(Reader* self) @private
{
	Frame* f = &self.frames[self.depth - 1];
	if (f.kind == ARRAY) return self.pos < f.end;
	return f.cursor < f.sig.len;
}

// The end of the innermost readable region.
fn usz limit(Reader* self) @private => self.frames[self.depth - 1].end;

// Consume `type` from the innermost level, which must expect it next.
fn void? claim_read(Reader* self, String type) @private
{
	Frame* f = &self.frames[self.depth - 1];
	if (f.cursor >= f.sig.len) return error::INVALID_STATE~;
	usz end = signature::complete_end(f.sig, f.cursor)!;
	if (f.sig[f.cursor:end] != type)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0,
			"reading type '%s' where '%s' is next", type, f.sig[f.cursor:end])~;
	}
	f.cursor = end;
	if (f.kind == ARRAY && f.cursor == f.sig.len) f.cursor = 0;
}

// The innermost open container, which must be of `kind`.
fn Frame*? top_read(Reader* self, FrameKind kind) @private
{
	Frame* f = &self.frames[self.depth - 1];
	if (f.kind != kind) return error::INVALID_STATE~;
	return f;
}

// Opens a level whose contents are `sig`, ending at `end`.
fn void? push_read(Reader* self, FrameKind kind, String sig, usz end) @private
{
	if (self.depth >= MAX_FRAMES) return malformed(self.pos, "containers nested too deeply")~;
	self.frames[self.depth] = { .kind = kind, .sig = sig, .end = end };
	self.depth++;
}

// Skips padding to `alignment`; the padding must be NUL and inside the container.
fn void? align(Reader* self, usz alignment) @private
{
	usz pad = padding_for(self.pos, alignment);
	if (pad > limit(self) - self.pos) return malformed(self.pos, "padding runs past its container")~;
	for (usz i = 0; i < pad; i++)
	{
		if (self.data[self.pos + i] != 0) return malformed(self.pos + i, "padding is not NUL")~;
	}
	self.pos += pad;
}

// Reads `n` bytes as an unsigned integer in the reader's byte order.
fn ulong? take(Reader* self, usz n) @private
{
	if (n > limit(self) - self.pos) return malformed(self.pos, "truncated value")~;
	ulong v = 0;
	for (usz i = 0; i < n; i++)
	{
		usz shift = self.big_endian ? (n - 1 - i) * 8 : i * 8;
		v |= (ulong)self.data[self.pos + i] << shift;
	}
	self.pos += n;
	return v;
}

// A string-like value: claim its type, align its length, read it.
fn String? read_text(Reader* self, String type, usz length_bytes) @private
{
	claim_read(self, type)!;
	return read_text_body(self, type, length_bytes);
}

// The length, text and terminating NUL of a string-like value, validated.
fn String? read_text_body(Reader* self, String type, usz length_bytes) @private
{
	align(self, length_bytes)!;
	usz n = (usz)take(self, length_bytes)!;
	usz remaining = limit(self) - self.pos;
	if (n >= remaining) return malformed(self.pos, "text runs past its container")~;
	String text = self.data[self.pos:self.pos + n];
	if (self.data[self.pos + n] != 0) return malformed(self.pos + n, "text is not NUL-terminated")~;
	self.pos += n + 1;
	bool ok;
	switch (type[0])
	{
		case signature::STRING: ok = names::is_utf8_text(text);
		case signature::OBJECT_PATH: ok = names::is_object_path(text);
		default: ok = signature::valid(text);
	}
	if (!ok) return malformed(self.pos, "invalid text for its type")~;
	return text;
}

// PROTOCOL error describing malformed data at `at`.
fn fault malformed(usz at, String what) @private
{
	return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "malformed D-Bus data at byte %d: %s", (long)at, what);
}
