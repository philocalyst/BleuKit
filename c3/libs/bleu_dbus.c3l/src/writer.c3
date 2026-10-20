<*
 Builds the marshalled form of values, checking every append against the
 signature it was given.

 A `Writer` is created for one signature. Each `append_*` call must supply the
 next complete type of that signature, in order, and each container must be
 opened and closed in the order the signature nests them. A mismatch returns
 `INVALID_ARGUMENT` and writes nothing, so a message can never be emitted with
 bytes that disagree with its signature.

     Writer w;
     w.init(alloc, "sa{sv}")!;
     defer w.free();
     w.append_string("Name")!;
     w.begin_array("a{sv}")!;
     ...
     w.end_array()!;
     w.finish()!;
     String bytes = w.bytes();

 The signature string must outlive the writer; literals and signatures copied
 into an arena are safe.
*>
module bleu::dbus::marshal;
import bleu::error, bleu::dbus::signature, bleu::dbus::names, bleu::dbus::value;

struct Writer
{
	DString buffer;
	bool big_endian;
	String signature;
	Frame[MAX_FRAMES] frames;
	uint depth;
}

<*
 Start a marshalled value of `signature`.

 @param [&inout] allocator : "Allocator for the bytes; the writer grows its buffer from it"
 @param signature : "A valid signature for the value; must outlive the writer"
 @return? error::INVALID_ARGUMENT : "The signature is not valid"
*>
fn void? Writer.init(&self, Allocator allocator, String signature, bool big_endian = false)
{
	if (!signature::valid(signature)) return error::INVALID_ARGUMENT~;
	self.buffer.init(allocator);
	self.big_endian = big_endian;
	self.signature = signature;
	self.frames[0] = { .kind = TOP, .sig = signature };
	self.depth = 1;
}

<* Release the buffer. The writer must not be used afterwards. *>
fn void Writer.free(&self) => self.buffer.free();

<* The bytes written so far. Valid until the next append or until `free`. *>
fn String Writer.bytes(&self) @inline => self.buffer.str_view();

<* Number of bytes written so far. *>
fn usz Writer.size(&self) @inline => self.buffer.len();

<*
 Check that the whole signature has been written and no container is open.

 @return? error::INVALID_STATE : "Values are missing, or a container is still open"
*>
fn void? Writer.finish(&self)
{
	Frame* top = &self.frames[0];
	if (self.depth != 1 || top.cursor != self.signature.len) return error::INVALID_STATE~;
}

<* Pad the buffer with NUL bytes up to a multiple of `alignment`. *>
fn void Writer.align(&self, usz alignment)
{
	usz pad = padding_for(self.buffer.len(), alignment);
	for (usz i = 0; i < pad; i++) self.buffer.append_char(0);
}

<* BYTE (`y`). *>
fn void? Writer.append_byte(&self, char v)
{
	claim(self, "y")!;
	self.buffer.append_char(v);
}

<* BOOLEAN (`b`): a UINT32 holding 0 or 1. *>
fn void? Writer.append_bool(&self, bool v)
{
	claim(self, "b")!;
	put_fixed(self, v ? 1 : 0, 4);
}

<* INT16 (`n`). *>
fn void? Writer.append_i16(&self, short v)
{
	claim(self, "n")!;
	put_fixed(self, (ulong)(long)v, 2);
}

<* UINT16 (`q`). *>
fn void? Writer.append_u16(&self, ushort v)
{
	claim(self, "q")!;
	put_fixed(self, v, 2);
}

<* INT32 (`i`). *>
fn void? Writer.append_i32(&self, int v)
{
	claim(self, "i")!;
	put_fixed(self, (ulong)(long)v, 4);
}

<* UINT32 (`u`). *>
fn void? Writer.append_u32(&self, uint v)
{
	claim(self, "u")!;
	put_fixed(self, v, 4);
}

<* INT64 (`x`). *>
fn void? Writer.append_i64(&self, long v)
{
	claim(self, "x")!;
	put_fixed(self, (ulong)v, 8);
}

<* UINT64 (`t`). *>
fn void? Writer.append_u64(&self, ulong v)
{
	claim(self, "t")!;
	put_fixed(self, v, 8);
}

<* DOUBLE (`d`), IEEE 754 binary64. *>
fn void? Writer.append_f64(&self, double v)
{
	claim(self, "d")!;
	put_fixed(self, bitcast(v, ulong), 8);
}

<*
 UNIX_FD (`h`): an index into the descriptor array that travels with the message.

 @param index : "Position of the descriptor in the message's descriptor array"
*>
fn void? Writer.append_unix_fd(&self, uint index)
{
	claim(self, "h")!;
	put_fixed(self, index, 4);
}

