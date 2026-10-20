<*
 The text shown for a copy: valid UTF-8, one line, no control or bidirectional-override
 characters, and at most `PREVIEW_LIMIT` bytes. Bytes from another application are never
 shown raw. Pure: no I/O, no OS.
*>
module bleu::clipboard;

<* Most bytes of preview text kept. The cut is always on a character boundary. *>
const usz PREVIEW_LIMIT = 512;

<* U+FFFD REPLACEMENT CHARACTER, shown for each byte that is not part of valid UTF-8. *>
const String REPLACEMENT = "\xEF\xBF\xBD";

<* One UTF-8 sequence: its length in bytes (0 when invalid) and its code point. *>
struct Decoded
{
	usz size;
	uint code;
}

<*
 Decode the sequence that starts at `at`. Overlong forms, surrogates and code points above
 U+10FFFF are invalid (RFC 3629 section 4), so the result has `size` 0 for them.
*>
fn Decoded decode_at(char[] text, usz at)
{
	uint lead = (uint)text[at];
	if (lead < 0x80) return { .size = 1, .code = lead };
	usz need;
	uint code;
	uint low  = 0x80;
	uint high = 0xBF;
	if (lead >= 0xC2 && lead <= 0xDF)
	{
		need = 2;
		code = lead & 0x1F;
	}
	else if (lead >= 0xE0 && lead <= 0xEF)
	{
		need = 3;
		code = lead & 0x0F;
		if (lead == 0xE0) low = 0xA0;
		if (lead == 0xED) high = 0x9F;
	}
	else if (lead >= 0xF0 && lead <= 0xF4)
	{
		need = 4;
		code = lead & 0x07;
		if (lead == 0xF0) low = 0x90;
		if (lead == 0xF4) high = 0x8F;
	}
	else
	{
		return { };
	}
	if (at + need > (usz)text.len) return { };
	for (usz k = 1; k < need; k++)
	{
		uint next = (uint)text[at + k];
		if (next < low || next > high) return { };
		low = 0x80;
		high = 0xBF;
		code = (code << 6) | (next & 0x3F);
	}
	return { .size = need, .code = code };
}

<*
 Whether a code point is shown as a space: every C0 and C1 control (tab and newline
 included), the line and paragraph separators, the bidirectional embedding and isolate
 controls (which can reorder what the reader sees), and the space itself.
*>
fn bool is_space_like(uint code) @inline
{
	if (code <= 0x20 || (code >= 0x7F && code <= 0x9F)) return true;
	if (code == 0x2028 || code == 0x2029) return true;
	if (code >= 0x202A && code <= 0x202E) return true;
	return code >= 0x2066 && code <= 0x2069;
}

<*
 Sanitised preview of `text`, copied into `allocator`. Runs of space-like characters become
 one space, leading and trailing spaces are dropped, invalid bytes become U+FFFD, and the
 result stops before it would pass `PREVIEW_LIMIT` bytes.
*>
fn String make_preview(Allocator allocator, char[] text)
{
	char[PREVIEW_LIMIT] out;
	usz len        = 0;
	bool pending   = false; // a space is owed before the next visible character
	usz at         = 0;
	while (at < (usz)text.len)
	{
		Decoded decoded = decode_at(text, at);
		if (decoded.size == 0)
		{
			if (!emit(out[..], &len, pending, REPLACEMENT)) break;
			pending = false;
			at++;
			continue;
		}
		if (is_space_like(decoded.code))
		{
			pending = len > 0;
			at += decoded.size;
			continue;
		}
		if (!emit(out[..], &len, pending, (String)text[at:decoded.size])) break;
		pending = false;
		at += decoded.size;
	}
	String result = (String)out[0:len];
	return result.copy(allocator);
}

<*
 Append an optional space and then `piece` to `out` at `len`.

 @return "false when the piece would not fit, in which case nothing was written"
*>
fn bool emit(char[] out, usz* len, bool space_first, String piece) @private
{
	usz needed = (usz)piece.len + (space_first ? (usz)1 : (usz)0);
	if (*len + needed > (usz)out.len) return false;
	if (space_first) out[(*len)++] = ' ';
	foreach (c : piece) out[(*len)++] = c;
	return true;
}
