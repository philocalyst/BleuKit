<*
 Marshalling: the byte format of D-Bus values, in both byte orders.

 `Writer` turns values into bytes and `Reader` turns bytes back into values. Both
 are driven by a signature, so neither needs type tags on the wire, and both
 apply the same rules:

 * every value is aligned to its natural boundary, counted from the first byte
   of the buffer, with NUL padding of the minimum length;
 * STRUCT and DICT_ENTRY start on an 8-byte boundary;
 * an ARRAY is a UINT32 byte length (excluding the padding that follows it),
   padding to the element alignment (present even when the array is empty),
   then the elements;
 * a VARIANT is a SIGNATURE of its contents, then the contents.

 Sources: D-Bus specification, "Byte order and alignment", "Marshalling basic
 types", "Marshalling containers" and "Summary of D-Bus marshalling"; the
 example "00 00 00 08 | 00 00 00 00 | 00 00 00 00 00 00 00 05" for an array of
 one INT64 (big endian, 8-byte aligned start) is reproduced in the tests.
 Cross-checked against systemd sd-bus src/libsystemd/sd-bus/bus-message.c
 (message_append_basic, message_open_array: length excludes padding; padding
 added before the first element even if there is none) and zvariant 5.5.0
 src/dbus/ser.rs (SeqSerializer::end_seq subtracts first_padding from the length).
*>
module bleu::dbus::marshal;
import bleu::error, bleu::dbus::signature, bleu::dbus::names, bleu::dbus::value;

<*
 Largest array length in bytes, excluding padding: 2^26.
 Spec "Marshalling containers"; sd-bus BUS_ARRAY_MAX_SIZE 67108864.
*>
const MAX_ARRAY_LENGTH = 67108864;

<*
 Most containers that may be open at once, plus the top level: 32 arrays and 32
 structs (VARIANT counts too, within the spec's total of 64).
*>
const MAX_FRAMES = 65;

<* Largest signature a VARIANT carries (its length is one byte). *>
const MAX_VARIANT_SIGNATURE = 255;

<* Kind of container a frame describes. *>
enum FrameKind : char
{
	TOP,
	ARRAY,
	STRUCT,
	DICT_ENTRY,
	VARIANT,
}

<*
 One open level of a marshalled value. `sig` is what the contents of this level
 must look like; `cursor` is how far into `sig` the contents have progressed.
 An ARRAY's `sig` is its element type and its cursor wraps to the start after
 each element. The other fields are used only by the writer (`length_at`,
 `data_at`) or only by the reader (`end`, the absolute end of the level).
*>
struct Frame
{
	FrameKind kind;
	String sig;
	usz cursor;
	usz length_at;
	usz data_at;
	usz end;
}

// Bytes of NUL padding that move `pos` up to the next multiple of `align`.
fn usz padding_for(usz pos, usz align) @inline => (align - pos % align) % align;

// Index just past the complete type a frame expects next. An array's element
// may be a dict entry, which a standalone type may not be.
fn usz? frame_end(Frame* f) @inline
{
	if (f.kind == ARRAY) return signature::element_end(f.sig, f.cursor);
	return signature::complete_end(f.sig, f.cursor);
}

// The kind of value a complete type's first code describes.
fn Kind? kind_of_code(char code)
{
	switch (code)
	{
		case signature::BYTE: return BYTE;
		case signature::BOOLEAN: return BOOLEAN;
		case signature::INT16: return INT16;
		case signature::UINT16: return UINT16;
		case signature::INT32: return INT32;
		case signature::UINT32: return UINT32;
		case signature::INT64: return INT64;
		case signature::UINT64: return UINT64;
		case signature::DOUBLE: return DOUBLE;
		case signature::STRING: return STRING;
		case signature::OBJECT_PATH: return OBJECT_PATH;
		case signature::SIGNATURE: return SIGNATURE;
		case signature::UNIX_FD: return UNIX_FD;
		case signature::ARRAY: return ARRAY;
		case signature::STRUCT_OPEN: return STRUCT;
		case signature::DICT_OPEN: return DICT_ENTRY;
		case signature::VARIANT: return VARIANT;
		default: return error::INVALID_ARGUMENT~;
	}
}
