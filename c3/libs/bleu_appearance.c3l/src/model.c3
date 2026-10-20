<*
 Desktop appearance, as plain data: colour scheme and accent, accessibility
 flags, font and text scale, icon, GTK and cursor themes, clock format and
 wallpaper.

 A value the platform cannot tell is empty, never guessed. Strings are "" and
 `Maybe` values have no value; the matching `Cap` in `Capabilities` says why
 (see `service.c3`). A flag that is `false` is a reading, not an absence.
*>
module bleu::appearance;
import std::collections::maybe, bleu::unit, bleu::availability, bleu::operation;

<*
 Light or dark preference. `NO_PREFERENCE` is what the desktop reports when
 the user has chosen neither.
*>
enum ColorScheme : char
{
	NO_PREFERENCE,
	DARK,
	LIGHT,
}

<* Whether the user asked for more contrast than normal. *>
enum Contrast : char
{
	NORMAL,
	HIGH,
}

<* The clock's hour format. `UNKNOWN` when the desktop has no setting we can read. *>
enum ClockFormat : char
{
	UNKNOWN,
	H12,
	H24,
}

<* An sRGB colour; each channel is in [0, 1]. *>
struct Rgb
{
	Level red;
	Level green;
	Level blue;
}

<*
 One desktop picture. `screen` is the OS screen id where the desktop has one
 picture per screen (macOS), and "" where there is one picture for all of them.
*>
struct Wallpaper
{
	String screen;
	String path;
}

<* The whole picture. Every field is valid only where its capability is available. *>
struct State
{
	ColorScheme color_scheme;
	Maybe{Rgb} accent;
	Contrast contrast;
	bool reduced_motion;
	bool reduced_transparency;
	String font_name;
	Maybe{float} text_scale; // 1.0 is the default size
	String icon_theme;
	String gtk_theme;
	String cursor_theme;
	ClockFormat clock_format;
	Wallpaper[] wallpapers;
}

<*
 Every optional operation or reading. `COLOR_SCHEME_SET`, `WALLPAPER_SET` are the
 requests; the others are readings of `State`.
*>
enum Cap : char
{
	COLOR_SCHEME,
	COLOR_SCHEME_SET,
	ACCENT,
	CONTRAST,
	REDUCED_MOTION,
	REDUCED_TRANSPARENCY,
	FONT,
	TEXT_SCALE,
	THEME_NAMES,
	CLOCK_FORMAT,
	WALLPAPER,
	WALLPAPER_SET,
	WALLPAPER_PER_SCREEN,
}

<*
 Which part of `State` changed. One event per part that changed, emitted after
 the new state is published; re-read the state for the values.
*>
enum EventKind : char
{
	COLOR_SCHEME, // the colour scheme
	ACCENT,       // the accent colour
	ACCESSIBILITY, // contrast, reduced motion or reduced transparency
	DESKTOP,      // font, text scale, theme names or clock format
	WALLPAPER,    // the wallpapers
}

<* A transient: which part of the appearance changed. *>
struct Event
{
	EventKind kind;
}

<* What the worker is asked to do. *>
enum CommandKind : char
{
	REFRESH,           // read the desktop now instead of waiting for the next poll
	SET_COLOR_SCHEME,  // write `scheme`
	SET_WALLPAPER,     // set the wallpaper to `path`
}

<*
 A request for the worker. `op` is the caller's `Operation`; the worker holds
 its own reference until it settles the operation. `path` lives in the
 operation's arena. REFRESH carries neither.
*>
struct Command
{
	CommandKind kind;
	ColorScheme scheme;
	String path;
	Operation{bool}* op;
}

<* Which mechanism provides the data. *>
enum Backend : char
{
	AUTO,
	PORTAL,    // Linux: org.freedesktop.portal.Settings, with GNOME gsettings for desktop keys
	GSETTINGS, // Linux: `gsettings get/set` alone, when no portal answers
	APPKIT,    // macOS: NSUserDefaults, NSWorkspace accessibility flags, NSScreen wallpapers
	WIN32,     // Windows: registry Personalize and DWM, SystemParametersInfo wallpaper
}
