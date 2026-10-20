<*
 Type signatures: the grammar that describes the type of every D-Bus value.

 A signature is a sequence of *complete types*. This module validates
 signatures against the limits of the specification, splits them into complete
 types, and reports the wire alignment of each type.

 Sources:
 * D-Bus specification, "Type System" and "Valid Signatures": container depth
   of 32 arrays and 32 structs, a maximum signature length of 255, dict entries
   only as array elements with a basic key.
   https://dbus.freedesktop.org/doc/dbus-specification.html
 * zvariant 5.5.0 src/container_depths.rs (MAX_STRUCT_DEPTH = 32,
   MAX_ARRAY_DEPTH = 32) and systemd sd-bus src/libsystemd/sd-bus/bus-signature.c
   (the same two limits; dict entries count against the struct depth).
*>
module bleu::dbus::signature;
import bleu::error;

<* Longest signature: it is carried with a single length byte on the wire. *>
const MAX_LENGTH = 255;

<* Deepest nesting of array type codes allowed in a signature. *>
const MAX_ARRAY_DEPTH = 32;

<* Deepest nesting of structs and dict entries allowed in a signature. *>
const MAX_STRUCT_DEPTH = 32;

<*
 Type codes. Each constant is the ASCII code of its type, as it appears in a
 signature. `STRUCT` ('r') and `DICT_ENTRY` ('e') are reserved and never appear
 in a signature; parentheses and braces are used instead.
*>
const char INVALID      = 0;
const char BYTE         = 'y';
const char BOOLEAN      = 'b';
const char INT16        = 'n';
const char UINT16       = 'q';
const char INT32        = 'i';
const char UINT32       = 'u';
const char INT64        = 'x';
const char UINT64       = 't';
const char DOUBLE       = 'd';
const char UNIX_FD      = 'h';
const char STRING       = 's';
const char OBJECT_PATH  = 'o';
const char SIGNATURE    = 'g';
const char ARRAY        = 'a';
const char VARIANT      = 'v';
const char STRUCT_OPEN  = '(';
const char STRUCT_CLOSE = ')';
const char DICT_OPEN    = '{';
const char DICT_CLOSE   = '}';

<* Alignment of a 1-byte value (BYTE, SIGNATURE, VARIANT). *>
const usz ALIGN_1 = 1;
<* Alignment of a 2-byte value (INT16, UINT16). *>
const usz ALIGN_2 = 2;
<* Alignment of a 4-byte value and of a length prefix (BOOLEAN, UINT32, UNIX_FD, STRING, OBJECT_PATH, ARRAY). *>
const usz ALIGN_4 = 4;
<* Alignment of an 8-byte value and of a STRUCT or DICT_ENTRY. *>
const usz ALIGN_8 = 8;

<*
 True for the basic (non-container) types, which are exactly one code long.

 @param code : "A type code"
*>
fn bool is_basic(char code) @inline
{
	switch (code)
	{
		case BYTE:
		case BOOLEAN:
		case INT16:
		case UINT16:
		case INT32:
		case UINT32:
		case INT64:
		case UINT64:
		case DOUBLE:
		case UNIX_FD:
		case STRING:
		case OBJECT_PATH:
		case SIGNATURE: return true;
		default: return false;
	}
}

<*
 Natural alignment of one type code on the wire. For STRUCT and DICT_ENTRY
 this is 8 regardless of their contents.

 @param code : "The first code of a complete type"
 @return "1, 2, 4 or 8; 1 for codes that are not types"
*>
fn usz code_alignment(char code)
{
	switch (code)
	{
		case INT16:
		case UINT16: return ALIGN_2;
		case BOOLEAN:
		case INT32:
		case UINT32:
		case UNIX_FD:
		case STRING:
		case OBJECT_PATH:
		case ARRAY: return ALIGN_4;
		case INT64:
		case UINT64:
		case DOUBLE:
		case STRUCT_OPEN:
		case DICT_OPEN: return ALIGN_8;
		default: return ALIGN_1;
	}
}

<*
 Alignment of the complete type at the start of `type`.

 @param type : "A single complete type, not empty"
 @require type.len > 0 : "an empty string is not a type"
