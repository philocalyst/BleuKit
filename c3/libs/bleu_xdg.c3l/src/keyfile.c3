<*
 Desktop-Entry-flavoured key files: the INI-like syntax shared by `.desktop`
 files, icon themes, `mimeapps.list` and `mimeinfo.cache`.

 Source: Desktop Entry Specification 1.5
 (https://specifications.freedesktop.org/desktop-entry-spec/latest/), sections
 "Basic format", "Entries", "Value types", "Localized values for keys" and
 "Locale matching". Cross-checked against GLib's `gkeyfile.c`
 (https://github.com/GNOME/glib/blob/main/glib/gkeyfile.c): its escape table
 (`\s \n \t \r \\`, an error for any other escape and for a trailing backslash)
 and its key-name rule (anything except `=`, `[` and `]`), which is why
 `KeySyntax.PERMISSIVE` exists. GLib refuses `\;` outside lists; this module
 accepts it everywhere.

 A file is UTF-8, optionally starting with a byte-order mark. Lines end in LF,
 or CRLF (the CR is dropped). Blank lines and lines starting with `#` are
 comments. `[Group Name]` opens a group; `Key=Value` and `Key[locale]=Value`
 add an entry to the current group. Spaces and tabs around names and values are
 not part of them. Group names are printable ASCII; key names are `A-Za-z0-9-`.

 Key names are checked against the Desktop Entry alphabet by default. Files whose
 keys are MIME types (`mimeapps.list`, `mimeinfo.cache`) are read with
 `KeySyntax.PERMISSIVE` instead, which accepts any printable ASCII name.

 Malformed input is rejected, never guessed at. Every error carries the line
 number as its native code (`error::last().code`), so a message can point at
 the offending line. Duplicate groups and duplicate keys (same name and locale)
 in one group are errors, as the specification's "Basic format" section requires.

 Values are stored undecoded and decoded on access: the string escapes `\s \n
 \t \r \\` are decoded, and list values are split on unescaped `;`. The escape
 `\;` is accepted in every value, not only in lists, which is more lenient than
 the specification.
*>
module bleu::xdg::keyfile;
import bleu::error, std::io, std::collections::list;

<*
 The largest key file read from disk, in bytes. Desktop entries, index.theme and the
 MIME association lists are a few kilobytes. A directory a user can write to must not
 make the reader load a gigabyte.
*>
const long MAX_FILE_BYTES = 1024 * 1024;

const char LIST_SEPARATOR      = ';';
const uint UTF8_ONE_BYTE_LIMIT   = 0x80;
const uint UTF8_TWO_BYTE_LIMIT   = 0x800;
const uint UTF8_THREE_BYTE_LIMIT = 0x10000;
const uint UTF8_MAX_CODE_POINT   = 0x10FFFF;
const uint UTF8_FIRST_SURROGATE  = 0xD800;
const uint UTF8_LAST_SURROGATE   = 0xDFFF;
const uint UTF8_TWO_FIRST        = 0xC2;
const uint UTF8_TWO_LAST         = 0xDF;
const uint UTF8_THREE_FIRST      = 0xE0;
const uint UTF8_THREE_LAST       = 0xEF;
const uint UTF8_FOUR_FIRST       = 0xF0;
const uint UTF8_FOUR_LAST        = 0xF4;
const uint UTF8_TWO_MASK         = 0x1F;
const uint UTF8_THREE_MASK       = 0x0F;
const uint UTF8_FOUR_MASK        = 0x07;
const uint UTF8_CONTINUATION_TAG  = 0x80;
const uint UTF8_CONTINUATION_MASK = 0x3F;
const uint UTF8_CONTINUATION_BITS = 6;
const char ESCAPE              = '\\';
const char COMMENT_START       = '#';
const char GROUP_OPEN          = '[';
const char GROUP_CLOSE         = ']';
const char KEY_VALUE_SEPARATOR = '=';
const char CARRIAGE_RETURN     = '\r';
const char LINE_FEED           = '\n';
const char FIRST_PRINTABLE     = ' ';
const char LAST_PRINTABLE      = '~';
const String UTF8_BOM          = "\xEF\xBB\xBF";
const String BLANKS            = " \t";
const int LOCALE_FORMS         = 4;

<*
 One `Key[locale]=Value` line. `raw` is the value as written, with escapes
 still in place; it is a view into the owning `KeyFile`'s text.
*>
struct Entry
{
	String key;
	String locale;
	String raw;
}

<* A `[Group]` and its entries, in file order. *>
struct Group
{
	String name;
	List{Entry} entries;
}

<*
 A parsed key file. It owns a copy of the source text, and every name and raw
 value is a view into that copy, so `free` releases everything at once.
*>
struct KeyFile
{
	Allocator allocator;
	String text;
	List{Group} groups;
}

<*
 How key names are checked. `STRICT` accepts `A-Za-z0-9-` (the Desktop Entry
 rule); `PERMISSIVE` accepts any printable ASCII name, for MIME-type keys.
*>
enum KeySyntax : char
{
	STRICT,
	PERMISSIVE,
}

<*
 A parsed locale: `lang_COUNTRY.ENCODING@MODIFIER` with the encoding dropped.
 Absent parts are empty strings.
*>
struct Locale
{
	String lang;
	String country;
	String modifier;
}

<*
 Parse a key file with the Desktop Entry key rule (`KeySyntax.STRICT`).

 @param [&inout] allocator : "Allocator for the copy of the text and the entry lists"
 @param source : "The complete file contents, UTF-8"
 @return "A key file that the caller must `free`"
 @return? error::PROTOCOL : "A line is malformed, a group or key is duplicated, or an escape is invalid; the line number is the native code in `error::last()`"
*>
fn KeyFile? parse(Allocator allocator, String source) => parse_with(allocator, source, STRICT);

<*
 Parse a key file, checking key names as `syntax` says. See `parse`.
*>
fn KeyFile? parse_with(Allocator allocator, String source, KeySyntax syntax)
{
	// The file is UTF-8, and GLib refuses other bytes too; they would reach names and values as they are.
	if (!well_formed_utf8(source)) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "the key file is not UTF-8")~;
	KeyFile file = { .allocator = allocator, .text = source.copy(allocator) };
	file.groups.init(allocator);
	defer catch file.free();
	String text = file.text;
	if (text.starts_with(UTF8_BOM)) text = text[UTF8_BOM.len:text.len - UTF8_BOM.len];
	sz position = 0;
	int line_no = 0;
	while (position < text.len)
	{
		line_no++;
		String line = blank_trim(next_line(text, &position));
		if (line.len == 0 || line[0] == COMMENT_START) continue;
		if (line[0] == GROUP_OPEN)
		{
			open_group(&file, line, line_no)!;
		}
		else
		{
			add_entry(&file, line, line_no, syntax)!;
		}
	}
	return file;
}

<* Release the text, the entries and the groups. The key file is unusable afterwards. *>
fn void KeyFile.free(&self)
{
	foreach (&group : self.groups) group.entries.free();
	self.groups.free();
	alloc::free(self.allocator, self.text.ptr);
	self.text = "";
}

<* Whether a group with this exact name exists. *>
fn bool KeyFile.has_group(&self, String group) => self.find_group(group) != null;

<* Whether `key` (without a locale) exists in `group`. *>
fn bool KeyFile.has_key(&self, String group, String key) => self.find_entry(group, key) != null;

<*
 A string value, decoded. Use `get_localized_string` for `localestring` keys.

 @param [&inout] allocator : "Allocator for the decoded string"
 @return? NOT_FOUND : "The group or key does not exist"
 @return? error::PROTOCOL : "The value holds an invalid escape"
*>
fn String? KeyFile.get_string(&self, Allocator allocator, String group, String key)
{
	Entry* entry = self.find_entry(group, key);
	if (!entry) return NOT_FOUND~;
	return decode_string(entry.raw, allocator);
}

<*
 A `localestring` value, chosen by the locale matching order of the
 specification: `lang_COUNTRY@MODIFIER`, `lang_COUNTRY`, `lang@MODIFIER`,
 `lang`, then the unlocalised key. The encoding part of either side is ignored.

 @param [&inout] allocator : "Allocator for the decoded string"
 @param locale : "The current LC_MESSAGES value, for example de_DE.UTF-8@euro; empty for none"
 @return? NOT_FOUND : "The group or key does not exist in any matching form"
 @return? error::PROTOCOL : "The chosen value holds an invalid escape"
*>
fn String? KeyFile.get_localized_string(&self, Allocator allocator, String group, String key, String locale)
{
	Entry* entry = self.find_localized(group, key, locale);
	if (!entry) return NOT_FOUND~;
	return decode_string(entry.raw, allocator);
}

<*
 A `strings` value: a `;`-separated list, decoded. A trailing empty element
 needs its own `;`, so `a;;` has two elements and `a;` has one.

 @param [&inout] allocator : "Allocator for the array and its strings"
 @return? NOT_FOUND : "The group or key does not exist"
 @return? error::PROTOCOL : "The value holds an invalid escape"
*>
fn String[]? KeyFile.get_strings(&self, Allocator allocator, String group, String key)
{
	Entry* entry = self.find_entry(group, key);
	if (!entry) return NOT_FOUND~;
	return decode_list(entry.raw, allocator);
}

<*
 A `boolean` value, which must be exactly `true` or `false`.

 @return? NOT_FOUND : "The group or key does not exist"
 @return? error::PROTOCOL : "The value is neither `true` nor `false`"
*>
fn bool? KeyFile.get_boolean(&self, String group, String key)
{
	Entry* entry = self.find_entry(group, key);
	if (!entry) return NOT_FOUND~;
	if (entry.raw == "true") return true;
	if (entry.raw == "false") return false;
	return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "boolean key '%s' holds '%s'", key, entry.raw)~;
}

