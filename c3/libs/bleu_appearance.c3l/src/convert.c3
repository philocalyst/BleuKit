<*
 Conversions between the desktops' spellings and Bleu's types. Pure: no I/O
 and no native calls, so every rule here is covered by a `@test`.

 Sources: the Settings portal values (`org.freedesktop.appearance`, D-Bus
 specification of xdg-desktop-portal Settings, `data/org.freedesktop.portal.Settings.xml`,
 raw.githubusercontent.com/flatpak/xdg-desktop-portal); the GNOME schema values
 (`org.gnome.desktop.interface.gschema.xml.in`, gsettings-desktop-schemas);
 the `gsettings get` text form (GVariant text format, GLib `gvariant-serialiser`);
 the file URI rules of RFC 3986 section 2.3 for the unreserved set.
*>
module bleu::appearance::convert;
import std::collections::maybe, bleu::appearance, bleu::error, bleu::unit;

<* Largest value of one colour channel byte, as a float. *>
const float CHANNEL_MAX = 255.0f;

<* Scheme of the Settings portal's `color-scheme` (u): 1 prefers dark, 2 prefers light, other values no preference. *>
fn ColorScheme scheme_from_portal(uint value)
{
	switch (value)
	{
		case 1: return DARK;
		case 2: return LIGHT;
		default: return NO_PREFERENCE;
	}
}

<* The GNOME `color-scheme` enum: 'prefer-dark', 'prefer-light', or 'default'. *>
fn ColorScheme scheme_from_gnome(String value)
{
	switch (value)
	{
		case "prefer-dark": return DARK;
		case "prefer-light": return LIGHT;
		default: return NO_PREFERENCE;
	}
}

<* The GNOME `color-scheme` spelling of `scheme`. *>
fn String scheme_to_gnome(ColorScheme scheme)
{
	switch (scheme)
	{
		case DARK: return "prefer-dark";
		case LIGHT: return "prefer-light";
		case NO_PREFERENCE: return "default";
	}
}

<*
 Windows `AppsUseLightTheme` (REG_DWORD): 0 is dark, 1 is light. Windows
 always has one of the two, so there is no "no preference" value.
*>
fn ColorScheme scheme_from_apps_use_light_theme(uint value) => value == 0 ? DARK : LIGHT;

<* The `AppsUseLightTheme` value for a scheme that is not NO_PREFERENCE. *>
fn uint apps_use_light_theme(ColorScheme scheme) => scheme == DARK ? 0 : 1;

<* Contrast of the Settings portal's `contrast` (u): 1 is higher contrast. *>
fn Contrast contrast_from_portal(uint value) => value == 1 ? HIGH : NORMAL;

<* `reduced-motion` of the Settings portal (u): 1 asks for less motion. *>
fn bool reduced_from_portal(uint value) => value == 1;

