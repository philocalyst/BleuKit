<*
 Typed model of a `.desktop` file, the `OnlyShowIn`/`NotShowIn` visibility rule,
 and discovery of desktop files in the `applications/` directories.

 Source: Desktop Entry Specification 1.5
 (https://specifications.freedesktop.org/desktop-entry-spec/latest/): "Desktop
 File ID", "Basic format", "OnlyShowIn, NotShowIn", "Application actions" and
 the key table. The desktop-file-ID rule and the directory walk are from that
 text. The precedence of `applications/` directories follows GLib's
 `desktop_file_dir` handling in `gio/gdesktopappinfo.c`, which was read, not run.

 A `DesktopEntry` owns its strings in a private arena: `release` frees them all.
 Localized keys (`Name`, `GenericName`, `Comment`, `Icon`) are resolved for the
 locale given to `parse`. `Keywords` is read unlocalised (the specification
 allows localized keywords, which are not resolved here).
*>
module bleu::xdg::desktop_entry;
import bleu::error, bleu::xdg::keyfile, bleu::xdg::dirs, std::io, std::collections::list, std::collections::set;

const String MAIN_GROUP               = "Desktop Entry";
const String ACTION_GROUP_PREFIX      = "Desktop Action ";
const String APPLICATIONS_DIRECTORY   = "applications";
const String DESKTOP_SUFFIX           = ".desktop";
const String CURRENT_DESKTOP_VARIABLE = "XDG_CURRENT_DESKTOP";
const String PATH_SEPARATOR           = "/";
const String ID_SEPARATOR             = "-";
const String DESKTOP_LIST_SEPARATOR   = ":";
const int MAX_SCAN_DEPTH              = 8;
const usz ARENA_PAGE_SIZE             = 1024;

<* The `Type` of a desktop entry. *>
enum EntryType : char
{
	APPLICATION,
	LINK,
	DIRECTORY,
}

<*
 One `[Desktop Action X]` group named by the `Actions` key. Actions whose group
 is missing, or that have no `Name`, are dropped as the specification says.
*>
struct Action
{
	String id;
	String name;
	String icon;
	String exec;
}

<*
 A parsed desktop entry. All strings and arrays live in its arena; `release`
 frees the lot, including this struct.
*>
struct DesktopEntry
{
	Allocator parent;
	DynamicArenaAllocator arena;
	EntryType type;
	String name;
	String generic_name;
	String comment;
	String icon;
	String exec;
	String try_exec;
	String working_dir;
	String startup_wm_class;
	bool terminal;
	bool startup_notify;
	bool no_display;
	bool hidden;
	bool dbus_activatable;
	String[] only_show_in;
	String[] not_show_in;
	String[] categories;
	String[] keywords;
	String[] mime_types;
	Action[] actions;
}

<*
 A desktop file found by `scan`.
*>
struct DesktopFile
{
	String id; // the desktop file ID, for example org.example.App.desktop
	String path; // the file that holds this ID; valid only during the visit
}

<*
 Called once for every desktop file, in precedence order. Returning a fault
 stops the scan and passes the fault on.
*>
alias ScanVisitor = fn void?(void* context, DesktopFile file);

<*
 Parse a desktop entry.

 @param [&inout] allocator : "Allocator the entry's arena draws its pages from"
 @param source : "The complete file contents, UTF-8"
 @param locale : "The LC_MESSAGES value that localized keys are resolved for; empty for none"
 @return "The entry, which the caller must `release`"
 @return? error::PROTOCOL : "The file is not a valid desktop entry: a missing or unknown Type or Name, a missing Exec for a non-D-Bus application, or a malformed line"
*>
fn DesktopEntry*? parse(Allocator allocator, String source, String locale)
{
	KeyFile file        = keyfile::parse(tmem, source)!;
	DesktopEntry* entry = alloc::new(allocator, DesktopEntry);
	entry.parent = allocator;
	entry.arena.init(allocator, ARENA_PAGE_SIZE);
	defer catch entry.release();
	fill(entry, &file, locale)!;
	return entry;
}

<*
 Read and parse a desktop file from disk.

 @return? NOT_FOUND : "The file does not exist"
 @return? error::PERMISSION_DENIED : "The file cannot be read"
 @return? error::PROTOCOL : "The file is not a valid desktop entry"
*>
fn DesktopEntry*? load(Allocator allocator, String path, String locale)
{
	char[] bytes = read_file(path)!;
	return parse(allocator, (String)bytes, locale);
}

<* Free the entry, its strings and the struct itself. *>
fn void DesktopEntry.release(&self)
{
	Allocator parent = self.parent;
	self.arena.free();
	alloc::free(parent, self);
}

<*
 Whether the entry is shown in the desktop environments named in
 `current_desktops` (the colon-separated `$XDG_CURRENT_DESKTOP`, already split).

 The first name that appears in `OnlyShowIn` shows the entry, the first that
 appears in `NotShowIn` hides it, and when neither matches the default applies:
 shown, unless the entry has an `OnlyShowIn` list. This is independent of the
 `Hidden` and `NoDisplay` flags, which the caller checks separately.

 @param current_desktops : "Desktop names in precedence order; may be empty"
*>
fn bool DesktopEntry.show_in(&self, String[] current_desktops)
{
	foreach (desktop : current_desktops)
	{
		if (contains(self.only_show_in, desktop)) return true;
		if (contains(self.not_show_in, desktop)) return false;
	}
	return self.only_show_in.len == 0;
}

<*
 The names in `$XDG_CURRENT_DESKTOP`, in order, with empty names dropped.

 @param [&inout] allocator : "Allocator for the array and its strings"
*>
fn String[] current_desktops(Environment env, Allocator allocator)
{
	String value = env.get(tmem, CURRENT_DESKTOP_VARIABLE) ?? "";
	List{String} names;
	names.tinit();
	foreach (name : value.tsplit(DESKTOP_LIST_SEPARATOR, 0, true)) names.push(name.copy(allocator));
	return names.to_aligned_array(allocator);
}

<*
 Visit every desktop file under `data_dirs`, each in its `applications/`
 directory and in subdirectories of it (`applications/foo/bar.desktop` has the
 ID `foo-bar.desktop`). When one ID occurs more than once, only the first
 occurrence in `data_dirs` order is visited, which is the one that takes
 precedence. Unreadable directories are skipped, as the Base Directory
 specification asks.

 Within one directory the order of files is the order the file system returns
 them, so the choice between two files that map to the same ID inside a single
 directory (which the specification leaves undefined) can vary between systems.

 @param data_dirs : "The XDG data directories in precedence order"
 @param context : "Passed to every visit"
*>
fn void? scan(String[] data_dirs, void* context, ScanVisitor visitor)
{
	HashSet{String} seen;
	seen.tinit();
	foreach (directory : data_dirs)
	{
		String applications = string::tformat("%s/%s", directory.trim_right("/"), APPLICATIONS_DIRECTORY);
		if (!io::file::is_dir(applications)) continue;
		walk(applications, "", 0, &seen, context, visitor)!;
	}
}

// Visit the desktop files directly in `directory` and below it. `prefix` is the
// path of `directory` relative to the `applications` root, with a trailing slash.
fn void? walk(
	String directory,
	String prefix,
	int depth,
	HashSet{String}* seen,
	void* context,
	ScanVisitor visitor
) @local
{
	if (depth > MAX_SCAN_DEPTH) return;
	PathList? listing = io::path::ls(tmem, (Path)directory);
	if (catch err = listing) return;
	foreach (name : listing)
	{
		String full = string::tformat("%s/%s", directory, name);
		if (io::file::is_dir(full))
		{
			walk(full, string::tformat("%s%s/", prefix, name), depth + 1, seen, context, visitor)!;
			continue;
		}
		if (!name.ends_with(DESKTOP_SUFFIX)) continue;
		String id = string::tformat("%s%s", prefix, name).treplace(PATH_SEPARATOR, ID_SEPARATOR);
		if (!seen.add(id)) continue;
		visitor(context, { .id = id, .path = full })!;
	}
}

// Fill `entry` from the main group, and its actions, of `file`.
fn void? fill(DesktopEntry* entry, KeyFile* file, String locale) @local
{
	if (!file.has_group(
		MAIN_GROUP
	)) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "no [Desktop Entry] group")~;
	Allocator a = &entry.arena;
	entry.type = type_of(string_value(file, tmem, MAIN_GROUP, "Type")!)!;
	entry.name = required_localized(file, a, MAIN_GROUP, "Name", locale)!;
	entry.generic_name = localized_value(file, a, MAIN_GROUP, "GenericName", locale)!;
	entry.comment = localized_value(file, a, MAIN_GROUP, "Comment", locale)!;
	entry.icon = localized_value(file, a, MAIN_GROUP, "Icon", locale)!;
	entry.exec = string_value(file, a, MAIN_GROUP, "Exec")!;
	entry.try_exec = string_value(file, a, MAIN_GROUP, "TryExec")!;
	entry.working_dir = string_value(file, a, MAIN_GROUP, "Path")!;
	entry.startup_wm_class = string_value(file, a, MAIN_GROUP, "StartupWMClass")!;
	entry.terminal = flag_value(file, MAIN_GROUP, "Terminal")!;
	entry.startup_notify = flag_value(file, MAIN_GROUP, "StartupNotify")!;
	entry.no_display = flag_value(file, MAIN_GROUP, "NoDisplay")!;
	entry.hidden = flag_value(file, MAIN_GROUP, "Hidden")!;
	entry.dbus_activatable = flag_value(file, MAIN_GROUP, "DBusActivatable")!;
	entry.only_show_in = list_value(file, a, MAIN_GROUP, "OnlyShowIn")!;
	entry.not_show_in = list_value(file, a, MAIN_GROUP, "NotShowIn")!;
	entry.categories = list_value(file, a, MAIN_GROUP, "Categories")!;
	entry.keywords = list_value(file, a, MAIN_GROUP, "Keywords")!;
	entry.mime_types = list_value(file, a, MAIN_GROUP, "MimeType")!;
	if (entry.type == APPLICATION && entry.exec.len == 0 && !entry.dbus_activatable)
	{
		return error::raise(
			error::PROTOCOL,
			error::Domain.INTERNAL,
			0,
			"an application needs Exec unless DBusActivatable is true"
		)~;
	}
	entry.actions = actions(file, a, list_value(file, tmem, MAIN_GROUP, "Actions")!, locale)!;
}

