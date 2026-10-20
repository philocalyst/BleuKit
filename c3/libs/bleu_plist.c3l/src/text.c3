<*
 Text helpers for property lists: UTF-8 output and UTF-16 input.

 Source: The Unicode Standard, chapter 3 (UTF-16 surrogate pairs and UTF-8
 bit patterns, https://www.unicode.org/versions/latest/); RFC 3629 for UTF-8.
 The surrogate arithmetic is checked by the golden fixture `sample.bplist`, whose
 `Unicode` value holds U+1F600 and was encoded by Python's `plistlib`.

 Surrogates that are unpaired, and code points above U+10FFFF, are errors: the
 readers never produce invalid UTF-8.
*>
module bleu::plist::text;
import bleu::error;

const uint FIRST_HIGH_SURROGATE = 0xD800;
const uint LAST_HIGH_SURROGATE = 0xDBFF;
const uint FIRST_LOW_SURROGATE = 0xDC00;
const uint LAST_LOW_SURROGATE = 0xDFFF;
const uint MAX_CODE_POINT = 0x10FFFF;
const uint SURROGATE_OFFSET = 0x10000;
const uint SURROGATE_BITS = 10;
const uint SURROGATE_MASK = 0x3FF;
const uint ONE_BYTE_LIMIT = 0x80;
const uint TWO_BYTE_LIMIT = 0x800;
const uint THREE_BYTE_LIMIT = 0x10000;
const uint CONTINUATION_TAG = 0x80;
const uint CONTINUATION_BITS = 6;
const uint CONTINUATION_MASK = 0x3F;
const uint TWO_BYTE_TAG = 0xC0;
const uint THREE_BYTE_TAG = 0xE0;
const uint FOUR_BYTE_TAG = 0xF0;
const uint UTF16_UNIT_BYTES = 2;
const char UTF16_BE_BOM_HIGH = 0xFE;
const char UTF16_BE_BOM_LOW = 0xFF;

<*
 Append one code point to `out` as UTF-8.

 @return? error::PROTOCOL : "The code point is a surrogate or above U+10FFFF"
*>
fn void? append_utf8(DString* out, uint code_point)
{
	if (code_point >= FIRST_HIGH_SURROGATE && code_point <= LAST_LOW_SURROGATE) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "surrogate U+%X is not a character", code_point)~;
	if (code_point > MAX_CODE_POINT) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "code point U+%X is out of range", code_point)~;
	if (code_point < ONE_BYTE_LIMIT)
	{
		out.append_char((char)code_point);
	}
	else if (code_point < TWO_BYTE_LIMIT)
	{
		out.append_char((char)(TWO_BYTE_TAG | (code_point >> CONTINUATION_BITS)));
		out.append_char((char)(CONTINUATION_TAG | (code_point & CONTINUATION_MASK)));
	}
	else if (code_point < THREE_BYTE_LIMIT)
	{
		out.append_char((char)(THREE_BYTE_TAG | (code_point >> (2 * CONTINUATION_BITS))));
		out.append_char((char)(CONTINUATION_TAG | ((code_point >> CONTINUATION_BITS) & CONTINUATION_MASK)));
		out.append_char((char)(CONTINUATION_TAG | (code_point & CONTINUATION_MASK)));
	}
	else
	{
		out.append_char((char)(FOUR_BYTE_TAG | (code_point >> (3 * CONTINUATION_BITS))));
		out.append_char((char)(CONTINUATION_TAG | ((code_point >> (2 * CONTINUATION_BITS)) & CONTINUATION_MASK)));
		out.append_char((char)(CONTINUATION_TAG | ((code_point >> CONTINUATION_BITS) & CONTINUATION_MASK)));
		out.append_char((char)(CONTINUATION_TAG | (code_point & CONTINUATION_MASK)));
	}
}

<*
 Whether `bytes` starts with a UTF-16 byte-order mark, either endianness.
*>
fn bool has_utf16_mark(char[] bytes) @inline
{
	return bytes.len >= 2 && ((bytes[0] == 0xFE && bytes[1] == 0xFF) || (bytes[0] == 0xFF && bytes[1] == 0xFE));
}

<*
 Decode UTF-16 that starts with a byte-order mark into UTF-8. The mark is dropped.

 @param [&inout] allocator : "Allocator for the UTF-8 result"
 @return? error::PROTOCOL : "The data has an odd length, an unpaired surrogate, or no byte-order mark"
*>
fn String? from_utf16_with_mark(Allocator allocator, char[] bytes)
{
	if (!has_utf16_mark(bytes)) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "UTF-16 data has no byte-order mark")~;
	bool big_endian = bytes[0] == UTF16_BE_BOM_HIGH;
	return utf16_to_utf8(allocator, bytes[UTF16_UNIT_BYTES:bytes.len - UTF16_UNIT_BYTES], big_endian);
}

<*
 Decode UTF-16 code units into UTF-8. Surrogate pairs become one code point.

 @param [&inout] allocator : "Allocator for the UTF-8 result"
 @param bytes : "The code units, two bytes each"
 @param big_endian : "true for UTF-16BE, false for UTF-16LE"
 @return? error::PROTOCOL : "The data has an odd length or an unpaired surrogate"
*>
fn String? utf16_to_utf8(Allocator allocator, char[] bytes, bool big_endian)
{
	if (bytes.len % UTF16_UNIT_BYTES != 0) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "UTF-16 data has an odd length")~;
	DString out;
	out.init(tmem, bytes.len);
	usz i = 0;
	while (i < bytes.len)
	{
		uint unit = read_unit(bytes, i, big_endian);
		i += UTF16_UNIT_BYTES;
		if (unit < FIRST_HIGH_SURROGATE || unit > LAST_LOW_SURROGATE)
		{
			append_utf8(&out, unit)!;
			continue;
		}
		if (unit > LAST_HIGH_SURROGATE || i >= bytes.len) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "unpaired UTF-16 surrogate")~;
		uint low = read_unit(bytes, i, big_endian);
		if (low < FIRST_LOW_SURROGATE || low > LAST_LOW_SURROGATE) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "unpaired UTF-16 surrogate")~;
		i += UTF16_UNIT_BYTES;
		uint code_point = SURROGATE_OFFSET + ((unit - FIRST_HIGH_SURROGATE) << SURROGATE_BITS) + (low - FIRST_LOW_SURROGATE);
		append_utf8(&out, code_point)!;
	}
	return out.copy_str(allocator);
}

// The 16-bit unit at byte `index` of `bytes`.
fn uint read_unit(char[] bytes, usz index, bool big_endian) @local @inline
{
	uint first = (uint)(bytes[index] & 0xFF);
	uint second = (uint)(bytes[index + 1] & 0xFF);
	return big_endian ? (first << 8) | second : (second << 8) | first;
}
