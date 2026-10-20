<*
 Icon Theme specification: `index.theme` parsing, directory size rules, and the
 icon lookup that returns a file path (no image is decoded here).

 Source: Icon Theme Specification 0.13
 (https://specifications.freedesktop.org/icon-theme-spec/latest/): "Directory
 Layout" (section 3), "File Formats" (section 4, the Icon Theme and per-directory
 keys), "Icon Lookup" (section 5, `FindIcon`, `LookupIcon`, `DirectoryMatchesSize`,
 `DirectorySizeDistance`).

 The specification's pseudocode for the Threshold distance has two typos (it
 compares `iconsize*iconsize`, and its lower bound uses `MinSize`). The
 implementation uses the meaning the text describes, which GTK's
 `theme_dir_size_difference` (gtk/gtkicontheme.c, https://github.com/GNOME/gtk)
 also implements: the bounds are `(Size - Threshold)*Scale` and
 `(Size + Threshold)*Scale`. GTK's Scalable branch compares the unscaled size to
 `MaxSize*Scale`; this implementation compares the scaled size, as the
 specification's formula does.

 `Finder` is the cache. It keeps the parsed themes and one listing per directory
 it has looked in, so a lookup costs a few `stat`-free set probes after the first
 time. Everything it holds lives in its arena; `release` frees the lot. A cache
 is only valid while the files do not change; `Finder.clear` drops it.
*>
module bleu::xdg::icon;
import bleu::error, bleu::xdg::keyfile, bleu::xdg::dirs, std::io, std::collections::list, std::collections::set, std::collections::map;

const String INDEX_FILE           = "index.theme";
const String ICON_THEME_GROUP     = "Icon Theme";
const String FALLBACK_THEME       = "hicolor";
const String PIXMAPS_DIRECTORY    = "/usr/share/pixmaps";
const String HOME_ICONS_DIRECTORY = ".icons";
const String ICONS_DIRECTORY      = "icons";
const String EXTENSION_SEPARATOR  = ".";
const String PATH_SEPARATOR       = "/";
const String[3] EXTENSIONS        = { "png", "svg", "xpm" };
const int DEFAULT_SCALE           = 1;
const int DEFAULT_THRESHOLD       = 2;
const int MAX_THEME_DEPTH         = 16;
const usz ARENA_PAGE_SIZE         = 1024;

<* The `Type` of a directory: how far its icons can be scaled from their nominal size. *>
enum DirectoryType : char
{
	FIXED,
	SCALABLE,
	THRESHOLD,
}

<*
 One subdirectory of a theme and its size rules. `path` is relative to the
 theme directory, for example `48x48/apps`.
*>
struct Directory
{
	String path;
	DirectoryType type;
	int size;
	int scale;
	int min_size;
	int max_size;
	int threshold;
}

<*
 A parsed `index.theme`. Every string and array lives in the allocator given to
 `parse_index`. `name` is the theme's internal name (its directory name, which
 paths are built from); `display_name` is the `Name` key.
*>
struct Theme
{
	String name;
	String display_name;
	String[] inherits;
	Directory[] directories;
}

<*
 Whether icons in this directory are the right size for a request of `size` at
 `scale` (the exact-match phase of the lookup). The scale must match exactly.
*>
fn bool Directory.matches(self, int size, int scale)
{
	if (self.scale != scale) return false;
	switch (self.type)
	{
		case FIXED: return self.size == size;
		case SCALABLE: return self.min_size <= size && size <= self.max_size;
		case THRESHOLD: return self.size - self.threshold <= size && size <= self.size + self.threshold;
	}
}

<*
 How far, in scaled pixels, the directory's nominal size is from a request of
 `size` at `scale`; zero when the directory covers the request. Used to pick the
 closest icon when no directory matches exactly.
