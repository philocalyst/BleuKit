<*
 MIME types that another application offers are untrusted: they may be empty, very
 many, very long or full of control characters. This file decides which ones Bleu keeps,
 and which text type it reads when a copy has several. Pure: no I/O, no OS.
*>
module bleu::clipboard;
import std::collections::maybe;

<* Most types kept from one offer. Extra types are dropped, not refused. *>
const usz MAX_MIME_TYPES = 32;
<* Longest type name kept. Longer names are dropped. *>
const usz MAX_MIME_LENGTH = 255;

<*
 Text types in the order Bleu prefers them. UTF-8 first, then the X11 names that
 toolkits still offer alone. `TEXT` and `STRING` are the legacy ICCCM targets.
*>
const String[5] TEXT_TYPES_BY_PREFERENCE = {
	"text/plain;charset=utf-8",
	"UTF8_STRING",
	"text/plain",
	"STRING",
	"TEXT",
};

<*
 Whether `mime` may be kept: non-empty, at most `MAX_MIME_LENGTH` bytes, and only printable
 ASCII (space included, since parameters such as `charset=` contain one).
*>
fn bool is_valid_mime(String mime)
{
	if (mime.len == 0 || mime.len > MAX_MIME_LENGTH) return false;
	foreach (c : mime)
	{
		if (c < ' ' || c > '~') return false;
	}
	return true;
}

<* The ASCII lower-case form of `c`; other bytes are unchanged. *>
fn char lower_ascii(char c) @inline => c >= 'A' && c <= 'Z' ? (char)(c + ('a' - 'A')) : c;

<* ASCII case-insensitive equality. MIME types and the legacy X11 targets are case-insensitive. *>
fn bool equal_ignore_case(String a, String b)
{
	if (a.len != b.len) return false;
	foreach (i, x : a)
	{
		char y = b[i];
		if (lower_ascii(x) != lower_ascii(y)) return false;
	}
	return true;
}

<*
 The type of `offered` that Bleu reads as text: the first entry of `TEXT_TYPES_BY_PREFERENCE`
 that the owner also offered. The returned string is the owner's spelling.

 @return "The matching type, or nothing when the owner offered no text"
*>
fn Maybe{String} choose_text_type(String[] offered)
{
	foreach (preferred : TEXT_TYPES_BY_PREFERENCE)
	{
		foreach (mime : offered)
		{
			if (equal_ignore_case(mime, preferred)) return maybe::value(mime);
		}
	}
	return { };
}

<*
 A deep copy of the valid, distinct types in `offered`, at most `MAX_MIME_TYPES`, in order.
 Invalid and repeated names are dropped; a repeat is one that matches exactly.

 @param allocator : "Where the copies and the array live"
 @return "A new slice of copies, possibly empty"
*>
fn String[] sanitise_offer(Allocator allocator, String[] offered)
{
	if (offered.len == 0) return { };
	String[] kept = alloc::alloc_array(allocator, String, (sz)min((usz)offered.len, MAX_MIME_TYPES));
	usz count = 0;
	foreach (mime : offered)
	{
		if (count == MAX_MIME_TYPES) break;
		if (!is_valid_mime(mime) || contains(kept[0:count], mime)) continue;
		kept[count++] = mime.copy(allocator);
	}
	return kept[0:count];
}

<* Whether `values` holds `wanted` exactly. *>
fn bool contains(String[] values, String wanted) @private
{
	foreach (value : values)
	{
		if (value == wanted) return true;
	}
	return false;
}

<* A deep copy of `values`, in `allocator`. The strings are not checked: they are already kept types. *>
fn String[] copy_strings(Allocator allocator, String[] values)
{
	if (values.len == 0) return { };
	String[] copies = alloc::alloc_array(allocator, String, values.len);
	foreach (i, value : values) copies[i] = value.copy(allocator);
	return copies;
}
