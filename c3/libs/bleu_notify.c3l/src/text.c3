<*
 Bounds for text that comes from untrusted applications.
*>
module bleu::notify::text;

<*
 The longest prefix of `text` that is at most `max` bytes and ends on a UTF-8
 character boundary. Text that already fits is returned as it is.
*>
fn String truncate(String text, usz max)
{
	if ((usz)text.len <= max) return text;
	usz cut = max;
	// A continuation byte is 10xxxxxx: back up to the lead byte of the character the cut would split.
	while (cut > 0 && is_continuation(text[cut])) cut--;
	return text[0:cut];
}

<* True for the bytes of a UTF-8 sequence after its first byte. *>
fn bool is_continuation(char b) @inline => (b & 0xC0) == 0x80;