// `Type=` as an EntryType.
fn EntryType? type_of(String value) @local
{
	if (value == "Application") return APPLICATION;
	if (value == "Link") return LINK;
	if (value == "Directory") return DIRECTORY;
	return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "unknown Type '%s'", value)~;
}

// The `[Desktop Action X]` groups named by `ids` that are complete.
fn Action[]? actions(KeyFile* file, Allocator allocator, String[] ids, String locale) @local
{
	List{Action} found;
	found.tinit();
	foreach (id : ids)
	{
		String group = string::tformat("%s%s", ACTION_GROUP_PREFIX, id);
		if (!file.has_group(group)) continue;
		String name = localized_value(file, allocator, group, "Name", locale)!;
		if (name.len == 0) continue;
		found.push(
			{
				.id = id.copy(allocator),
				.name = name,
				.icon = localized_value(file, allocator, group, "Icon", locale)!,
				.exec = string_value(file, allocator, group, "Exec")!,
			}
		);
	}
	return found.to_aligned_array(allocator);
}

// Absent keys read as "", so optional strings need no special case.
fn String? string_value(KeyFile* file, Allocator allocator, String group, String key) @local
{
	String? value = file.get_string(allocator, group, key);
	if (catch err = value)
	{
		if (err == NOT_FOUND) return "";
		return err~;
	}
	return value;
}

