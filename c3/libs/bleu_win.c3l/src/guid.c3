<*
 GUIDs as the Windows ABI sees them: sixteen bytes, of which the first three
 fields are native-endian integers and the last eight are a plain byte string.

 This module is platform-neutral (no Win32 import), so the parser, formatter
 and comparisons are unit-tested on every host. Layout source: `GUID` in
 mingw-w64 `guiddef.h`, and Microsoft Learn "GUID structure" (see
 docs/research/bleu_win.md, section 1).

 Textual form is `{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}` (upper-case braces
 on output; braces and either case are accepted on input).
*>
module bleu::win::guid;
import std::core::mem, std::core::string;
import bleu::error;

<*
 A globally unique identifier. Field names follow the Windows `GUID` struct.

 Layout: 16 bytes, 4-byte alignment, no padding (checked by the module tests).
*>
struct Guid
{
	uint data1;
	ushort data2;
	ushort data3;
	char[8] data4;
}

$assert(Guid::size == 16);

<* The all-zero GUID. *>
const Guid NIL = { .data1 = 0, .data2 = 0, .data3 = 0, .data4 = { 0, 0, 0, 0, 0, 0, 0, 0 } };

<*
 Build a GUID from the eleven-field literal form used by `DEFINE_GUID`, so a
 constant can be copied straight from a header:

 const Guid IID_IUNKNOWN = guid::make(0x00000000, 0x0000, 0x0000,
 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46);

 @return "The GUID with the given fields"
*>
fn Guid make(
	uint data1,
	ushort data2,
	ushort data3,
	char b0,
	char b1,
	char b2,
	char b3,
	char b4,
	char b5,
	char b6,
	char b7
) @inline
{
	return { .data1 = data1, .data2 = data2, .data3 = data3, .data4 = { b0, b1, b2, b3, b4, b5, b6, b7 } };
}

<*
 Compile-time GUID literal: `guid("2f13c006-a03a-5f69-b090-75a43e33423e")`.

 The text is parsed by the compiler, so a malformed literal is a compile error.
 Braces are optional. Use it in `const` declarations.

 @param $text : "A GUID in canonical text form, 32 hex digits in 8-4-4-4-12 groups"
*>
macro Guid guid($text)
{
	char[16] $bytes =  { };
	int $n          =  0;
	int $high       = -1;
	$foreach $c : $text:
		$if $c != '-' &&& $c != '{' &&& $c != '}':
			$if $high < 0:
				$high = (int)guid_nibble($c);
			$else
				$bytes[$n] = (char)($high * 16 + (int)guid_nibble($c));
				$n = $n + 1;
				$high = -1;
			$endif
		$endif
	$endforeach
	$assert($n == 16);
	return {
		.data1 = ((uint)$bytes[0] << 24) | ((uint)$bytes[1] << 16) | ((uint)$bytes[2] << 8) | (uint)$bytes[3],
		.data2 = (ushort)(((uint)$bytes[4] << 8) | (uint)$bytes[5]),
		.data3 = (ushort)(((uint)$bytes[6] << 8) | (uint)$bytes[7]),
		.data4 = { $bytes[8], $bytes[9], $bytes[10], $bytes[11], $bytes[12], $bytes[13], $bytes[14], $bytes[15] }
	};
}

<* Value of one hex digit, at compile time. Used by `guid`. *>
macro uint guid_nibble($c) @private
{
	$if $c >= '0' &&& $c <= '9':
		return $c - '0';
	$else
		$if $c >= 'a' &&& $c <= 'f':
			return $c - 'a' + 10;
		$else
			return $c - 'A' + 10;
		$endif
	$endif
}

<* Two GUIDs are equal when all sixteen bytes are. *>
fn bool Guid.equals(self, Guid other) @inline
{
	return self.data1 == other.data1 && self.data2 == other.data2 && self.data3 == other.data3 && mem::equals(
		&self.data4,
		&other.data4,
		8
	);
}

<*
 Total order on GUIDs: the field-by-field comparison of their byte layout,
 most significant first. Returns a negative value, zero or a positive value.
*>
fn int Guid.compare(self, Guid other)
{
	if (self.data1 != other.data1) return self.data1 < other.data1 ? -1 : 1;
	if (self.data2 != other.data2) return self.data2 < other.data2 ? -1 : 1;
	if (self.data3 != other.data3) return self.data3 < other.data3 ? -1 : 1;
	for (usz i = 0; i < 8; i++)
	{
		if (self.data4[i] != other.data4[i]) return self.data4[i] < other.data4[i] ? -1 : 1;
	}
	return 0;
}

<*
 Canonical upper-case text with braces, as `StringFromGUID2` writes it.

 @param allocator : "Allocator for the returned string"
 @return "`{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}`"
*>
fn String Guid.format(self, Allocator allocator)
{
	return string::format(
		allocator,
		"{%08X-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X}",
		self.data1,
		self.data2,
		self.data3,
		self.data4[0],
		self.data4[1],
		self.data4[2],
		self.data4[3],
		self.data4[4],
		self.data4[5],
		self.data4[6],
		self.data4[7]
	);
}

<*
 Parse canonical GUID text. Braces are optional and hex digits may be either
 case; anything else (wrong length, misplaced dash, non-hex digit) is rejected.

 @param text : "The text to parse"
 @return "The parsed GUID"
 @return? error::INVALID_ARGUMENT : "If `text` is not a GUID"
*>
fn Guid? parse(String text)
{
	String body = text;
	if (body.len == 38 && body[0] == '{' && body[37] == '}') body = body[1..36];
	if (body.len != 36) return error::raise(
		error::INVALID_ARGUMENT,
		error::Domain.INTERNAL,
		0,
		"not a GUID: '%s'",
		text
	)~;
	char[32] nibbles;
	usz count = 0;
	for (usz i = 0; i < 36; i++)
	{
		char c = body[i];
		// The four dashes sit at fixed positions in the 8-4-4-4-12 layout.
		if (i == 8 || i == 13 || i == 18 || i == 23)
		{
			if (c != '-') return error::raise(
				error::INVALID_ARGUMENT,
				error::Domain.INTERNAL,
				0,
				"not a GUID: '%s'",
				text
			)~;
			continue;
		}
		int value = guid_hex_value(c);
		if (value < 0) return error::raise(
			error::INVALID_ARGUMENT,
			error::Domain.INTERNAL,
			0,
			"not a GUID: '%s'",
			text
		)~;
		nibbles[count++] = (char)value;
	}
	char[16] bytes;
	for (usz b = 0; b < 16; b++) bytes[b] = (char)(nibbles[2 * b] * 16 + nibbles[2 * b + 1]);
	return {
		.data1 = ((uint)bytes[0] << 24) | ((uint)bytes[1] << 16) | ((uint)bytes[2] << 8) | (uint)bytes[3],
		.data2 = (ushort)(((uint)bytes[4] << 8) | (uint)bytes[5]),
		.data3 = (ushort)(((uint)bytes[6] << 8) | (uint)bytes[7]),
		.data4 = { bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15] },
	};
}

<* Value of a hex digit, or -1 when `c` is not one. *>
fn int guid_hex_value(char c) @local
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}