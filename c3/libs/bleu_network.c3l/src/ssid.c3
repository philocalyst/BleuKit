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
	if (bytes.len == 0) return { .bytes = {}, .label = "" };
	char[] copy   = alloc::clone_slice(allocator, bytes);
	String label  = names::is_utf8_text((String)bytes) ? ((String)bytes).copy(allocator) : "";
	return { .bytes = copy, .label = label };
}

<* Whether two SSIDs are the same network: the same octets, nothing else. *>
fn bool same_ssid(char[] a, char[] b) @inline => a.len == b.len && mem::equal(a.ptr, b.ptr, a.len);