fn String? localized_value(KeyFile* file, Allocator allocator, String group, String key, String locale) @local
{
	String? value = file.get_localized_string(allocator, group, key, locale);
	if (catch err = value)
	{
		if (err == NOT_FOUND) return "";
		return err~;
	}
	return value;
}

// A localized key that must be present and non-empty.
fn String? required_localized(KeyFile* file, Allocator allocator, String group, String key, String locale) @local
{
	String value = localized_value(file, allocator, group, key, locale)!;
	if (value.len == 0) return error::raise(
		error::PROTOCOL,
		error::Domain.INTERNAL,
		0,
		"missing required key '%s'",
		key
	)~;
	return value;
}

fn String[]? list_value(KeyFile* file, Allocator allocator, String group, String key) @local
{
	String[]? values = file.get_strings(allocator, group, key);
	if (catch err = values)
	{
		if (err == NOT_FOUND) return { };
		return err~;
	}
	return values;
}

// A boolean key, false when absent.
fn bool? flag_value(KeyFile* file, String group, String key) @local
{
	bool? value = file.get_boolean(group, key);
	if (catch err = value)
	{
		if (err == NOT_FOUND) return false;
		return err~;
	}
	return value;
}

fn bool contains(String[] list, String value) @local
{
	foreach (item : list)
	{
		if (item == value) return true;
	}
	return false;
}

// The bytes of `path`, in temporary memory. Missing files are NOT_FOUND;
// every other I/O failure is reported as a permission problem.
fn char[]? read_file(String path) @local
{
	char[]? bytes = io::file::load(tmem, path);
	if (catch err = bytes)
	{
		if (err == io::FILE_NOT_FOUND) return NOT_FOUND~;
		return error::PERMISSION_DENIED~;
	}
	return bytes;
}