<*
 A `numeric` value, as read by scanf's `%f` in the C locale.

 @return? NOT_FOUND : "The group or key does not exist"
 @return? error::PROTOCOL : "The value is not a number"
*>
fn double? KeyFile.get_numeric(&self, String group, String key)
{
	Entry* entry = self.find_entry(group, key);
	if (!entry) return NOT_FOUND~;
	if (try number = entry.raw.to_double()) return number;
	return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "numeric key '%s' holds '%s'", key, entry.raw)~;
}

<*
 Split a locale string into its parts. The encoding is discarded.

 @param value : "A locale such as de_DE.UTF-8@euro, de, or the empty string"
*>
fn Locale parse_locale(String value)
{
	String rest     = value;
	String modifier = "";
	if (try at = rest.index_of_char('@'))
	{
		modifier = rest[at + 1:rest.len - at - 1];
		rest = rest[:at];
	}
	if (try dot = rest.index_of_char('.')) rest = rest[:dot];
	if (try underscore = rest.index_of_char('_'))
	{
		return {
			.lang = rest[:underscore],
			.country = rest[underscore + 1:rest.len - underscore - 1],
			.modifier = modifier
		};
	}
	return { .lang = rest, .modifier = modifier };
}

// The `form`-th candidate for `wanted`, in matching order: with both country and
// modifier, with country, with modifier, then the bare language. Forms that need
// a part `wanted` lacks do not exist.
fn Locale? candidate(Locale wanted, int form) @local
{
	bool has_country  = wanted.country.len > 0;
	bool has_modifier = wanted.modifier.len > 0;
	switch (form)
	{
		case 0:
			if (!has_country || !has_modifier) return NOT_FOUND~;
			return { .lang = wanted.lang, .country = wanted.country, .modifier = wanted.modifier };
		case 1:
			if (!has_country) return NOT_FOUND~;
			return { .lang = wanted.lang, .country = wanted.country };
		case 2:
			if (!has_modifier) return NOT_FOUND~;
			return { .lang = wanted.lang, .modifier = wanted.modifier };
		default:
			return { .lang = wanted.lang };
	}
}

