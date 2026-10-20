module bleu::network;
import bleu::dbus::names;

<*
 An SSID from its raw octets. The bytes are copied into `allocator`; the label
 is the bytes as UTF-8 when they are valid UTF-8, and "" otherwise (an SSID is
 not required to be text, and a label must never invent characters).

 @param allocator : "Allocator for the copied bytes and label"
*>
fn Ssid make_ssid(Allocator allocator, char[] bytes)
{
	if (bytes.len == 0) return { .bytes = { }, .label = "" };
	char[] copy  = alloc::clone_slice(allocator, bytes);
	String label = is_displayable_name((String)bytes) ? ((String)bytes).copy(allocator) : "";
	return { .bytes = copy, .label = label };
}

<* Whether two SSIDs are the same network: the same octets, nothing else. *>
fn bool same_ssid(char[] a, char[] b) @inline => a.len == b.len && mem::equals(a.ptr, b.ptr, a.len);

<*
 Whether `text` may be shown as a name: valid UTF-8 without control characters
 (U+0000-U+001F, U+007F-U+009F) and without bidirectional overrides or isolates
 (U+202A-U+202E, U+2066-U+2069). Those can hide or reorder the text around them,
 so a name that contains them is shown as nothing (its octets stay the identity).
*>
fn bool is_displayable_name(String text)
{
	if (!names::is_utf8_text(text)) return false;
	for (sz i = 0; i < text.len; i++)
	{
		char c = text[i];
		if (c < 0x20 || c == 0x7F) return false;
		if (c == 0xC2 && i + 1 < text.len && text[i + 1] <= 0x9F) return false;
		if (c != 0xE2 || i + 2 >= text.len) continue;
		char middle = text[i + 1];
		char last   = text[i + 2];
		if (middle == 0x80 && last >= 0xAA && last <= 0xAE) return false;
		if (middle == 0x81 && last >= 0xA6 && last <= 0xA9) return false;
	}
	return true;
}
