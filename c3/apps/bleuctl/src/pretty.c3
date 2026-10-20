<*
 Indent one line of compact JSON for people to read. The text is not parsed: the
 scanner only tracks strings and brackets, so it works on any JSON the daemon writes.
*>
module bleuctl::pretty;

<* Spaces per nesting level. *>
const usz INDENT = 2;

<*
 Append `compact` to `out` with one member or element per line.

 @param compact : "One JSON value; whitespace outside strings is dropped"
*>
fn void format(String compact, DString* out)
{
	usz depth = 0;
	bool in_string = false;
	bool escaped = false;
	for (usz i = 0; i < compact.len; i++)
	{
		char c = compact[i];
		if (in_string)
		{
			out.append_char(c);
			if (escaped)
			{
				escaped = false;
			}
			else if (c == '\\')
			{
				escaped = true;
			}
			else if (c == '"')
			{
				in_string = false;
			}
			continue;
		}
		if (c == '"')
		{
			in_string = true;
			out.append_char(c);
		}
		else if (c == '{' || c == '[')
		{
			out.append_char(c);
			// An empty container stays on its line.
			if (i + 1 < compact.len && (compact[i + 1] == '}' || compact[i + 1] == ']'))
			{
				out.append_char(compact[i + 1]);
				i++;
			}
			else
			{
				depth++;
				newline(out, depth);
			}
		}
		else if (c == '}' || c == ']')
		{
			depth = depth > 0 ? depth - 1 : 0;
			newline(out, depth);
			out.append_char(c);
		}
		else if (c == ',')
		{
			out.append_char(c);
			newline(out, depth);
		}
		else if (c == ':')
		{
			out.append(": ");
		}
		else if (c != ' ' && c != '\n' && c != '\r' && c != '\t')
		{
			// Whitespace between tokens is replaced by the layout above; everything else is copied.
			out.append_char(c);
		}
	}
}

<* Start a new line indented for `depth` levels. *>
fn void newline(DString* out, usz depth) @private
{
	out.append_char('\n');
	for (usz i = 0; i < depth * INDENT; i++) out.append_char(' ');
}