<*
 An accent colour from its three channels (the portal's `(ddd)`, sRGB). A
 channel that is not a number in [0, 1] makes the whole colour unset.
*>
fn Maybe{Rgb} accent_from_channels(double red, double green, double blue)
{
	if (!in_unit_range(red) || !in_unit_range(green) || !in_unit_range(blue)) return { };
	Rgb rgb = { .red = (Level)(float)red, .green = (Level)(float)green, .blue = (Level)(float)blue };
	return maybe::value(rgb);
}

// NaN fails both comparisons, so it is out of range.
fn bool in_unit_range(double channel) @private => channel >= 0.0 && channel <= 1.0;

<*
 A DWM `AccentColor` (REG_DWORD) read as 0xAABBGGRR: the low byte is red and
 the alpha byte is ignored.
*>
fn Maybe{Rgb} accent_from_abgr(uint value)
{
	Rgb rgb = {
		.red = (Level)((float)(value & 0xff) / CHANNEL_MAX),
		.green = (Level)((float)((value >> 8) & 0xff) / CHANNEL_MAX),
		.blue = (Level)((float)((value >> 16) & 0xff) / CHANNEL_MAX),
	};
	return maybe::value(rgb);
}

<* The GNOME `clock-format` enum: '12h' or '24h'. *>
fn ClockFormat clock_from_gnome(String value)
{
	switch (value)
	{
		case "12h": return H12;
		case "24h": return H24;
		default: return UNKNOWN;
	}
}

<* A GNOME `text-scaling-factor` (a double). Unset when the text is not a number. *>
fn Maybe{float} scale_from_gnome(String value)
{
	if (try scale = value.to_float()) return maybe::value(scale);
	return { };
}

<* A GVariant boolean as `gsettings get` prints it: `true` or `false`. *>
fn bool? bool_from_gnome(String value)
{
	switch (value)
	{
		case "true": return true;
		case "false": return false;
		default: return error::INVALID_ARGUMENT~;
	}
}

<*
 The text of a GVariant string as `gsettings get` prints it: 'text', where `\\`
 and `\'` stand for a backslash and a quote.

 @param allocator : "Allocator for the returned text"
 @return? error::PROTOCOL : "The text is not a quoted GVariant string"
*>
fn String? unquote(Allocator allocator, String printed)
{
	String text = printed.trim();
	if (text.len < 2 || text[0] != '\'' || text[text.len - 1] != '\'') return error::PROTOCOL~;
	String inner = text[1:text.len - 2];
	char[] out   = alloc::new_array(allocator, char, inner.len);
	usz n        = 0;
	for (usz i = 0; i < inner.len; i++)
	{
		char c = inner[i];
		if (c == '\\' && i + 1 < inner.len)
		{
			i++;
			c = inner[i];
		}
		out[n++] = c;
	}
	return (String)out[0:n];
}

<*
 A GVariant string literal for `text`, as `gsettings set` reads it: quoted,
 with `\\` and `\'` escaped.

 @param allocator : "Allocator for the returned text"
*>
fn String quote(Allocator allocator, String text)
{
	char[] out = alloc::new_array(allocator, char, text.len * 2 + 2);
	usz n      = 0;
	out[n++] = '\'';
	foreach (c : text)
	{
		if (c == '\\' || c == '\'') out[n++] = '\\';
		out[n++] = c;
	}
	out[n++] = '\'';
	return (String)out[0:n];
}

const String FILE_SCHEME = "file://";
const String HEX_DIGITS  = "0123456789ABCDEF";

<*
 The `file://` URI of an absolute path. Every byte outside the unreserved set
 (letters, digits, `-._~`) and `/` is written as %XX.

 @param allocator : "Allocator for the returned URI"
*>
fn String file_uri(Allocator allocator, String path)
{
	char[] out = alloc::new_array(allocator, char, path.len * 3 + FILE_SCHEME.len);
	usz n      = 0;
	foreach (c : FILE_SCHEME) out[n++] = c;
	foreach (c : path)
	{
		if (is_unreserved(c))
		{
			out[n++] = c;
			continue;
		}
		out[n++] = '%';
		out[n++] = HEX_DIGITS[(usz)c >> 4];
		out[n++] = HEX_DIGITS[(usz)c & 0xf];
	}
	return (String)out[0:n];
}

fn bool is_unreserved(char c) @private
{
	if (c >= 'a' && c <= 'z') return true;
	if (c >= 'A' && c <= 'Z') return true;
	if (c >= '0' && c <= '9') return true;
	return c == '-' || c == '.' || c == '_' || c == '~' || c == '/';
}

<*
 The path of a `file://` URI, with %XX escapes decoded.

 @param allocator : "Allocator for the returned path"
 @return? error::INVALID_ARGUMENT : "The URI does not start with file://"
*>
fn String? path_from_file_uri(Allocator allocator, String uri)
{
	if (!uri.starts_with(FILE_SCHEME)) return error::INVALID_ARGUMENT~;
	String rest = uri[FILE_SCHEME.len:uri.len - FILE_SCHEME.len];
	char[] out  = alloc::new_array(allocator, char, rest.len);
	usz n       = 0;
	for (usz i = 0; i < rest.len; i++)
	{
		if (rest[i] == '%' && i + 2 < rest.len)
		{
			int high = hex_value(rest[i + 1]);
			int low  = hex_value(rest[i + 2]);
			if (high >= 0 && low >= 0)
			{
				out[n++] = (char)(high * 16 + low);
				i += 2;
				continue;
			}
		}
		out[n++] = rest[i];
	}
	return (String)out[0:n];
}

// The value of one hexadecimal digit, or -1.
fn int hex_value(char c) @private
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

<*
 `template` with each "{path}" inside every argument replaced by `path`. The
 result is an argv for `process::run`: nothing is passed through a shell.

 @param allocator : "Allocator for the argv and its strings"
*>
fn String[] substitute(Allocator allocator, String[] template, String path)
{
	String[] argv = alloc::new_array(allocator, String, template.len);
	foreach (i, arg : template) argv[i] = replace_placeholder(allocator, arg, path);
	return argv;
}

const String PATH_PLACEHOLDER = "{path}";

// `text` with every PATH_PLACEHOLDER replaced by `path`, copied into `allocator`.
fn String replace_placeholder(Allocator allocator, String text, String path) @private
{
	sz count = 0;
	for (usz i = 0; i + PATH_PLACEHOLDER.len <= text.len; i++)
	{
		if (text[i:PATH_PLACEHOLDER.len] == PATH_PLACEHOLDER) count++;
	}
	char[] out = alloc::new_array(allocator, char, text.len + count * path.len);
	usz n      = 0;
	for (usz i = 0; i < text.len; i++)
	{
		if (i + PATH_PLACEHOLDER.len <= text.len && text[i:PATH_PLACEHOLDER.len] == PATH_PLACEHOLDER)
		{
			foreach (c : path) out[n++] = c;
			i += PATH_PLACEHOLDER.len - 1;
			continue;
		}
		out[n++] = text[i];
	}
	return (String)out[0:n];
}