*>
fn int Directory.distance(self, int size, int scale)
{
	int wanted = size * scale;
	int low;
	int high;
	switch (self.type)
	{
		case FIXED:
			low = self.size * self.scale;
			high = low;
		case SCALABLE:
			low = self.min_size * self.scale;
			high = self.max_size * self.scale;
		case THRESHOLD:
			low = (self.size - self.threshold) * self.scale;
			high = (self.size + self.threshold) * self.scale;
	}
	if (wanted < low) return low - wanted;
	if (wanted > high) return wanted - high;
	return 0;
}

<*
 Parse the text of an `index.theme`.

 @param [&inout] allocator : "Allocator for the theme's strings and arrays"
 @param name : "The theme's internal name, the directory it was found in"
 @param source : "The complete file contents, UTF-8"
 @return? error::PROTOCOL : "The file has no [Icon Theme] group, a directory has no Size, or a value is malformed"
*>
fn Theme? parse_index(Allocator allocator, String name, String source)
{
	KeyFile file = keyfile::parse(tmem, source)!;
	if (!file.has_group(
		ICON_THEME_GROUP
	)) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "no [Icon Theme] group")~;
	List{Directory} directories;
	directories.tinit();
	String[2] list_keys = { "Directories", "ScaledDirectories" };
	foreach (list_key : list_keys)
	{
		String[] sections = comma_list(&file, tmem, ICON_THEME_GROUP, list_key)!;
		foreach (section : sections)
		{
			// A listed directory without a section is skipped, as GTK does.
			if (!file.has_group(section)) continue;
			directories.push(parse_directory(&file, allocator, section)!);
		}
	}
	return {
		.name = name.copy(allocator),
		.display_name = string_value(&file, allocator, ICON_THEME_GROUP, "Name")!,
		.inherits = comma_list(&file, allocator, ICON_THEME_GROUP, "Inherits")!,
		.directories = directories.to_aligned_array(allocator),
	};
}

<*
 A new theme directory whose index.theme and icons are looked up on demand.

 @param [&inout] allocator : "Allocator for the cache; released with `release`"
 @param base_dirs : "Base directories in search order (see `default_base_dirs`)"
 @param theme : "The user's icon theme, for example Adwaita"
*>
fn Finder* open(Allocator allocator, String[] base_dirs, String theme) @inline
{
	Finder* finder = alloc::new(allocator, Finder);
	finder.parent = allocator;
	finder.arena.init(allocator, ARENA_PAGE_SIZE);
	finder.base_dirs = copy_all(&finder.arena, base_dirs);
	finder.theme = theme.copy(&finder.arena);
	finder.themes.init(&finder.arena);
	finder.listings.init(&finder.arena);
	return finder;
}

<* Free the cache, its themes and listings, and the finder itself. *>
fn void Finder.release(&self)
{
	Allocator parent = self.parent;
	self.arena.free();
	alloc::free(parent, self);
}

<* Forget every cached theme and listing, for when the icon files may have changed. *>
fn void Finder.clear(&self)
{
	self.themes.clear();
	self.listings.clear();
}

<*
 Find the file that draws icon `name` at `size` and `scale`, following the
 specification: the user's theme and its parents, then `hicolor` and its parents,
 then the unthemed fallback in the base directories. An absolute `name` is
 returned if it exists.

 @param [&inout] allocator : "Allocator for the returned path"
 @param name : "An icon name without extension, or an absolute path"
 @return? NOT_FOUND : "No theme and no fallback holds the icon; the caller picks its own fallback"
*>
fn String? Finder.find(&self, Allocator allocator, String name, int size, int scale)
{
	if (dirs::is_absolute(name))
	{
		if (io::file::is_file(name)) return name.copy(allocator);
		return NOT_FOUND~;
	}
	if (try path = self.find_in_theme(self.theme, name, size, scale, 0)) return path.copy(allocator);
	if (try path = self.find_in_theme(FALLBACK_THEME, name, size, scale, 0)) return path.copy(allocator);
	if (try path = self.lookup_fallback(name)) return path.copy(allocator);
	return NOT_FOUND~;
}

<*
 The default base directories, in the order the specification gives: `$HOME/.icons`,
 each `icons` directory under `$XDG_DATA_DIRS`, then `/usr/share/pixmaps`.
 `$XDG_DATA_HOME/icons` is not included, because the specification omits it.

 @param [&inout] allocator : "Allocator for the array and its strings"