<*
 STRING (`s`): valid UTF-8 without NUL.

 @return? error::INVALID_ARGUMENT : "The text is not valid string data, or the type does not match"
*>
fn void? Writer.append_string(&self, String text)
{
	if (!names::is_utf8_text(text)) return error::INVALID_ARGUMENT~;
	claim(self, "s")!;
	put_text(self, text, 4);
}

<*
 OBJECT_PATH (`o`).

 @return? error::INVALID_ARGUMENT : "The text is not a valid object path, or the type does not match"
*>
fn void? Writer.append_object_path(&self, String path)
{
	if (!names::is_object_path(path)) return error::INVALID_ARGUMENT~;
	claim(self, "o")!;
	put_text(self, path, 4);
}

<*
 SIGNATURE (`g`): a valid signature of at most 255 bytes.

 @return? error::INVALID_ARGUMENT : "The text is not a valid signature, or the type does not match"
*>
fn void? Writer.append_signature(&self, String sig)
{
	if (!signature::valid(sig)) return error::INVALID_ARGUMENT~;
	claim(self, "g")!;
	put_text(self, sig, 1);
}

<*
 Open an ARRAY whose full type is `array_sig` (for example "a{sv}" or "as").
 Its elements follow, then `end_array`.

 @param array_sig : "The complete array type, starting with 'a'"
 @return? error::INVALID_ARGUMENT : "The type does not match the expected type"
*>
fn void? Writer.begin_array(&self, String array_sig)
{
	if (!signature::is_single(array_sig) || array_sig[0] != signature::ARRAY) return error::INVALID_ARGUMENT~;
	claim(self, array_sig)!;
	put_fixed(self, 0, 4);
	usz length_at = self.buffer.len() - 4;
	String element = array_sig[1:array_sig.len];
	self.align(signature::alignment_of(element));
	push(self, ARRAY, element, length_at, self.buffer.len())!;
}

<*
 Close the innermost array and fill in its length.

 @return? error::INVALID_STATE : "The innermost open container is not an array"
 @return? error::INVALID_ARGUMENT : "The elements take more than 2^26 bytes"
*>
fn void? Writer.end_array(&self)
{
	Frame* f = top(self, ARRAY)!;
	usz length = self.buffer.len() - f.data_at;
	if (length > MAX_ARRAY_LENGTH) return error::INVALID_ARGUMENT~;
	patch_fixed(self, f.length_at, length, 4);
	self.depth--;
}

<*
 Open a STRUCT. The expected type must be a struct; its fields follow.

 @return? error::INVALID_ARGUMENT : "The expected type is not a struct"
*>
fn void? Writer.begin_struct(&self)
{
	String type = expected_type(self, signature::STRUCT_OPEN)!;
	claim(self, type)!;
	self.align(signature::ALIGN_8);
	push(self, STRUCT, type[1:type.len - 1], 0, 0)!;
}

<* Close the innermost struct; every field must have been written. *>
fn void? Writer.end_struct(&self)
{
	Frame* f = top(self, STRUCT)!;
	if (f.cursor != f.sig.len) return error::INVALID_STATE~;
	self.depth--;
}

<*
 Open a DICT_ENTRY (`{key value}`). It must be the element of an array, and the
 expected type must be a dict entry.

 @return? error::INVALID_ARGUMENT : "The expected type is not a dict entry"
*>
fn void? Writer.begin_dict_entry(&self)
{
	String type = expected_type(self, signature::DICT_OPEN)!;
	claim(self, type)!;
	self.align(signature::ALIGN_8);
	push(self, DICT_ENTRY, type[1:type.len - 1], 0, 0)!;
}

<* Close the innermost dict entry; both its key and value must have been written. *>
fn void? Writer.end_dict_entry(&self)
{
	Frame* f = top(self, DICT_ENTRY)!;
	if (f.cursor != f.sig.len) return error::INVALID_STATE~;
	self.depth--;
}

<*
 Open a VARIANT whose contents have type `contents_sig`. Write the contents,
 then `end_variant`.

 @param contents_sig : "A single complete type"
 @return? error::INVALID_ARGUMENT : "The contents type is not a single complete type, or the expected type is not a variant"
*>
fn void? Writer.begin_variant(&self, String contents_sig)
{
	if (!signature::is_single(contents_sig)) return error::INVALID_ARGUMENT~;
	claim(self, "v")!;
	self.buffer.append_char((char)contents_sig.len);
	self.buffer.append_string(contents_sig);
	self.buffer.append_char(0);
	push(self, VARIANT, contents_sig, 0, 0)!;
}

<* Close the innermost variant; its contents must have been written. *>
fn void? Writer.end_variant(&self)
{
	Frame* f = top(self, VARIANT)!;
	if (f.cursor != f.sig.len) return error::INVALID_STATE~;
	self.depth--;
}

