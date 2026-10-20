<*
 Binary property lists (`bplist00`): the reader.

 Source: Apple CoreFoundation, `CFBinaryPList.c` (https://github.com/apple-oss-distributions/CF):
 `__CFBinaryPlistGetTopLevelInfo` (the trailer and offset-table rules), the marker
 table in `__CFBinaryPlistCreateObjectFiltered` (integers of 1, 2 and 4 bytes are
 unsigned, 8 bytes signed; reals of 4 or 8 bytes; the date marker 0x33; the
 extended length form that follows a 0xF length nibble). Cross-checked against
 Python's `plistlib` (the golden fixtures) and the "Binary Property List" notes in
 the Apple open-source sources.

 Layout: `bplist0?` header, objects, a table of 8-byte-or-smaller object offsets,
 and a 32-byte trailer. The trailer holds, in big-endian order: five unused
 bytes, a sort version, the offset width, the reference width, the object count,
 the index of the top object, and the offset of the table.

 Refused, never followed: a file whose length does not match its trailer exactly,
 an offset or reference outside the file or the object region, a reference to the
 object itself, nesting deeper than `value::MAX_NESTING`, and more than
 `MAX_DECODED_VALUES` values in one document (a dictionary may share its values,
 so an unbounded reader could be made to build exponentially many). Integers wider
 than 64 bits are refused when they do not sign-extend; Apple truncates them.

 Not done: the writer (the XML writer covers output). Sets (0xC0) are read as
 arrays in stored order, since the value model has no set.
*>
module bleu::plist::binary;
import bleu::error, bleu::plist::value, bleu::plist::text, std::collections::list, std::collections::set, std::math;

const String MAGIC_PREFIX = "bplist0";
const usz MAGIC_LENGTH = 8;
const usz TRAILER_LENGTH = 32;
const usz TRAILER_OFFSET_SIZE = 6;
const usz TRAILER_REF_SIZE = 7;
const usz TRAILER_OBJECT_COUNT = 8;
const usz TRAILER_TOP_OBJECT = 16;
const usz TRAILER_TABLE_OFFSET = 24;
const usz WORD_BYTES = 8;
const usz MAX_INTEGER_BYTES = 16;
const usz MAX_ID_BYTES = 8;
const usz MAX_OBJECTS = 1 << 28;
const usz MAX_DECODED_VALUES = 1 << 20;
const uint TYPE_MASK = 0xF0;
const uint LENGTH_MASK = 0x0F;
const uint EXTENDED_LENGTH = 0x0F;
const uint MARKER_FALSE = 0x08;
const uint MARKER_TRUE = 0x09;
const uint TYPE_NULL_FILL = 0x00;
const uint TYPE_INTEGER = 0x10;
const uint TYPE_REAL = 0x20;
const uint TYPE_DATE = 0x30;
const uint TYPE_DATA = 0x40;
const uint TYPE_ASCII = 0x50;
const uint TYPE_UTF16 = 0x60;
const uint TYPE_UID = 0x80;
const uint TYPE_ARRAY = 0xA0;
const uint TYPE_SET = 0xC0;
const uint TYPE_DICT = 0xD0;
const uint REAL_FLOAT_LOG2 = 2;
const uint REAL_DOUBLE_LOG2 = 3;
const uint DATE_LOG2 = 3;
const uint LARGEST_INTEGER_LOG2 = 4;
const uint ASCII_LIMIT = 0x80;
const ulong SIGN_EXTENSION = 0xFFFFFFFFFFFFFFFF;

<*
 Decode a binary property list.

 @param [&inout] allocator : "Allocator for the value tree"
 @param data : "The complete file, starting with `bplist0`"
 @return? error::PROTOCOL : "The trailer, offsets or an object are malformed, or the file is nested or holds more values than the readers accept"
 @return? error::OUT_OF_RANGE : "An integer does not fit in 64 bits, or the document holds too many values"
*>
fn Value? parse(Allocator allocator, char[] data)
{
	if (data.len < MAGIC_LENGTH + TRAILER_LENGTH + 1 || (String)data[0:MAGIC_PREFIX.len] != MAGIC_PREFIX)
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "not a binary property list")~;
	}
	Parser parser = trailer_parser(allocator, data)!;
	usz top = parser.offset_index(parser.top_object)!;
	return parser.object(top, 0)!;
}

