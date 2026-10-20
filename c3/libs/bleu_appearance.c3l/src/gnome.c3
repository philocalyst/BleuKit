<*
 GNOME desktop settings, read and written with the `gsettings` command.

 The Settings portal does not carry fonts, theme names, the text scale, the
 clock format or the wallpaper, so GNOME's own keys are the source for those.
 `gsettings` is run with an argv (never through a shell), and every value it
 prints is a GVariant text, parsed by `convert.c3`.

 Source: gsettings(1) `get` and `set`; keys and defaults from gsettings-desktop-schemas
 (`schemas/org.gnome.desktop.interface.gschema.xml.in` and
 `schemas/org.gnome.desktop.background.gschema.xml.in`,
 https://raw.githubusercontent.com/GNOME/gsettings-desktop-schemas/master/schemas/).
 A command that cannot run, or a key the schema lacks, reads as empty.
*>
module bleu::appearance::gnome @feat(LINUX);
import std::os::process, bleu::appearance, bleu::appearance::convert, bleu::error;

const String INTERFACE_SCHEMA  = "org.gnome.desktop.interface";
const String BACKGROUND_SCHEMA = "org.gnome.desktop.background";
const sz VALUE_CAPACITY        = 1024;
<* Room for the key list of one schema, which is a few hundred bytes. *>
const usz KEY_LIST_CAPACITY    = 4096;

<*
 The text `gsettings get` printed for one key, trimmed. It is a view into
 `buffer`, valid while the buffer is.

 @return? error::BACKEND_FAILURE : "The gsettings command could not run"
*>
fn String? printed_text(char[] buffer, String schema, String key)
{
	String[4] argv = { "gsettings", "get", schema, key };
	String text    = process::run_capture_stdout(buffer, argv[..], process::SpawnOptions.INHERIT_ENV)!;
	return text.trim();
}

// A GVariant string key, unquoted into `allocator`; "" when it is missing or not a string.
fn String read_string(Allocator allocator, String schema, String key)
{
	char[VALUE_CAPACITY] buffer;
	String printed = printed_text(buffer[..], schema, key) ?? "";
	return convert::unquote(allocator, printed) ?? "";
}

<*
 Whether `gsettings` can read the interface schema here. False when the command
 is missing or the schema is not installed.
*>
fn bool available()
{
	char[VALUE_CAPACITY] buffer;
	String printed = printed_text(buffer[..], INTERFACE_SCHEMA, "color-scheme") ?? "";
	return printed.len > 0;
}

<*
 The GNOME colour scheme. A key that cannot be read (the command fails or prints nothing) is an error, so the
 caller keeps its last reading; "default" is NO_PREFERENCE.

 @return? error::UNAVAILABLE : "gsettings printed nothing for the key"
*>
fn ColorScheme? read_color_scheme()
{
	char[VALUE_CAPACITY] buffer;
	String printed = printed_text(buffer[..], INTERFACE_SCHEMA, "color-scheme") ?? "";
	if (printed.len == 0) return error::UNAVAILABLE~;
	@pool()
	{
		return convert::scheme_from_gnome(convert::unquote(tmem, printed) ?? "");
	};
}

<*
 Whether GNOME animations are on. `enable-animations` is a GVariant boolean.

 @return? error::INVALID_ARGUMENT : "The key is missing or is not a boolean"
*>
fn bool? animations_enabled()
{
	char[VALUE_CAPACITY] buffer;
	String printed = printed_text(buffer[..], INTERFACE_SCHEMA, "enable-animations") ?? "";
	return convert::bool_from_gnome(printed);
}

<*
 Fill the desktop keys of `state`: fonts, text scale, theme names, clock format
 and the wallpaper. Strings are allocated from `allocator`.
*>
fn void read_desktop(Allocator allocator, State* state)
{
	state.font_name = read_string(allocator, INTERFACE_SCHEMA, "font-name");
	state.icon_theme = read_string(allocator, INTERFACE_SCHEMA, "icon-theme");
	state.gtk_theme = read_string(allocator, INTERFACE_SCHEMA, "gtk-theme");
	state.cursor_theme = read_string(allocator, INTERFACE_SCHEMA, "cursor-theme");
	state.clock_format = convert::clock_from_gnome(read_string(allocator, INTERFACE_SCHEMA, "clock-format"));
	char[VALUE_CAPACITY] buffer;
	String scale = printed_text(buffer[..], INTERFACE_SCHEMA, "text-scaling-factor") ?? "";
	state.text_scale = convert::scale_from_gnome(scale);
	String uri = read_string(allocator, BACKGROUND_SCHEMA, "picture-uri");
	if (try path = convert::path_from_file_uri(allocator, uri))
	{
		Wallpaper[] wallpapers = alloc::new_array(allocator, Wallpaper, 1);
		wallpapers[0] = { .screen = "", .path = path };
		state.wallpapers = wallpapers;
	}
}

<*
 Run `gsettings set` with `printed` as the GVariant value. @return? error::BACKEND_FAILURE : "gsettings refused the
 value"
*>
fn void? set_text(String schema, String key, String printed)
{
	String[5] argv = { "gsettings", "set", schema, key, printed };
	int status     = process::run(argv[..], process::SpawnOptions.INHERIT_ENV)!;
	if (status != 0)
	{
		return error::raise(
			error::BACKEND_FAILURE,
			error::Domain.INTERNAL,
			status,
			"gsettings set %s %s failed",
			schema,
			key
		)~;
	}
}

<* Write the GNOME colour scheme. NO_PREFERENCE is written as 'default'. *>
fn void? set_color_scheme(ColorScheme scheme)
{
	@pool()
	{
		return set_text(INTERFACE_SCHEMA, "color-scheme", convert::quote(tmem, convert::scheme_to_gnome(scheme)));
	};
}

<* The key of the dark picture: GNOME 42 and later have it; earlier releases have only the light one. *>
const String PICTURE_DARK_KEY = "picture-uri-dark";

<*
 Whether the schema has the key `key`: `gsettings list-keys` prints one key per line.

 @return? error::BACKEND_FAILURE : "gsettings could not list the keys of the schema"
*>
fn bool? has_key(String schema, String key)
{
	char[KEY_LIST_CAPACITY] buffer;
	String[3] argv = { "gsettings", "list-keys", schema };
	String listed  = process::run_capture_stdout(buffer[..], argv[..], process::SpawnOptions.INHERIT_ENV)!;
	sz start       = 0;
	for (sz i = 0; i <= listed.len; i++)
	{
		if (i < listed.len && listed[i] != '\n') continue;
		if (listed[start:i - start].trim() == key) return true;
		start = i + 1;
	}
	return false;
}

<*
 Point GNOME's picture keys at the file at `path`. The light picture is required. The dark one is written when
 the schema has it (GNOME 42 and later); on an older release only the light picture exists.

 @return? error::BACKEND_FAILURE : "gsettings refused a picture, or could not list the keys"
*>
fn void? set_wallpaper(String path)
{
	@pool()
	{
		String uri = convert::quote(tmem, convert::file_uri(tmem, path));
		set_text(BACKGROUND_SCHEMA, "picture-uri", uri)!;
		bool has_dark = has_key(BACKGROUND_SCHEMA, PICTURE_DARK_KEY)!;
		if (has_dark) set_text(BACKGROUND_SCHEMA, PICTURE_DARK_KEY, uri)!;
	};
}