// The localised entry for `locale` in matching order, else the unlocalised one.
fn Entry* KeyFile.find_localized(&self, String group, String key, String locale)
{
	if (locale.len == 0) return self.find_entry(group, key);
	Locale wanted = parse_locale(locale);
	for (int form = 0; form < LOCALE_FORMS; form++)
	{
		if (try wanted_form = candidate(wanted, form))
		{
			Entry* entry = self.find_entry_in_locale(group, key, wanted_form);
			if (entry) return entry;
		}
	}
	return self.find_entry(group, key);
}

// The entry `key` in `group` whose locale, encoding dropped, equals `wanted`.
fn Entry* KeyFile.find_entry_in_locale(&self, String group, String key, Locale wanted)
{
	Group* found = self.find_group(group);
	if (!found) return null;
	foreach (&entry : found.entries)
	{
		if (entry.key != key || entry.locale.len == 0) continue;
		Locale have = parse_locale(entry.locale);
		if (have.lang == wanted.lang && have.country == wanted.country
			&& have.modifier == wanted.modifier) return entry;
	}
	return null;
}

// The group named `name`, or null.
fn Group* KeyFile.find_group(&self, String name)
{
	foreach (&group : self.groups)
	{
		if (group.name == name) return group;
	}
	return null;
}

// The unlocalised entry `key` of `group`, or null.
fn Entry* KeyFile.find_entry(&self, String group, String key)
{
	Group* found = self.find_group(group);
	if (!found) return null;
	foreach (&entry : found.entries)
	{
		if (entry.key == key && entry.locale.len == 0) return entry;
	}
	return null;
}