// A refusal of the trailer, with the reason.
fn fault bad_trailer(String reason) @local => error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "malformed trailer: %s", reason);

// The fields of the trailer, checked the way CoreFoundation checks them.
struct Parser
{
	Allocator allocator;
	char[] data;
	usz object_count;
	usz top_object;
	usz table_offset;
	usz offset_size;
	usz ref_size;
	usz decoded;
}

// Read and validate the trailer and offset table of `data`.
fn Parser? trailer_parser(Allocator allocator, char[] data) @local
{
	usz trailer_at = data.len - TRAILER_LENGTH;
	usz object_count = read_word(data, trailer_at + TRAILER_OBJECT_COUNT);
	usz top_object = read_word(data, trailer_at + TRAILER_TOP_OBJECT);
	usz table_offset = read_word(data, trailer_at + TRAILER_TABLE_OFFSET);
	usz offset_size = (usz)(data[trailer_at + TRAILER_OFFSET_SIZE] & 0xFF);
	usz ref_size = (usz)(data[trailer_at + TRAILER_REF_SIZE] & 0xFF);
	if (object_count < 1 || object_count > MAX_OBJECTS) return error::raise(error::OUT_OF_RANGE, error::Domain.INTERNAL, 0, "object count %d is out of range", object_count)~;
	if (top_object >= object_count) return bad_trailer("the top object is not an object")~;
	if (table_offset < MAGIC_LENGTH + 1 || table_offset > trailer_at) return bad_trailer("the offset table is outside the file")~;
	if (offset_size < 1 || offset_size > MAX_ID_BYTES || ref_size < 1 || ref_size > MAX_ID_BYTES) return bad_trailer("offset or reference width is invalid")~;
	usz table_size = object_count * offset_size;
	if (table_offset + table_size != trailer_at) return bad_trailer("the file length does not match its trailer")~;
	if (ref_size < WORD_BYTES && ((ulong)1 << (8 * ref_size)) <= object_count) return bad_trailer("references are too narrow for the object count")~;
	if (offset_size < WORD_BYTES && ((ulong)1 << (8 * offset_size)) <= table_offset) return bad_trailer("offsets are too narrow for the offset table")~;
	Parser parser = { .allocator = allocator, .data = data, .object_count = object_count, .top_object = top_object, .table_offset = table_offset, .offset_size = offset_size, .ref_size = ref_size };
	for (usz index = 0; index < object_count; index++) parser.offset_index(index)!;
	return parser;
}

fn Value? Parser.object(&self, usz index, int depth)
{
	if (depth > value::MAX_NESTING) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "values are nested deeper than %d", value::MAX_NESTING)~;
	if (self.decoded >= MAX_DECODED_VALUES) return error::raise(error::OUT_OF_RANGE, error::Domain.INTERNAL, 0, "more than %d values in one document", MAX_DECODED_VALUES)~;
	self.decoded++;
	usz at = self.offset_index(index)!;
	uint marker = (uint)(self.data[at] & 0xFF);
	uint type = marker & TYPE_MASK;
	uint low = marker & LENGTH_MASK;
	switch (type)
	{
		case TYPE_NULL_FILL:
			if (marker == MARKER_FALSE) return { .kind = BOOL, .boolean = false };
			if (marker == MARKER_TRUE) return { .kind = BOOL, .boolean = true };
			return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "marker 0x%02X is not a value", marker)~;
		case TYPE_INTEGER:
			return { .kind = INTEGER, .integer = self.integer_at(at, low)! };
		case TYPE_REAL:
			return { .kind = REAL, .real = self.real_at(at, low)! };
		case TYPE_DATE:
			if (low != DATE_LOG2) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "date has width %d", low)~;
			return { .kind = DATE, .date = self.real_bits(at + 1, WORD_BYTES)! };
		case TYPE_DATA:
			usz data_start = at + 1;
			usz data_length = self.length_at(&data_start, low)!;
			return { .kind = DATA, .bytes = self.copy_bytes(data_start, data_length)! };
		case TYPE_ASCII:
			usz text_start = at + 1;
			usz text_length = self.length_at(&text_start, low)!;
			return { .kind = STRING, .text = self.ascii(text_start, text_length)! };
		case TYPE_UTF16:
			usz wide_start = at + 1;
			usz unit_count = self.length_at(&wide_start, low)!;
			return { .kind = STRING, .text = self.utf16(wide_start, unit_count)! };
		case TYPE_UID:
			return { .kind = UID, .integer = (long)self.unsigned_at(at + 1, (usz)low + 1, MAX_ID_BYTES)! };
		case TYPE_ARRAY:
		case TYPE_SET:
			usz array_start = at + 1;
			usz count = self.length_at(&array_start, low)!;
			return { .kind = ARRAY, .items = self.items(array_start, count, index, depth)! };
		case TYPE_DICT:
			usz dict_start = at + 1;
			usz pairs = self.length_at(&dict_start, low)!;
			return self.dictionary(dict_start, pairs, index, depth);
		default:
			return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "unknown object marker 0x%02X", marker)~;
	}
}

