<*
 Privacy markers that applications put on the clipboard next to their content. Each
 name is a convention of one platform's clipboard history, not a standard of this
 library; the sources are cited next to each name. Pure: no I/O, no OS.
*>
module bleu::clipboard;

<*
 KDE Klipper keeps an item out of its history when the source offers this type with the
 value `secret` (Klipper historymodel.cpp:1022, read 2026-10-20). Bleu treats the presence
 of the type as the marker, whatever its value, which keeps more out of the history.
*>
const String MARKER_KDE_PASSWORD_HINT = "x-kde-passwordManagerHint";

<*
 nspasteboard.org: `ConcealedType` marks confidential content (for example a password),
 `TransientType` marks content that is on the pasteboard only momentarily. Both are read
 from https://nspasteboard.org/ on 2026-10-20; the names are exact.
*>
const String MARKER_NSPASTEBOARD_CONCEALED = "org.nspasteboard.ConcealedType";
const String MARKER_NSPASTEBOARD_TRANSIENT = "org.nspasteboard.TransientType";

<*
 Windows registered clipboard formats (MS-clipboard-formats, "Cloud Clipboard and
 Clipboard History Formats", read 2026-10-20). Presence of `ExcludeClipboardContentFromMonitorProcessing`
 excludes every format from history and sync. `CanIncludeInClipboardHistory` excludes the
 item from history when its DWORD is 0; the Windows backend lists it only in that case.
*>
const String MARKER_WINDOWS_EXCLUDE_ALL = "ExcludeClipboardContentFromMonitorProcessing";
const String MARKER_WINDOWS_NO_HISTORY = "CanIncludeInClipboardHistory";

<*
 The privacy of a selection from the types its owner offered. CONCEALED wins over
 TRANSIENT, and any marker wins over OPEN.
*>
fn Privacy privacy_of(String[] mime_types)
{
	Privacy result = Privacy.OPEN;
	foreach (mime : mime_types)
	{
		if (mime == MARKER_KDE_PASSWORD_HINT || mime == MARKER_NSPASTEBOARD_CONCEALED
			|| mime == MARKER_WINDOWS_EXCLUDE_ALL)
		{
			return Privacy.CONCEALED;
		}
		if (mime == MARKER_NSPASTEBOARD_TRANSIENT || mime == MARKER_WINDOWS_NO_HISTORY)
		{
			result = Privacy.TRANSIENT;
		}
	}
	return result;
}
