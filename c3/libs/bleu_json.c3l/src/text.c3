<*
 Text in JSON: quoting, RFC 8259 escaping and UTF-8 validation.

 Output is always valid JSON text. Control characters, quotation marks and
 backslashes are escaped. Bytes that are not well-formed UTF-8 (RFC 3629) are
 replaced by U+FFFD, one replacement for each maximal invalid subsequence, the
 same rule the WHATWG decoder and Python's `errors="replace"` use. Valid
 non-ASCII text is copied unchanged.
*>
module bleu::json;

<* The UTF-8 encoding of U+FFFD REPLACEMENT CHARACTER. *>
const String REPLACEMENT = "\xEF\xBF\xBD";

<* Lower-case hexadecimal digits of the \u00XX escapes. *>
const String HEX_DIGITS = "0123456789abcdef";

<* Bytes below this value are control characters and must be escaped. *>
const char FIRST_PRINTABLE = 0x20;

<* First byte of the two-byte sequences that is not a valid lead (overlong C0, C1). *>
const char FIRST_TWO_BYTE_LEAD = 0xC2;

<*
 Length of the UTF-8 unit that starts at `text[i]`.

 A well-formed sequence yields `valid = true` and its length (1 to 4). A
 malformed one yields `valid = false` and the length of the maximal invalid
 prefix that must become a single U+FFFD. The table of valid ranges follows
 Unicode 15, Table 3-7: no overlong forms, no surrogates, nothing above U+10FFFF.

 @param text : "The text being scanned"
 @param i : "Index of the lead byte"
 @param valid : "True when the sequence is well formed"
 @require i < text.len : "The index is inside the text"
*>
fn sz utf8_unit(String text, sz i, bool* valid)
{
	char lead = text[i];
	*valid = true;
	if (lead < 0x80) return 1;
	char low = 0x80;
	char high = 0xBF;
	sz continuation;
	switch
	{
		case lead >= FIRST_TWO_BYTE_LEAD && lead <= 0xDF:
			continuation = 1;
		case lead == 0xE0:
			continuation = 2;
			low = 0xA0;
		case lead >= 0xE1 && lead <= 0xEC:
			continuation = 2;
		case lead == 0xED:
			continuation = 2;
			high = 0x9F;
		case lead >= 0xEE && lead <= 0xEF:
			continuation = 2;
		case lead == 0xF0:
			continuation = 3;
			low = 0x90;
		case lead >= 0xF1 && lead <= 0xF3:
			continuation = 3;
		case lead == 0xF4:
			continuation = 3;
			high = 0x8F;
		default:
			*valid = false;
			return 1;
	}
	for (sz k = 1; k <= continuation; k++)
	{
		if (i + k >= text.len)
		{
			*valid = false;
			return k;
		}
		char b = text[i + k];
		char lo = k == 1 ? low : 0x80;
		char hi = k == 1 ? high : 0xBF;
		if (b < lo || b > hi)
		{
			*valid = false;
			return k;
		}
	}
	return continuation + 1;
}

<*
 Write a JSON string literal: the text quoted and escaped, invalid UTF-8
 replaced by U+FFFD. Does not check the position in the document; the callers
 do, through `begin_value` or `key`.
*>
fn void? JsonWriter.emit_quoted(&self, String text)
{
	self.emit("\"")!;
	// An empty String may have no storage at all, so it is never sliced.
	if (text.len == 0)
	{
		self.emit("\"")!;
		return;
	}
	sz run = 0; // start of the bytes not yet written
	sz i = 0;
	while (i < text.len)
	{
		char c = text[i];
		if (c >= FIRST_PRINTABLE && c < 0x80 && c != '"' && c != '\\')
		{
			i++;
			continue;
		}
		if (c >= 0x80)
		{
			bool valid;
			sz width = utf8_unit(text, i, &valid);
			if (valid)
			{
				i += width;
				continue;
			}
			self.emit(text[run : i - run])!;
			self.emit(REPLACEMENT)!;
			i += width;
			run = i;
			continue;
		}
		self.emit(text[run : i - run])!;
		self.emit_escape(c)!;
		i++;
		run = i;
	}
	self.emit(text[run : text.len - run])!;
	self.emit("\"")!;
}

<* Write the escape sequence of one byte that must not appear verbatim in a string. *>
fn void? JsonWriter.emit_escape(&self, char c)
{
	switch (c)
	{
		case '"': return self.emit("\\\"");
		case '\\': return self.emit("\\\\");
		case '\b': return self.emit("\\b");
		case '\f': return self.emit("\\f");
		case '\n': return self.emit("\\n");
		case '\r': return self.emit("\\r");
		case '\t': return self.emit("\\t");
		default:
			char[6] escape = { '\\', 'u', '0', '0', HEX_DIGITS[c >> 4], HEX_DIGITS[c & 0xF] };
			return self.emit((String)escape[0:6]);
	}
}

<* Write a string value. Invalid UTF-8 is replaced; see the module note. *>
fn void? JsonWriter.put_string(&self, String text)
{
	self.begin_value()!;
	self.emit_quoted(text)!;
	self.end_value();
}