// Begin a `[name]` group. Rejects an empty, non-printable or duplicate name.
fn void? open_group(KeyFile* file, String line, int line_no) @local
{
	if (line[^1] != GROUP_CLOSE) return error::raise(
		error::PROTOCOL,
		error::Domain.INTERNAL,
		line_no,
		"line %d: group header is not closed",
		line_no
	)~;
	String name = line[1:line.len - 2];
	if (name.len == 0) return error::raise(
		error::PROTOCOL,
		error::Domain.INTERNAL,
		line_no,
		"line %d: empty group name",
		line_no
	)~;
	foreach (c : name)
	{
		if (c < FIRST_PRINTABLE || c > LAST_PRINTABLE || c == GROUP_OPEN || c == GROUP_CLOSE)
		{
			return error::raise(
				error::PROTOCOL,
				error::Domain.INTERNAL,
				line_no,
				"line %d: group name holds a character outside printable ASCII",
				line_no
			)~;
		}
	}
	if (file.find_group(
		name
	)) return error::raise(
		error::PROTOCOL,
		error::Domain.INTERNAL,
		line_no,
		"line %d: duplicate group '%s'",
		line_no,
		name
	)~;
	Group group = { .name = name };
	group.entries.init(file.allocator);
	file.groups.push(group);
	return;
}

// Add `Key[locale]=Value` to the current group.
fn void? add_entry(KeyFile* file, String line, int line_no, KeySyntax syntax) @local
{
	if (file.groups.is_empty()) return error::raise(
		error::PROTOCOL,
		error::Domain.INTERNAL,
		line_no,
		"line %d: entry before the first group",
		line_no
	)~;
	if (!line.contains_char(
		KEY_VALUE_SEPARATOR
	)) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, line_no, "line %d: missing '='", line_no)~;
	sz delimiter = line.index_of_char(KEY_VALUE_SEPARATOR)!!;
	Entry entry  = split_key(blank_trim(line[:delimiter]), line_no, syntax)!;
	entry.raw = blank_trim(line[delimiter + 1:line.len - delimiter - 1]);
	validate_escapes(entry.raw, line_no)!;
	Group* current = file.groups.get_ref(file.groups.len() - 1);
	foreach (existing : current.entries)
	{
		if (existing.key == entry.key && existing.locale == entry.locale)
		{
			return error::raise(
				error::PROTOCOL,
				error::Domain.INTERNAL,
				line_no,
				"line %d: duplicate key '%s'",
				line_no,
				entry.key
			)~;
		}
	}
	current.entries.push(entry);
	return;
}