*>
fn String[] default_base_dirs(Environment env, Allocator allocator)
{
	List{String} bases;
	bases.tinit();
	if (try home = env.get(tmem, "HOME"))
	{
		if (dirs::is_absolute(home)) bases.push(string::tformat("%s/%s", home.trim_right("/"), HOME_ICONS_DIRECTORY)
			.copy(allocator));
	}
	foreach (data : dirs::data_dirs(env, tmem))
	{
		bases.push(string::tformat("%s/%s", data.trim_right("/"), ICONS_DIRECTORY).copy(allocator));
	}
	bases.push(PIXMAPS_DIRECTORY.copy(allocator));
	return bases.to_aligned_array(allocator);
}

// The icon in `theme_name` or its parents, depth-limited against inheritance loops.
fn String? Finder.find_in_theme(&self, String theme_name, String name, int size, int scale, int depth)
{
	if (depth > MAX_THEME_DEPTH) return NOT_FOUND~;
	Theme* theme = self.load_theme(theme_name);
	if (!theme) return NOT_FOUND~;
	if (try path = self.lookup_in_theme(theme, name, size, scale)) return path;
	foreach (parent : theme.inherits)
	{
		if (try path = self.find_in_theme(parent, name, size, scale, depth + 1)) return path;
	}
	return NOT_FOUND~;
}

// Exact match first, then the closest size, in the specification's order.
fn String? Finder.lookup_in_theme(&self, Theme* theme, String name, int size, int scale)
{
	foreach (&dir : theme.directories)
	{
		if (!dir.matches(size, scale)) continue;
		if (try path = self.find_in_directory(theme, dir, name)) return path;
	}
	String chosen = "";
	int best      = 0;
	foreach (&dir : theme.directories)
	{
		int distance = dir.distance(size, scale);
		foreach (base : self.base_dirs)
		{
			foreach (extension : EXTENSIONS)
			{
				if (chosen.len > 0 && distance >= best) continue;
				if (try path = self.existing(theme_directory(base, theme, dir), file_name(name, extension)))
				{
					chosen = path;
					best = distance;
				}
			}
		}
	}
	if (chosen.len == 0) return NOT_FOUND~;
	return chosen;
}

// The first base directory and extension under which `name` exists in `dir`.
fn String? Finder.find_in_directory(&self, Theme* theme, Directory* dir, String name)
{
	foreach (base : self.base_dirs)
	{
		foreach (extension : EXTENSIONS)
		{
			if (try path = self.existing(theme_directory(base, theme, dir), file_name(name, extension))) return path;
		}
	}
	return NOT_FOUND~;
}

// The unthemed fallback: `name` with any supported extension directly in a base directory.
fn String? Finder.lookup_fallback(&self, String name)
{
	foreach (base : self.base_dirs)
	{
		foreach (extension : EXTENSIONS)
		{
			if (try path = self.existing(base, file_name(name, extension))) return path;
		}
	}
	return NOT_FOUND~;
}

// The parsed theme `name`, or null when no base directory holds a valid one. Cached.
fn Theme* Finder.load_theme(&self, String name)
{
	if (try cached = self.themes.get(name)) return cached;
	Theme* theme = null;
	foreach (base : self.base_dirs)
	{
		String index = string::tformat("%s/%s/%s", base, name, INDEX_FILE);
		if (!io::file::is_file(index)) continue;
		char[]? bytes = io::file::load(tmem, index);
		if (catch bytes) break;
		// A malformed index.theme is treated as absent, so the search goes on to the parents.
		if (try parsed = parse_index(&self.arena, name, (String)bytes))
		{
			theme = alloc::new(&self.arena, Theme);
			*theme = parsed;
		}
		break;
	}
	self.themes.set(name.copy(&self.arena), theme);
	return theme;
}

// `path` when the directory listing contains the file `file`. Cached per directory.
fn String? Finder.existing(&self, String directory, String file)
{
	if (!self.listing(directory).contains(file)) return NOT_FOUND~;
	return string::tformat("%s/%s", directory, file);
}