// The integer of an 0x1n object: 1, 2, 4, 8 or 16 bytes big-endian.
fn long? Parser.integer_at(&self, usz at, uint low)
{
	if (low > LARGEST_INTEGER_LOG2) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "integer of width 2^%d", low)~;
	usz size = (usz)1 << (usz)low;
	if (size <= WORD_BYTES) return (long)self.unsigned_at(at + 1, size, WORD_BYTES)!;
	ulong high = self.unsigned_at(at + 1, WORD_BYTES, WORD_BYTES)!;
	ulong low_word = self.unsigned_at(at + 1 + WORD_BYTES, WORD_BYTES, WORD_BYTES)!;
	bool fits = (high == 0 && (long)low_word >= 0) || (high == SIGN_EXTENSION && (long)low_word < 0);
	if (!fits) return error::raise(error::OUT_OF_RANGE, error::Domain.INTERNAL, 0, "integer does not fit in 64 bits")~;
	return (long)low_word;
}

// The real of an 0x2n object: 4 bytes (float) or 8 bytes (double).
fn double? Parser.real_at(&self, usz at, uint low)
{
	if (low == REAL_FLOAT_LOG2)
	{
		uint bits = (uint)self.unsigned_at(at + 1, 4, 4)!;
		return (double)bitcast(bits, float);
	}
	if (low == REAL_DOUBLE_LOG2) return self.real_bits(at + 1, WORD_BYTES)!;
	return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "real of width 2^%d", low)~;
}

// An 8-byte big-endian IEEE double at `at`.
fn double? Parser.real_bits(&self, usz at, usz size)
{
	ulong bits = self.unsigned_at(at, size, WORD_BYTES)!;
	return bitcast(bits, double);
}

// A length: the nibble itself, or, when it is 0xF, the integer object that follows (advancing `*position`).
fn usz? Parser.length_at(&self, usz* position, uint low)
{
	if (low != EXTENDED_LENGTH) return (usz)low;
	uint marker = (uint)(self.data[self.checked(*position, 1)!] & 0xFF);
	if ((marker & TYPE_MASK) != TYPE_INTEGER) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "extended length is not an integer")~;
	uint width = marker & LENGTH_MASK;
	if (width > REAL_DOUBLE_LOG2) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "extended length of width 2^%d", width)~;
	usz size = (usz)1 << width;
	ulong length = self.unsigned_at(*position + 1, size, MAX_ID_BYTES)!;
	*position += 1 + size;
	if (length > self.table_offset) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "length %d runs past the object region", length)~;
	return (usz)length;
}

// Copy `length` bytes of the object region at `start` into `allocator`.
fn char[]? Parser.copy_bytes(&self, usz start, usz length)
{
	self.checked(start, length)!;
	char[] copy = alloc::new_array(self.allocator, char, (sz)length);
	mem::copy(copy.ptr, self.data.ptr + start, (sz)length);
	return copy;
}

