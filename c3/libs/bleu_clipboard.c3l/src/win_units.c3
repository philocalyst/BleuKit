<*
 Pure helpers for the Windows clipboard's UTF-16 data. No OS calls, so this file is not gated
 and its tests run on every host.
*>
module bleu::clipboard;
import std::core::types;

<*
 The length of a NUL-terminated UTF-16 string held in `units`: the index of the first zero
 unit, or the whole length when there is none. Clipboard memory is not always terminated, so
 the scan never passes the end of the slice.
*>
fn usz utf16_length(Char16[] units)
{
	for (usz i = 0; i < units.len; i++)
	{
		if (units[i] == 0) return i;
	}
	return units.len;
}