<*
 Write any value, recursively. Its signature must be the next type expected.

 @return? error::INVALID_ARGUMENT : "The value's type does not match the expected type"
*>
fn void? Writer.append_value(&self, Value v)
{
	switch (v.kind)
	{
		case BYTE: return self.append_byte((char)v.bits);
		case BOOLEAN: return self.append_bool(v.bits != 0);
		case INT16: return self.append_i16((short)(long)v.bits);
		case UINT16: return self.append_u16((ushort)v.bits);
		case INT32: return self.append_i32((int)(long)v.bits);
		case UINT32: return self.append_u32((uint)v.bits);
		case INT64: return self.append_i64((long)v.bits);
		case UINT64: return self.append_u64(v.bits);
		case DOUBLE: return self.append_f64(bitcast(v.bits, double));
		case UNIX_FD: return self.append_unix_fd((uint)v.bits);
		case STRING: return self.append_string(v.text);
		case OBJECT_PATH: return self.append_object_path(v.text);
		case SIGNATURE: return self.append_signature(v.text);
		case ARRAY:
			self.begin_array(v.sig)!;
			foreach (item : v.items) self.append_value(item)!;
			return self.end_array();
		case STRUCT:
			self.begin_struct()!;
			foreach (field : v.items) self.append_value(field)!;
			return self.end_struct();
		case DICT_ENTRY:
			self.begin_dict_entry()!;
			self.append_value(v.items[0])!;
			self.append_value(v.items[1])!;
			return self.end_dict_entry();
		case VARIANT:
			self.begin_variant(v.items[0].sig)!;
			self.append_value(v.items[0])!;
			return self.end_variant();
	}
}

// Pushes a container frame. The caller has already aligned the contents.
fn void? push(Writer* self, FrameKind kind, String sig, usz length_at, usz data_at) @private
{
	if (self.depth >= MAX_FRAMES) return error::INVALID_ARGUMENT~;
	self.frames[self.depth] = { .kind = kind, .sig = sig, .length_at = length_at, .data_at = data_at };
	self.depth++;
}

// The innermost open container, which must be of `kind`.
fn Frame*? top(Writer* self, FrameKind kind) @private
{
	Frame* f = &self.frames[self.depth - 1];
	if (f.kind != kind) return error::INVALID_STATE~;
	return f;
}

// The complete type the innermost level expects next, which must start with `code`.
fn String? expected_type(Writer* self, char code) @private
{
	Frame* f = &self.frames[self.depth - 1];
	if (f.cursor >= f.sig.len || f.sig[f.cursor] != code) return error::INVALID_ARGUMENT~;
	usz end = signature::complete_end(f.sig, f.cursor)!;
	return f.sig[f.cursor:end];
}

// Consume `type` from the innermost level, which must expect it next. Aligns
// nothing: the caller pads first.
fn void? claim(Writer* w, String type) @private
{
	Frame* f = &w.frames[w.depth - 1];
	if (f.cursor >= f.sig.len) return error::INVALID_STATE~;
	usz end = signature::complete_end(f.sig, f.cursor)!;
	if (f.sig[f.cursor:end] != type)
	{
		return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0,
			"expected type '%s', got '%s'", f.sig[f.cursor:end], type)~;
	}
	f.cursor = end;
	if (f.kind == ARRAY && f.cursor == f.sig.len) f.cursor = 0;
}

// Append `n` bytes of `v` in the writer's byte order, after aligning to `n`.
fn void put_fixed(Writer* self, ulong v, usz n) @private
{
	self.align(n);
	write_bytes(self, v, n);
}

// Overwrite `n` bytes already written at `at` with `v` (used for array lengths).
fn void patch_fixed(Writer* self, usz at, ulong v, usz n) @private
{
	for (usz i = 0; i < n; i++)
	{
		usz shift = self.big_endian ? (n - 1 - i) * 8 : i * 8;
		self.buffer.set(at + i, (char)(v >> shift));
	}
}

// Append `v` as `n` bytes in the writer's byte order, with no alignment.
fn void write_bytes(Writer* self, ulong v, usz n) @private
{
	for (usz i = 0; i < n; i++)
	{
		usz shift = self.big_endian ? (n - 1 - i) * 8 : i * 8;
		self.buffer.append_char((char)(v >> shift));
	}
}

// Append a length-prefixed NUL-terminated text. `length_bytes` is 4 for STRING
// and OBJECT_PATH, 1 for SIGNATURE.
fn void put_text(Writer* self, String text, usz length_bytes) @private
{
	self.align(length_bytes);
	write_bytes(self, text.len, length_bytes);
	self.buffer.append_string(text);
	self.buffer.append_char(0);
}