// An ASCII string: every byte must be below 0x80.
fn String? Parser.ascii(&self, usz start, usz length)
{
	self.checked(start, length)!;
	for (usz i = start; i < start + length; i++)
	{
		if ((uint)(self.data[i] & 0xFF) >= ASCII_LIMIT) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "ASCII string holds byte 0x%02X", self.data[i])~;
	}
	char[] bytes = self.copy_bytes(start, length)!;
	return (String)bytes;
}

// A UTF-16BE string of `units` code units.
fn String? Parser.utf16(&self, usz start, usz units)
{
	usz size = units * 2;
	self.checked(start, size)!;
	char[] wide = self.data[start:size];
	return text::utf16_to_utf8(self.allocator, wide, true);
}

// The `count` object references at `start`, decoded into an array.
fn Value[]? Parser.items(&self, usz start, usz count, usz owner, int depth)
{
	usz refs = count * self.ref_size;
	self.checked(start, refs)!;
	List{Value} items;
	items.tinit();
	for (usz i = 0; i < count; i++)
	{
		usz target = self.reference_at(start + i * self.ref_size, owner)!;
		items.push(self.object(target, depth + 1)!);
	}
	return items.to_aligned_array(self.allocator);
}

// The dictionary whose `pairs` keys are followed by `pairs` values.
fn Value? Parser.dictionary(&self, usz start, usz pairs, usz owner, int depth)
{
	usz refs = pairs * 2 * self.ref_size;
	self.checked(start, refs)!;
	List{value::Member} members;
	members.tinit();
	HashSet{String} keys;
	keys.tinit();
	for (usz i = 0; i < pairs; i++)
	{
		usz key_index = self.reference_at(start + i * self.ref_size, owner)!;
		usz value_index = self.reference_at(start + (pairs + i) * self.ref_size, owner)!;
		Value key = self.object(key_index, depth + 1)!;
		if (key.kind != STRING) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "dictionary key is not a string")~;
		Value member = self.object(value_index, depth + 1)!;
		value::add_member(&members, &keys, key.text, member)!;
	}
	return { .kind = DICT, .members = members.to_aligned_array(self.allocator) };
}

// One object reference, which must name an object other than `owner`.
fn usz? Parser.reference_at(&self, usz at, usz owner)
{
	usz target = (usz)read_be(self.data, self.checked(at, self.ref_size)!, self.ref_size);
	if (target >= self.object_count) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "reference %d is past the last object", target)~;
	if (target == owner) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "object %d refers to itself", owner)~;
	return target;
}

// The byte offset of object `index`, which must lie in the object region.
fn usz? Parser.offset_index(&self, usz index)
{
	usz at = self.table_offset + index * self.offset_size;
	usz offset = (usz)read_be(self.data, at, self.offset_size);
	if (offset < MAGIC_LENGTH || offset >= self.table_offset) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "object %d has an offset outside the file", index)~;
	return offset;
}


// An unsigned big-endian value of `size` bytes at `at`, which must be at most `limit` bytes wide.
fn ulong? Parser.unsigned_at(&self, usz at, usz size, usz limit)
{
	if (size > limit) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "value of %d bytes is too wide", size)~;
	self.checked(at, size)!;
	return read_be(self.data, at, size);
}

// `at` if the `size` bytes from it lie inside the object region, else an error.
fn usz? Parser.checked(&self, usz at, usz size)
{
	if (at < MAGIC_LENGTH || at > self.table_offset || size > self.table_offset - at)
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "object data at %d runs outside the object region", at)~;
	}
	return at;
}

// An 8-byte big-endian word at `at` in `data`, which is known to be in range.
fn usz read_word(char[] data, usz at) @local => (usz)read_be(data, at, WORD_BYTES);

// A big-endian unsigned number of `size` bytes (at most 8) at `at`, which the caller has checked.
fn ulong read_be(char[] data, usz at, usz size) @local
{
	ulong value = 0;
	for (usz i = 0; i < size; i++)
	{
		value = (value << 8) | (ulong)(data[at + i] & 0xFF);
	}
	return value;
}
