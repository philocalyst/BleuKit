<*
 freedesktop.org Base Directory specification: where user-specific and
 system-wide data, configuration, cache, state and runtime files live.

 Source: XDG Base Directory Specification 0.8
 (https://specifications.freedesktop.org/basedir-spec/latest/), section
 "Environment variables". Cross-checked against GLib (`glib/gutils.c`,
 https://github.com/GNOME/glib): GLib uses the same defaults and the same
 `XDG_DATA_DIRS` default, and treats an empty variable as unset. Two points
 where GLib differs and this module follows the specification: GLib accepts a
 relative `XDG_*_HOME` value, and on Windows GLib uses `LocalAppData`.

 Every function takes an `Environment`, so tests and embedding applications can
 supply their own variables. Results are copied into the caller's allocator.

 Rules applied exactly as the specification states them:
 * an unset or empty variable means "use the default";
 * a relative path in any of these variables is invalid and ignored.

 Platform notes (one logic everywhere, so the layout is identical on every OS):
 * The home directory is `$HOME`, and when that is not set (typical on
 Windows) `%USERPROFILE%`. A drive-letter path such as `C:\Users\me` counts as
 absolute.
 * macOS and Windows use the XDG defaults below, not `~/Library` or `%APPDATA%`
 (GLib uses `LocalAppData` on Windows). Code that needs native locations must
 not use this module for them.
*>
module bleu::xdg::dirs;
import bleu::error, std::os::env, std::collections::list;

const String PATH_LIST_SEPARATOR = ":";
const String DEFAULT_DATA_DIRS   = "/usr/local/share/:/usr/share/";
const String DEFAULT_CONFIG_DIRS = "/etc/xdg";

<*
 Source of environment variable values.

 `get` returns a copy of the variable in `allocator`, or `NOT_FOUND` when the
 variable is not set.
*>
interface Environment
{
	fn String? get(Allocator allocator, String name);
}

<*
 The process environment, as seen by `std::os::env`, with a table of overrides
 that is consulted first (for example to pin `HOME` for a child process).
*>
struct ProcessEnvironment (Environment)
{
	Variables overrides;
}

fn String? ProcessEnvironment.get(&self, Allocator allocator, String name) @dynamic
{
	if (try value = self.overrides.get(allocator, name)) return value;
	return env::get_var(allocator, name);
}

<*
 A fixed table of variables. Intended for tests, and for callers that build a
 sanitised environment for a child process. `names[i]` is the variable whose
 value is `values[i]`; the two arrays must have the same length.
*>
struct Variables (Environment)
{
	String[] names;
	String[] values;
}

fn String? Variables.get(&self, Allocator allocator, String name) @dynamic
{
	foreach (i, variable : self.names)
	{
		if (variable == name) return self.values[i].copy(allocator);
	}
	return NOT_FOUND~;
}

<*
 Whether `path` is absolute as the specification requires: it starts with `/`,
 or with a drive letter, a colon and a separator (Windows).
*>
fn bool is_absolute(String path) @inline
{
	if (path.len == 0) return false;
	if (path[0] == '/') return true;
	return path.len >= 3 && path[1] == ':' && (path[2] == '/' || path[2] == '\\') && ascii::is_alpha(path[0]);
}

<*
 `$XDG_DATA_HOME`, default `$HOME/.local/share`.

 @param [in] env : "Where the variables are read from"
 @param [&inout] allocator : "Allocator for the returned path"
 @return? error::UNAVAILABLE : "Neither the variable nor a home directory is set"
*>
fn String? data_home(Environment env, Allocator allocator) @inline
{
	return home_relative(env, allocator, "XDG_DATA_HOME", ".local/share");
}

<*
 `$XDG_CONFIG_HOME`, default `$HOME/.config`.

 @param [in] env : "Where the variables are read from"
 @param [&inout] allocator : "Allocator for the returned path"
 @return? error::UNAVAILABLE : "Neither the variable nor a home directory is set"
*>
fn String? config_home(Environment env, Allocator allocator) @inline
{
	return home_relative(env, allocator, "XDG_CONFIG_HOME", ".config");
}

<*
 `$XDG_CACHE_HOME`, default `$HOME/.cache`.

 @param [in] env : "Where the variables are read from"
 @param [&inout] allocator : "Allocator for the returned path"
 @return? error::UNAVAILABLE : "Neither the variable nor a home directory is set"
*>
fn String? cache_home(Environment env, Allocator allocator) @inline
{
	return home_relative(env, allocator, "XDG_CACHE_HOME", ".cache");
}

<*
 `$XDG_STATE_HOME`, default `$HOME/.local/state`.

 @param [in] env : "Where the variables are read from"
 @param [&inout] allocator : "Allocator for the returned path"
 @return? error::UNAVAILABLE : "Neither the variable nor a home directory is set"
*>
fn String? state_home(Environment env, Allocator allocator) @inline
{
	return home_relative(env, allocator, "XDG_STATE_HOME", ".local/state");
}

<*
 `$XDG_RUNTIME_DIR`. There is no default: the specification says applications
 should then fall back to a replacement directory, which is the caller's choice.
 Ownership and the 0700 mode are not checked here, because that needs a `stat`.

 @param [in] env : "Where the variables are read from"
 @param [&inout] allocator : "Allocator for the returned path"
 @return? error::UNAVAILABLE : "The variable is not set, empty or relative"
*>
fn String? runtime_dir(Environment env, Allocator allocator) @inline
{
	if (try value = absolute_variable(env, tmem, "XDG_RUNTIME_DIR")) return value.copy(allocator);
	return error::UNAVAILABLE~;
}

<*
 `$XDG_DATA_DIRS` in precedence order, default `/usr/local/share/:/usr/share/`.
 Relative and empty entries are dropped, so the result may be empty.

 @param [in] env : "Where the variables are read from"
 @param [&inout] allocator : "Allocator for the returned array and its strings"
*>
fn String[] data_dirs(Environment env, Allocator allocator) @inline
{
	return path_list(env, allocator, "XDG_DATA_DIRS", DEFAULT_DATA_DIRS);
}

<*
 `$XDG_CONFIG_DIRS` in precedence order, default `/etc/xdg`. Relative and empty
 entries are dropped, so the result may be empty.

 @param [in] env : "Where the variables are read from"
 @param [&inout] allocator : "Allocator for the returned array and its strings"
*>
fn String[] config_dirs(Environment env, Allocator allocator) @inline
{
	return path_list(env, allocator, "XDG_CONFIG_DIRS", DEFAULT_CONFIG_DIRS);
}

// `$variable` when it is set to an absolute path, else `$HOME/relative`.
fn String? home_relative(Environment env, Allocator allocator, String variable, String relative) @local
{
	if (try value = absolute_variable(env, tmem, variable)) return value.copy(allocator);
	String home = home_directory(env)!;
	return join(allocator, home, relative);
}

// The home directory: `$HOME`, falling back to `%USERPROFILE%`. Temporary.
fn String? home_directory(Environment env) @local
{
	if (try home = absolute_variable(env, tmem, "HOME")) return home;
	if (try home = absolute_variable(env, tmem, "USERPROFILE")) return home;
	return error::UNAVAILABLE~;
}

// Value of `name` if it is set, non-empty and absolute, else NOT_FOUND.
// The result lives in `allocator`.
fn String? absolute_variable(Environment env, Allocator allocator, String name) @local
{
	String value = env.get(allocator, name) ?? "";
	if (!is_absolute(value)) return NOT_FOUND~;
	return value;
}

// `base` + "/" + `relative`, without doubling a trailing separator on `base`.
fn String join(Allocator allocator, String base, String relative) @local
{
	bool has_separator = base[^1] == '/' || base[^1] == '\\';
	return has_separator ? string::tformat("%s%s", base, relative)
		.copy(allocator) : string::tformat("%s/%s", base, relative).copy(allocator);
}

// Split a colon-separated variable, keeping only absolute entries.
fn String[] path_list(Environment env, Allocator allocator, String variable, String fallback) @local
{
	String value = env.get(tmem, variable) ?? "";
	if (value.len == 0) value = fallback;
	List{String} entries;
	entries.tinit();
	foreach (part : value.tsplit(PATH_LIST_SEPARATOR))
	{
		if (is_absolute(part)) entries.push(part.copy(allocator));
	}
	return entries.to_aligned_array(allocator);
}