// Split `Key` or `Key[locale]` into an entry whose value is still empty.
fn Entry? split_key(String name, int line_no, KeySyntax syntax) @local
{
	String key    = name;
	String locale = "";
	if (try open = name.index_of_char('['))
	{
		if (name[^1] != ']') return error::raise(
			error::PROTOCOL,
			error::Domain.INTERNAL,
			line_no,
			"line %d: locale of a key is not closed",
			line_no
		)~;
		key = name[:open];
		locale = name[open + 1:name.len - open - 2];
		if (locale.len == 0 || locale.contains_char(
			GROUP_OPEN
		)) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, line_no, "line %d: malformed locale", line_no)~;
	}
	if (key.len == 0) return error::raise(
		error::PROTOCOL,
		error::Domain.INTERNAL,
		line_no,
		"line %d: empty key name",
		line_no
	)~;
	foreach (c : key)
	{
		if (!is_key_char(
			c,
			syntax
		)) return error::raise(
			error::PROTOCOL,
			error::Domain.INTERNAL,
			line_no,
			"line %d: key name holds '%c'",
			line_no,
			c
		)~;
	}
	return { .key = key, .locale = locale };
}

// The characters allowed in key names: A-Za-z0-9- when strict; any printable ASCII
// except the group brackets when permissive.
fn bool is_key_char(char c, KeySyntax syntax) @inline
{
	if (syntax == PERMISSIVE) return c >= FIRST_PRINTABLE && c <= LAST_PRINTABLE && c != GROUP_OPEN && c != GROUP_CLOSE;
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-';
}

// The next line of `text` starting at `*position`, without its line feed and
// carriage return; `*position` moves past the line feed.
fn String next_line(String text, sz* position) @local
{
	sz start = *position;
	sz end   = start;
	while (end < text.len && text[end] != LINE_FEED) end++;
	*position = end < text.len ? end + 1 : end;
	String line = text[start:end - start];
	if (line.len > 0 && line[^1] == CARRIAGE_RETURN) line = line[:line.len - 1];
	return line;
}

fn String blank_trim(String s) @inline => s.trim(BLANKS);

// Checks that every escape in `raw` is one the specification (or `\;`) allows.
fn void? validate_escapes(String raw, int line_no) @local
{
	sz i = 0;
	while (i < raw.len)
	{
		if (raw[i] != ESCAPE)
		{
			i++;
			continue;
		}
		if (catch decode_escape(
			raw,
			&i
		)) return error::raise(
			error::PROTOCOL,
			error::Domain.INTERNAL,
			line_no,
			"line %d: invalid escape sequence",
			line_no
		)~;
	}
	return;
}

<*
 Decode the escape sequence whose backslash is at `raw[*index]`, and move
 `*index` past it.

 @return? error::PROTOCOL : "The backslash ends the value, or is followed by a character that has no meaning"
*>
fn char? decode_escape(String raw, sz* index) @local
{
	sz i = *index;
	if (i + 1 >= raw.len) return error::PROTOCOL~;
	*index = i + 2;
	switch (raw[i + 1])
	{
		case 's': return ' ';
		case 'n': return '\n';
		case 't': return '\t';
		case 'r': return '\r';
		case '\\': return '\\';
		case ';': return ';';
		default: return error::PROTOCOL~;
	}
}

<* Decode the escapes of a plain value. *>
fn String? decode_string(String raw, Allocator allocator) @local
{
	DString out;
	out.init(tmem, raw.len);
	sz i = 0;
	while (i < raw.len)
	{
		if (raw[i] != ESCAPE)
		{
			out.append_char(raw[i]);
			i++;
			continue;
		}
		out.append_char(decode_escape(raw, &i)!);
	}
	return out.copy_str(allocator);
}

<*
 Decode a `;`-separated list. An element is kept when it holds any characters
 of the value, so a lone trailing separator adds nothing.
*>
fn String[]? decode_list(String raw, Allocator allocator) @local
{
	List{String} items;
	items.tinit();
	DString current;
	current.init(tmem, raw.len);
	bool has_characters = false;
	sz i                = 0;
	while (i < raw.len)
	{
		char c = raw[i];
		if (c == LIST_SEPARATOR)
		{
			items.push(current.str_view().copy(allocator));
			current.clear();
			has_characters = false;
			i++;
			continue;
		}
		if (c == ESCAPE)
		{
			current.append_char(decode_escape(raw, &i)!);
		}
		else
		{
			current.append_char(c);
			i++;
		}
		has_characters = true;
	}
	if (has_characters) items.push(current.str_view().copy(allocator));
	return items.to_aligned_array(allocator);
}

