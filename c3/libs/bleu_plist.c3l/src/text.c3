<*
 Text helpers for property lists: UTF-8 output and UTF-16 input.

 Source: The Unicode Standard, chapter 3 (UTF-16 surrogate pairs and UTF-8
 bit patterns, https://www.unicode.org/versions/latest/); RFC 3629 for UTF-8.
 The surrogate arithmetic is checked by the golden fixture `sample.bplist`, whose
 `Unicode` value holds U+1F600 and was encoded by Python's `plistlib`.

 Surrogates that are unpaired, and code points above U+10FFFF, are errors: the
 readers never produce invalid UTF-8. Text that arrives as UTF-8 (the XML path)
 is checked with `check_utf8` before it is used, and the writers check every string
 with `decode_at` so that a hand-built tree cannot abort the process.
*>
module bleu::plist::text;
import bleu::error;

const uint FIRST_HIGH_SURROGATE = 0xD800;
const uint LAST_HIGH_SURROGATE  = 0xDBFF;
const uint FIRST_LOW_SURROGATE  = 0xDC00;
const uint LAST_LOW_SURROGATE   = 0xDFFF;
const uint MAX_CODE_POINT       = 0x10FFFF;
const uint SURROGATE_OFFSET     = 0x10000;
const uint SURROGATE_BITS       = 10;
const uint SURROGATE_MASK       = 0x3FF;
const uint ONE_BYTE_LIMIT       = 0x80;
const uint TWO_BYTE_LIMIT       = 0x800;
const uint THREE_BYTE_LIMIT     = 0x10000;
const uint CONTINUATION_TAG     = 0x80;
const uint CONTINUATION_BITS    = 6;
const uint CONTINUATION_MASK    = 0x3F;
const uint TWO_BYTE_TAG         = 0xC0;
const uint THREE_BYTE_TAG       = 0xE0;
const uint FOUR_BYTE_TAG        = 0xF0;
const uint UTF16_UNIT_BYTES     = 2;
const char UTF16_BE_BOM_HIGH    = 0xFE;
const char UTF16_BE_BOM_LOW     = 0xFF;
const uint LEAD_TWO_FIRST       = 0xC2;
const uint LEAD_TWO_LAST        = 0xDF;
const uint LEAD_THREE_FIRST     = 0xE0;
const uint LEAD_THREE_LAST      = 0xEF;
const uint LEAD_FOUR_FIRST      = 0xF0;
const uint LEAD_FOUR_LAST       = 0xF4;
const uint LEAD_TWO_MASK        = 0x1F;
const uint LEAD_THREE_MASK      = 0x0F;
const uint LEAD_FOUR_MASK       = 0x07;

<*
 One code point read from UTF-8: its value and the number of bytes it occupied.
*>
struct CodePoint
{
	uint value;
	usz width;
}

<*
 Decode the code point that starts at byte `at` of `bytes`. The sequence must be
 well-formed UTF-8 (RFC 3629): no overlong forms, no surrogates, nothing above U+10FFFF.

 @param bytes : "The text"
 @param at : "The index of the first byte of the code point; must be below `bytes.len`"
 @return? error::PROTOCOL : "The bytes at `at` do not start one well-formed UTF-8 sequence"
*>
fn CodePoint? decode_at(String bytes, usz at)
{
	uint lead = (uint)(bytes[at] & 0xFF);
	if (lead < ONE_BYTE_LIMIT) return { .value = lead, .width = 1 };
	usz width      = 0;
	uint value     = 0;
	uint minimum   = 0;
	if (lead >= LEAD_TWO_FIRST && lead <= LEAD_TWO_LAST)
	{
		width = 2;
		value = lead & LEAD_TWO_MASK;
		minimum = ONE_BYTE_LIMIT;
	}
	else if (lead >= LEAD_THREE_FIRST && lead <= LEAD_THREE_LAST)
	{
		width = 3;
		value = lead & LEAD_THREE_MASK;
		minimum = TWO_BYTE_LIMIT;
	}
	else if (lead >= LEAD_FOUR_FIRST && lead <= LEAD_FOUR_LAST)
	{
		width = 4;
		value = lead & LEAD_FOUR_MASK;
		minimum = THREE_BYTE_LIMIT;
	}
	else
	{
		return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "byte 0x%02X cannot start UTF-8", lead)~;
	}
	if (at + width > bytes.len) return error::raise(
		error::PROTOCOL,
		error::Domain.INTERNAL,
		0,
		"UTF-8 sequence at byte %d is cut short",
		at
	)~;
	for (usz i = 1; i < width; i++)
	{
		uint continuation = (uint)(bytes[at + i] & 0xFF);
		if ((continuation & ~CONTINUATION_MASK) != CONTINUATION_TAG) return error::raise(
			error::PROTOCOL,
			error::Domain.INTERNAL,
			0,
			"UTF-8 sequence at byte %d has no continuation byte",
			at
		)~;
		value = (value << CONTINUATION_BITS) | (continuation & CONTINUATION_MASK);
	}
	if (value < minimum || value > MAX_CODE_POINT || (value >= FIRST_HIGH_SURROGATE && value <= LAST_LOW_SURROGATE))
	{
		return error::raise(
			error::PROTOCOL,
			error::Domain.INTERNAL,
			0,
			"UTF-8 sequence at byte %d is not a character",
			at
		)~;
	}
	return { .value = value, .width = width };
}

