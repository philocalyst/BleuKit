<*
 Property lists in any of their three encodings, read into one `Value` tree.

 Source: Apple "Property List Programming Guide", and CoreFoundation's
 `CFPropertyList.c` (XML) and `CFBinaryPList.c` (binary) in
 https://github.com/apple-oss-distributions/CF.
 A file is binary when it starts with `bplist0`; XML when it starts with a UTF-8
 or UTF-16 byte-order mark or with `<`. Apple's `InfoPlist.strings` files are
 often UTF-16 XML, so that form is accepted as well.

 Not done: the old-style OpenStep text form (`{ key = value; }`), which the
 "Old-Style Property Lists" chapter describes. It is refused as malformed, not
 guessed at.
*>
module bleu::plist;
import bleu::error, bleu::plist::value, bleu::plist::text, bleu::plist::xml, bleu::plist::binary;

const String BINARY_MAGIC = "bplist";

<*
 Read a property list, detecting its encoding from the first bytes.

 @param [&inout] allocator : "Allocator for the value tree; freeing it frees the tree"
 @param bytes : "The complete file"
 @return? error::PROTOCOL : "The file is not a well-formed property list in any supported encoding"
 @return? error::OUT_OF_RANGE : "A binary integer does not fit in 64 bits, or the document is too large"
*>
fn Value? read(Allocator allocator, char[] bytes)
{
	if (bytes.len >= BINARY_MAGIC.len && (String)bytes[0:BINARY_MAGIC.len] == BINARY_MAGIC) return binary::parse(
		allocator,
		bytes
	);
	if (text::has_utf16_mark(bytes))
	{
		String utf8 = text::from_utf16_with_mark(tmem, bytes)!;
		return xml::parse(allocator, utf8);
	}
	return xml::parse(allocator, (String)bytes);
}