<*
 The whole key file at `path`, in temporary memory. A file over `MAX_FILE_BYTES` is
 refused before it is read. Errors keep the OS's kind: a missing file is NOT_FOUND and
 a refused one is PERMISSION_DENIED; other failures are BACKEND_FAILURE.

 @return? NOT_FOUND : "The file does not exist"
 @return? error::PERMISSION_DENIED : "The OS refuses to read the file"
 @return? error::OUT_OF_RANGE : "The file is larger than `MAX_FILE_BYTES`"
 @return? error::BACKEND_FAILURE : "The file exists but could not be read for another reason"
*>
fn char[]? load_file(String path)
{
	char[]? bytes = read_capped(path);
	if (catch err = bytes)
	{
		if (err == io::FILE_NOT_FOUND || err == io::PATH_COULD_NOT_BE_FOUND) return NOT_FOUND~;
		if (err == io::NO_PERMISSION) return error::PERMISSION_DENIED~;
		if (err == error::OUT_OF_RANGE) return err~;
		return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, 0, "could not read %s", path)~;
	}
	return bytes;
}

// `path` read whole, after its size has been checked against `MAX_FILE_BYTES`.
fn char[]? read_capped(String path) @local
{
	long size = io::file::get_size(path)!;
	if (size > MAX_FILE_BYTES) return error::raise(
		error::OUT_OF_RANGE,
		error::Domain.INTERNAL,
		0,
		"%s is %d bytes, more than the %d the reader accepts",
		path,
		size,
		MAX_FILE_BYTES
	)~;
	return io::file::load(tmem, path);
}

// The UTF-8 length of the sequence at byte `at`, or 0 when it is not well formed
// (RFC 3629: no overlong forms, no surrogates, nothing above U+10FFFF).
fn usz utf8_length_at(String bytes, usz at) @local
{
	uint lead = (uint)(bytes[at] & 0xFF);
	if (lead < UTF8_ONE_BYTE_LIMIT) return 1;
	usz width;
	uint value;
	uint minimum;
	if (lead >= UTF8_TWO_FIRST && lead <= UTF8_TWO_LAST)
	{
		width = 2;
		value = lead & UTF8_TWO_MASK;
		minimum = UTF8_ONE_BYTE_LIMIT;
	}
	else if (lead >= UTF8_THREE_FIRST && lead <= UTF8_THREE_LAST)
	{
		width = 3;
		value = lead & UTF8_THREE_MASK;
		minimum = UTF8_TWO_BYTE_LIMIT;
	}
	else if (lead >= UTF8_FOUR_FIRST && lead <= UTF8_FOUR_LAST)
	{
		width = 4;
		value = lead & UTF8_FOUR_MASK;
		minimum = UTF8_THREE_BYTE_LIMIT;
	}
	else
	{
		return 0;
	}
	if (at + width > bytes.len) return 0;
	for (usz i = 1; i < width; i++)
	{
		uint continuation = (uint)(bytes[at + i] & 0xFF);
		if ((continuation & ~UTF8_CONTINUATION_MASK) != UTF8_CONTINUATION_TAG) return 0;
		value = (value << UTF8_CONTINUATION_BITS) | (continuation & UTF8_CONTINUATION_MASK);
	}
	if (value < minimum || value > UTF8_MAX_CODE_POINT || (value >= UTF8_FIRST_SURROGATE && value <= UTF8_LAST_SURROGATE)) return 0;
	return width;
}

// Whether `bytes` is well-formed UTF-8 throughout.
fn bool well_formed_utf8(String bytes) @local
{
	usz at = 0;
	while (at < bytes.len)
	{
		usz width = utf8_length_at(bytes, at);
		if (width == 0) return false;
		at += width;
	}
	return true;
}
