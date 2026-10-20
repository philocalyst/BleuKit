<*
 Which application opens which MIME type: `mimeapps.list` (defaults and added or
 removed associations), the associations declared by desktop files, and the
 `mimeinfo.cache` index.

 Source: Association between MIME types and applications, version 0.2
 (https://specifications.freedesktop.org/mime-apps-spec/latest/): "File name and
 location" (the eight-entry lookup order), "Adding/removing associations", "Default
 Application" and both suggested algorithms. The `mimeinfo.cache` layout is the
 one `update-desktop-database` writes (a `[MIME Cache]` group of `type=ids;`
 lines), cross-checked against GLib's `gdesktopappinfo.c`
 (https://github.com/GNOME/glib/blob/main/gio/gdesktopappinfo.c).

 Not done: the specification's "most specific to least specific" loop over MIME
 type hierarchies (`text/x-csrc` before `text/plain`) needs the shared-mime-info
 database, which this library does not read. Each call handles exactly the type it is
 given. Malformed `mimeapps.list` files and desktop files are skipped, not
 reported, so one broken file cannot hide the others.
*>
module bleu::xdg::mime;
import bleu::error, bleu::xdg::keyfile, bleu::xdg::dirs, bleu::xdg::desktop_entry, std::io, std::collections::list, std::collections::set;

const String MIMEAPPS_FILE          = "mimeapps.list";
const String APPLICATIONS_DIRECTORY = "applications";
const String DEFAULT_GROUP          = "Default Applications";
const String ADDED_GROUP            = "Added Associations";
const String REMOVED_GROUP          = "Removed Associations";
const String CACHE_GROUP            = "MIME Cache";
const String DESKTOP_FILE_SUFFIX    = "-mimeapps.list";
const String MIMEINFO_CACHE_FILE    = "mimeinfo.cache";

<*
 One `mimeapps.list` location, in lookup order. `data_directory` is the XDG data
 directory whose `applications/` directory holds the desktop files that sit beside
 this file; it is empty for configuration directories, which have none.
 Desktop-specific files (`$desktop-mimeapps.list`) only supply defaults.
*>
struct Source
{
	String path;
	String data_directory;
	bool desktop_specific;
}

<*
 The `mimeapps.list` files to consult, most important first: for each
 configuration and data location, the desktop-specific files of every name in
 `$XDG_CURRENT_DESKTOP` (lower-cased), then the generic file.

 @param [&inout] allocator : "Allocator for the array and its strings"
*>
fn Source[] sources(Environment env, Allocator allocator)
{
	String[] desktops = lower_case_all(desktop_entry::current_desktops(env, tmem), tmem);
	List{Source} found;
	found.tinit();
	add_location(&found, dirs::config_home(env, tmem) ?? "", "", &desktops, allocator);
	foreach (config : dirs::config_dirs(env, tmem)) add_location(&found, config, "", &desktops, allocator);
	String data_home = dirs::data_home(env, tmem) ?? "";
	add_location(
		&found,
		string::tformat("%s/%s", data_home.trim_right("/"), APPLICATIONS_DIRECTORY),
		data_home,
		&desktops,
		allocator
	);
	foreach (data : dirs::data_dirs(env, tmem))
	{
		add_location(
			&found,
			string::tformat("%s/%s", data.trim_right("/"), APPLICATIONS_DIRECTORY),
			data,
			&desktops,
			allocator
		);
	}
	return found.to_aligned_array(allocator);
}

<*
 The default application for `mime`: the first desktop ID that a `[Default
 Applications]` section lists, in `sources` order, whose desktop file exists and
 which is associated with the type. When no default is listed, the first
 application associated with the type.

 @param [&inout] allocator : "Allocator for the returned ID"
 @return? NOT_FOUND : "No application is associated with the type"
*>
fn String? default_application(Environment env, Allocator allocator, String mime)
{
	String[] associated = { };
	bool computed       = false;
	foreach (source : sources(env, tmem))
	{
		foreach (id : defaults_in(source, mime))
		{
			if (!desktop_file_exists(env, id)) continue;
			if (!computed)
			{
				associated = associated_applications(env, tmem, mime);
				computed = true;
			}
			if (contains_string(associated, id)) return id.copy(allocator);
		}
	}
	if (!computed) associated = associated_applications(env, tmem, mime);
	if (associated.len > 0) return associated[0].copy(allocator);
	return NOT_FOUND~;
}

<*
 Every desktop ID associated with `mime`, most preferred first, following the
 specification's suggested algorithm: each `mimeapps.list` in order contributes
 its added associations (unless blacklisted), blacklists its removed ones, then
 the desktop files beside it that declare the type; every desktop file it sees
 is then blacklisted for the rest of the walk, so a higher-precedence file hides
 a lower one with the same ID.

 @param [&inout] allocator : "Allocator for the array and its strings"
*>
fn String[] associated_applications(Environment env, Allocator allocator, String mime)
{
	List{String} results;
	results.tinit();
	HashSet{String} blacklist;
	blacklist.tinit();
	foreach (source : sources(env, tmem))
	{
		// Desktop-specific files may only supply defaults, so they add and remove nothing.
		if (source.desktop_specific) continue;
		foreach (id : association_list(source, ADDED_GROUP, mime))
		{
			if (!blacklist.contains(id) && !contains_string(results.array_view(), id)) results.push(id.copy(allocator));
		}
		foreach (id : association_list(source, REMOVED_GROUP, mime)) blacklist.add(id);
		if (source.data_directory.len == 0) continue;
		Visit visit = { .mime = mime, .blacklist = &blacklist, .results = &results, .allocator = allocator };
		// The visitor cannot fail, so the scan cannot fail either.
		desktop_entry::scan({ source.data_directory }, &visit, &visit_desktop_file)!!;
	}
	return results.to_aligned_array(allocator);
}

<*
 The desktop IDs that a `mimeinfo.cache` file (text) lists for `mime`. The cache
 is an index that `update-desktop-database` writes; it can be stale, so this does
 not replace `associated_applications`. A malformed cache lists nothing.

 @param [&inout] allocator : "Allocator for the array and its strings"
*>
fn String[] cached_applications(String cache_text, Allocator allocator, String mime)
{
	KeyFile? file = keyfile::parse_with(tmem, cache_text, PERMISSIVE);
	if (catch err = file) return { };
	String[]? ids = file.get_strings(tmem, CACHE_GROUP, mime);
	if (catch err = ids) return { };
	return copy_all(allocator, ids);
}

// Context for `visit_desktop_file`, one `applications` directory at a time.
struct Visit
{
	String mime;
	HashSet{String}* blacklist;
	List{String}* results;
	Allocator allocator;
}

// Adds the desktop file if it declares the type and is not blacklisted, then blacklists it.
fn void? visit_desktop_file(void* context, DesktopFile file) @local
{
	Visit* visit = (Visit*)context;
	if (visit.blacklist.contains(file.id)) return;
	visit.blacklist.add(file.id);
	// A desktop file that does not parse cannot declare a type; it is skipped.
	DesktopEntry*? entry = desktop_entry::load(mem, file.path, "");
	if (catch err = entry) return;
	defer entry.release();
	if (!contains_string(entry.mime_types, visit.mime)) return;
	if (!contains_string(visit.results.array_view(), file.id)) visit.results.push(file.id.copy(visit.allocator));
}

// The defaults `source` lists for `mime`, or none.
fn String[] defaults_in(Source source, String mime) @local
{
	return association_list(source, DEFAULT_GROUP, mime);
}

// The IDs listed for `mime` under `group` in `source`; none when the file or entry is absent or malformed.
fn String[] association_list(Source source, String group, String mime) @local
{
	if (!io::file::is_file(source.path)) return { };
	char[]? bytes = keyfile::load_file(source.path);
	if (catch err = bytes) return { };
	KeyFile? file = keyfile::parse_with(tmem, (String)bytes, PERMISSIVE);
	if (catch err = file) return { };
	String[]? ids = file.get_strings(tmem, group, mime);
	if (catch err = ids) return { };
	return ids;
}

// Whether a desktop file with this ID exists in one of the data directories.
fn bool desktop_file_exists(Environment env, String id) @local
{
	return desktop_file_path(env, id) != "";
}

// The path of the desktop file `id`, searched in the data home then the data dirs, or "".
fn String desktop_file_path(Environment env, String id) @local
{
	String home = dirs::data_home(env, tmem) ?? "";
	if (home.len > 0)
	{
		String path = string::tformat("%s/%s/%s", home.trim_right("/"), APPLICATIONS_DIRECTORY, id);
		if (io::file::is_file(path)) return path;
	}
	foreach (data : dirs::data_dirs(env, tmem))
	{
		String path = string::tformat("%s/%s/%s", data.trim_right("/"), APPLICATIONS_DIRECTORY, id);
		if (io::file::is_file(path)) return path;
	}
	return "";
}

// Appends the mimeapps.list locations of one base directory, desktop-specific first.
fn void add_location(
	List{Source}* found,
	String base,
	String data_directory,
	String[]* desktops,
	Allocator allocator
) @local
{
	if (base.len == 0) return;
	String trimmed = base.trim_right("/");
	foreach (desktop : *desktops)
	{
		found.push(
			{
				.path = string::tformat("%s/%s%s", trimmed, desktop, DESKTOP_FILE_SUFFIX)
			.copy(allocator), .data_directory = data_directory.copy(allocator), .desktop_specific = true, });
	}
	found.push(
		{
			.path = string::tformat("%s/%s", trimmed, MIMEAPPS_FILE)
		.copy(allocator), .data_directory = data_directory.copy(allocator), .desktop_specific = false, });
}

// Lower-cases each name, in `allocator`.
fn String[] lower_case_all(String[] names, Allocator allocator) @local
{
	String[] lowered = alloc::new_array(allocator, String, names.len);
	foreach (i, name : names) lowered[i] = name.to_lower_copy(allocator);
	return lowered;
}

fn bool contains_string(String[] list, String value) @local
{
	foreach (item : list)
	{
		if (item == value) return true;
	}
	return false;
}

fn String[] copy_all(Allocator allocator, String[] values) @local
{
	String[] copies = alloc::new_array(allocator, String, values.len);
	foreach (i, value : values) copies[i] = value.copy(allocator);
	return copies;
}