*>
fn usz alignment_of(String type) @inline => code_alignment(type[0]);

<*
 Index just past the complete type that starts at `start`.

 @param sig : "The signature being scanned"
 @param start : "Index of the first code of the type"
 @return? error::INVALID_ARGUMENT : "The text at `start` is not a complete type"
*>
fn usz? complete_end(String sig, usz start)
{
	return scan(sig, start, 0, 0, false);
}

// Recursive descent over one complete type. `arrays` and `structs` count the
// containers enclosing `pos`; `array_element` is true only for the element of
// an array, the only place a dict entry may appear.
fn usz? scan(String sig, usz pos, uint arrays, uint structs, bool array_element) @private
{
	if (pos >= sig.len) return error::INVALID_ARGUMENT~;
	char code = sig[pos];
	switch (code)
	{
		case ARRAY:
			if (arrays >= MAX_ARRAY_DEPTH) return error::INVALID_ARGUMENT~;
			return scan(sig, pos + 1, arrays + 1, structs, true);
		case STRUCT_OPEN:
			if (structs >= MAX_STRUCT_DEPTH) return error::INVALID_ARGUMENT~;
			return scan_fields(sig, pos + 1, arrays, structs + 1);
		case DICT_OPEN:
			if (!array_element) return error::INVALID_ARGUMENT~;
			if (structs >= MAX_STRUCT_DEPTH) return error::INVALID_ARGUMENT~;
			return scan_entry(sig, pos + 1, arrays, structs + 1);
		case VARIANT: return pos + 1;
		default:
			if (!is_basic(code)) return error::INVALID_ARGUMENT~;
			return pos + 1;
	}
}

// Fields of a struct, from `pos` (just after '(') up to and including ')'.
fn usz? scan_fields(String sig, usz pos, uint arrays, uint structs) @private
{
	usz p = pos;
	uint count = 0;
	while (p < sig.len && sig[p] != STRUCT_CLOSE)
	{
		p = scan(sig, p, arrays, structs, false)!;
		count++;
	}
	if (p >= sig.len || count == 0) return error::INVALID_ARGUMENT~;
	return p + 1;
}

// The key and value of a dict entry, from `pos` (just after '{') through '}'.
fn usz? scan_entry(String sig, usz pos, uint arrays, uint structs) @private
{
	if (pos >= sig.len || !is_basic(sig[pos])) return error::INVALID_ARGUMENT~;
	usz value = scan(sig, pos + 1, arrays, structs, false)!;
	if (value >= sig.len || sig[value] != DICT_CLOSE) return error::INVALID_ARGUMENT~;
	return value + 1;
}

<*
 True when `sig` is a valid signature for a message body or header: zero or
 more complete types, at most `MAX_LENGTH` bytes, within the depth limits.
*>
fn bool valid(String sig)
{
	if (sig.len > MAX_LENGTH) return false;
	usz pos = 0;
	while (pos < sig.len)
	{
		if (try end = complete_end(sig, pos))
		{
			pos = end;
			continue;
		}
		return false;
	}
	return true;
}

<*
 True when `sig` is exactly one complete type. A VARIANT's signature must be
 one, and so must the signature of a value that is given a type on its own.
*>
fn bool is_single(String sig)
{
	if (sig.len == 0 || !valid(sig)) return false;
	if (try end = complete_end(sig, 0)) return end == sig.len;
	return false;
}

<*
 Walks the complete types of a signature in order, without allocating. Validate
 the signature with `valid` first; otherwise `next` may fail part way through.
*>
struct TypeIterator
{
	String sig;
	usz pos;
}

<* Start an iteration over the complete types of `sig`. *>
fn TypeIterator iterate(String sig) @inline => { .sig = sig };

<* True while another complete type follows. *>
fn bool TypeIterator.has_next(&self) @inline => self.pos < self.sig.len;

<*
 The next complete type, as a slice of the signature.

 @return? error::INVALID_ARGUMENT : "The signature is malformed from this point on"
*>
fn String? TypeIterator.next(&self)
{
	usz end = complete_end(self.sig, self.pos)!;
	String type = self.sig[self.pos:end - self.pos];
	self.pos = end;
	return type;
}