<*
 Check that `bytes` is well-formed UTF-8, as `decode_at` defines it.

 @return? error::PROTOCOL : "The text holds a byte sequence that is not UTF-8"
*>
fn void? check_utf8(String bytes)
{
	usz at = 0;
	while (at < bytes.len)
	{
		CodePoint point = decode_at(bytes, at)!;
		at += point.width;
	}
}

<*
 Append one code point to `out` as UTF-8.

 @return? error::PROTOCOL : "The code point is a surrogate or above U+10FFFF"
*>
fn void? append_utf8(DString* out, uint code_point)
{
	if (code_point >= FIRST_HIGH_SURROGATE && code_point <= LAST_LOW_SURROGATE) return error::raise(
		error::PROTOCOL,
		error::Domain.INTERNAL,
		0,
		"surrogate U+%X is not a character",
		code_point
	)~;
	if (code_point > MAX_CODE_POINT) return error::raise(
		error::PROTOCOL,
		error::Domain.INTERNAL,
		0,
		"code point U+%X is out of range",
		code_point
	)~;
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
	if (!has_utf16_mark(
		bytes
	)) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "UTF-16 data has no byte-order mark")~;
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
	if (bytes.len % UTF16_UNIT_BYTES != 0) return error::raise(
		error::PROTOCOL,
		error::Domain.INTERNAL,
		0,
		"UTF-16 data has an odd length"
	)~;
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
		if (unit > LAST_HIGH_SURROGATE || i >= bytes.len) return error::raise(
			error::PROTOCOL,
			error::Domain.INTERNAL,
			0,
			"unpaired UTF-16 surrogate"
		)~;
		uint low = read_unit(bytes, i, big_endian);
		if (low < FIRST_LOW_SURROGATE || low > LAST_LOW_SURROGATE) return error::raise(
			error::PROTOCOL,
			error::Domain.INTERNAL,
			0,
			"unpaired UTF-16 surrogate"
		)~;
		i += UTF16_UNIT_BYTES;
		uint code_point = SURROGATE_OFFSET + ((unit - FIRST_HIGH_SURROGATE) << SURROGATE_BITS)
			+ (low - FIRST_LOW_SURROGATE);
		append_utf8(&out, code_point)!;
	}
	return out.copy_str(allocator);
}

// The 16-bit unit at byte `index` of `bytes`.
fn uint read_unit(char[] bytes, usz index, bool big_endian) @local @inline
{
	uint first  = (uint)(bytes[index] & 0xFF);
	uint second = (uint)(bytes[index + 1] & 0xFF);
	return big_endian ? (first << 8) | second : (second << 8) | first;
}