<*
 Attributes as one byte blob, for the keychain's generic-data field: for each
 attribute, a 4-byte big-endian key length, the key, a 4-byte value length and
 the value. Lengths are checked on decode, so a damaged blob is a protocol error.
*>
module bleu::secrets::local;
import std::collections::list, bleu::error, bleu::secrets;

<* Bytes of a length prefix. *>
const sz LENGTH_BYTES   = 4;
<* The hexadecimal digits, in order. *>
const String HEX_DIGITS = "0123456789abcdef";

<* Encode `attributes`. The blob is owned by `allocator`. *>
fn char[] encode_attributes(Allocator allocator, Attribute[] attributes)
{
	@pool()
	{
		DString out;
		out.init(tmem);
		foreach (attribute : attributes)
		{
			append_length(&out, attribute.key.len);
			out.append(attribute.key);
			append_length(&out, attribute.value.len);
			out.append(attribute.value);
		}
		return out.str_view().copy(allocator);
	};
}

fn void append_length(DString* out, sz length)
{
	out.append_char((char)(length >> 24));
	out.append_char((char)(length >> 16));
	out.append_char((char)(length >> 8));
	out.append_char((char)length);
}

<*
 Decode a blob written by `encode_attributes`. Strings are copied into `allocator`.

 @return? error::PROTOCOL : "The blob is truncated or a length is impossible"
*>
fn Attribute[]? decode_attributes(Allocator allocator, String blob)
{
	List{Attribute} out;
	out.init(tmem);
	usz at = 0;
	while (at < blob.len)
	{
		String key   = take_text(blob, &at)!;
		String value = take_text(blob, &at)!;
		out.push({ .key = key.copy(allocator), .value = value.copy(allocator) });
	}
	return alloc::clone_slice(allocator, out.array_view());
}

// The next length-prefixed text of `blob`, starting at `*at`.
fn String? take_text(String blob, usz* at)
{
	if (blob.len - *at < LENGTH_BYTES) return error::raise(
		error::PROTOCOL,
		error::Domain.INTERNAL,
		0,
		"attribute blob truncated"
	)~;
	usz length = 0;
	for (usz i = 0; i < LENGTH_BYTES; i++) length = (length << 8) | (usz)(char)blob[*at + i];
	*at += LENGTH_BYTES;
	if (blob.len - *at < length) return error::raise(
		error::PROTOCOL,
		error::Domain.INTERNAL,
		0,
		"attribute blob truncated"
	)~;
	String text = blob[*at:length];
	*at += length;
	return text;
}

<* Lower-case hexadecimal of `bytes`, owned by `allocator`. *>
fn String hex_encode(Allocator allocator, char[] bytes)
{
	@pool()
	{
		DString out;
		out.init(tmem);
		for (usz i = 0; i < bytes.len; i++)
		{
			out.append_char(HEX_DIGITS[((char)bytes[i]) >> 4]);
			out.append_char(HEX_DIGITS[((char)bytes[i]) & 0x0F]);
		}
		return out.str_view().copy(allocator);
	};
}

<*
 Bytes of lower- or upper-case hexadecimal text, owned by `allocator`.

 @return? error::PROTOCOL : "The text has an odd length or a non-hex digit"
*>
fn char[]? hex_decode(Allocator allocator, String text)
{
	if (text.len % 2 != 0) return error::raise(
		error::PROTOCOL,
		error::Domain.INTERNAL,
		0,
		"hex text has an odd length"
	)~;
	char[] out = alloc::alloc_array(allocator, char, text.len / 2);
	for (usz i = 0; i < out.len; i++)
	{
		int high = hex_value(text[2 * i]);
		int low  = hex_value(text[2 * i + 1]);
		if (high < 0 || low < 0) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "not a hex digit")~;
		out[i] = (char)(high << 4 | low);
	}
	return out;
}

fn int hex_value(char c) @inline
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}