// The names in `directory`, read once and then cached. An unreadable directory is empty.
fn HashSet{String}* Finder.listing(&self, String directory)
{
	if (try cached = self.listings.get(directory)) return cached;
	HashSet{String}* names = alloc::new(&self.arena, HashSet{String});
	names.init(&self.arena);
	if (try entries = io::path::ls(tmem, (Path)directory))
	{
		foreach (entry : entries) names.add(entry.copy(&self.arena));
	}
	self.listings.set(directory.copy(&self.arena), names);
	return names;
}

// `base/theme/path` for one of the theme's directories.
fn String theme_directory(String base, Theme* theme, Directory* dir) @local
{
	return string::tformat("%s/%s/%s", base, theme.name, dir.path);
}

fn String file_name(String name, String extension) @local
{
	return string::tformat("%s%s%s", name, EXTENSION_SEPARATOR, extension);
}

// Parse one `[directory]` section. Size is required; the rest have the specification's defaults.
fn Directory? parse_directory(KeyFile* file, Allocator allocator, String group) @local
{
	int size      = required_int(file, group, "Size")!;
	int scale     = int_value(file, group, "Scale", DEFAULT_SCALE)!;
	int threshold = int_value(file, group, "Threshold", DEFAULT_THRESHOLD)!;
	return {
		.path = group.copy(allocator),
		.type = directory_type(file, group)!,
		.size = size,
		.scale = scale,
		.min_size = int_value(file, group, "MinSize", size)!,
		.max_size = int_value(file, group, "MaxSize", size)!,
		.threshold = threshold,
	};
}

// The `Type` of a directory, Threshold when absent.
fn DirectoryType? directory_type(KeyFile* file, String group) @local
{
	String value = string_value(file, tmem, group, "Type")!;
	if (value.len == 0 || value == "Threshold") return THRESHOLD;
	if (value == "Fixed") return FIXED;
	if (value == "Scalable") return SCALABLE;
	return error::raise(
		error::PROTOCOL,
		error::Domain.INTERNAL,
		0,
		"directory '%s' has unknown Type '%s'",
		group,
		value
	)~;
}

fn int? required_int(KeyFile* file, String group, String key) @local
{
	String value = string_value(file, tmem, group, key)!;
	if (value.len == 0) return error::raise(
		error::PROTOCOL,
		error::Domain.INTERNAL,
		0,
		"directory '%s' has no %s",
		group,
		key
	)~;
	return int_value(file, group, key, 0)!;
}

fn int? int_value(KeyFile* file, String group, String key, int fallback) @local
{
	String value = string_value(file, tmem, group, key)!;
	if (value.len == 0) return fallback;
	if (try number = value.to_int()) return number;
	return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "'%s' in [%s] is not an integer", key, group)~;
}

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

// A comma-separated list, as the Icon Theme specification defines every list.
// Blank items are dropped and surrounding blanks trimmed.
fn String[]? comma_list(KeyFile* file, Allocator allocator, String group, String key) @local
{
	String value = string_value(file, tmem, group, key)!;
	List{String} items;
	items.tinit();
	foreach (item : value.tsplit(",", 0, false))
	{
		String trimmed = item.trim(" \t");
		if (trimmed.len > 0) items.push(trimmed.copy(allocator));
	}
	return items.to_aligned_array(allocator);
}

fn String[] copy_all(Allocator allocator, String[] values) @local
{
	String[] copies = alloc::new_array(allocator, String, values.len);
	foreach (i, value : values) copies[i] = value.copy(allocator);
	return copies;
}

<*
 The cache that `open` returns. It holds a copy of the base directories and the
 theme name, parsed themes (null for a theme that is absent), and one listing
 per directory it has read.
*>
struct Finder
{
	Allocator parent;
	DynamicArenaAllocator arena;
	String[] base_dirs;
	String theme;
	HashMap{String, Theme*} themes;
	HashMap{String, HashSet{String}*} listings;
}