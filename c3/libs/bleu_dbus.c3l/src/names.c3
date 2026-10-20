<*
 Validation of the text values that appear on the wire: UTF-8 strings, object
 paths, interface, member, error and bus names.

 Sources: D-Bus specification, "Basic types" (strict UTF-8, no NUL, noncharacters
 allowed), "Valid Object Paths", "Valid Names" (interface, bus, member and error
 names, maximum name length 255).
*>
module bleu::dbus::names;

<* Longest interface, member, error or bus name, in bytes. *>
const MAX_NAME_LENGTH = 255;

<*
 Strict UTF-8 without NUL: rejects overlong forms, UTF-16 surrogates and code
 points above U+10FFFF. Noncharacters are accepted, as the specification allows.
*>
fn bool is_utf8_text(String text)
{
	usz i = 0;
	usz n = text.len;
	while (i < n)
	{
		char c = text[i];
		if (c == 0) return false;
		if (c < 0x80)
		{
			i++;
			continue;
		}
		usz width;
		uint code;
		if (c >= 0xC2 && c <= 0xDF)
		{
			width = 2;
			code = c & 0x1F;
		}
		else if (c >= 0xE0 && c <= 0xEF)
		{
			width = 3;
			code = c & 0x0F;
		}
		else if (c >= 0xF0 && c <= 0xF4)
		{
			width = 4;
			code = c & 0x07;
		}
		else
		{
			return false;
		}
		if (width > n - i) return false;
		for (usz k = 1; k < width; k++)
		{
			char cont = text[i + k];
			if ((cont & 0xC0) != 0x80) return false;
			code = (code << 6) | (cont & 0x3F);
		}
		// Smallest code point each width may encode (no overlong forms).
		if (width == 3 && code < 0x800) return false;
		if (width == 4 && (code < 0x10000 || code > 0x10FFFF)) return false;
		if (code >= 0xD800 && code <= 0xDFFF) return false;
		i += width;
	}
	return true;
}

<*
 True for a syntactically valid object path: `/`, or `/` separated elements of
 `[A-Za-z0-9_]`, none empty, no trailing slash.
*>
fn bool is_object_path(String path)
{
	if (path.len == 0 || path[0] != '/') return false;
	if (path.len == 1) return true;
	if (path[path.len - 1] == '/') return false;
	usz start = 1;
	for (usz i = 1; i <= path.len; i++)
	{
		if (i == path.len || path[i] == '/')
		{
			if (i == start) return false; // empty element: "//" or a leading slash
			start = i + 1;
			continue;
		}
		if (!is_word_char(path[i])) return false;
	}
	return true;
}

<*
 True for an interface name or an error name: at least two `.`-separated
 elements of `[A-Za-z0-9_]`, none starting with a digit.
*>
fn bool is_interface(String name) => name.len <= MAX_NAME_LENGTH && is_dotted(name, false, false, 2);

<* True for an error name; the same rules as an interface name. *>
fn bool is_error_name(String name) => is_interface(name);

<*
 True for a member (method or signal) name: non-empty, `[A-Za-z0-9_]`, not
 starting with a digit, no dots.
*>
fn bool is_member(String name)
{
	if (name.len == 0 || name.len > MAX_NAME_LENGTH) return false;
	if (name[0] >= '0' && name[0] <= '9') return false;
	foreach (c : name)
	{
		if (!is_word_char(c)) return false;
	}
	return true;
}

<*
 True for a bus name. A unique name (`:1.42`) starts with `:`; its elements
 may start with a digit. A well-known name needs at least two elements, none
 starting with a digit. Both may contain `-`.
*>
fn bool is_bus_name(String name)
{
	if (name.len == 0 || name.len > MAX_NAME_LENGTH) return false;
	if (name[0] == ':') return is_dotted(name[1:name.len], true, true, 2);
	return is_dotted(name, true, false, 2);
}

<* True for a unique connection name such as `:1.42`. *>
fn bool is_unique_name(String name) => name.len > 1 && name[0] == ':' && is_bus_name(name);

// `[A-Za-z0-9_]`, plus `-` when `hyphen` is allowed.
fn bool is_word_char(char c, bool hyphen = false) @inline
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || (hyphen && c == '-');
}

// At least `min_elements` non-empty elements separated by '.', each made of
// word characters. Elements may not start with a digit unless `digit_start_ok`
// (only the elements of a unique connection name may).
fn bool is_dotted(String name, bool hyphen, bool digit_start_ok, usz min_elements) @private
{
	usz elements = 0;
	usz start = 0;
	for (usz i = 0; i <= name.len; i++)
	{
		if (i == name.len || name[i] == '.')
		{
			if (i == start) return false;
			if (!digit_start_ok && name[start] >= '0' && name[start] <= '9') return false;
			elements++;
			start = i + 1;
			continue;
		}
		if (!is_word_char(name[i], hyphen)) return false;
	}
	return elements >= min_elements;
}
