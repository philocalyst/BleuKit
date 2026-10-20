<*
 The `Info.plist` of a macOS application bundle, as a typed model, with the
 localized names from `InfoPlist.strings`, and the list of directories where
 applications are installed.

 Source: Apple "Information Property List Key Reference" (CFBundleIdentifier,
 CFBundleName, CFBundleDisplayName, CFBundleExecutable, CFBundleIconFile,
 CFBundleIconName, CFBundleShortVersionString, LSApplicationCategoryType,
 LSUIElement, LSBackgroundOnly, CFBundleURLTypes, CFBundleURLName,
 CFBundleURLSchemes), "Localized Information Property List Keys" (the
 `<language>.lproj/InfoPlist.strings` lookup), and the "Bundle Programming
 Guide" (the bundle layout, `Contents/Info.plist` and `Contents/Resources`).
 The key names were written from that reference, not re-fetched; the readers
 they depend on are verified (see `plist.c3`).
 The application directories are the four the project's brief names.

 Localization: for each preferred language (most preferred first), the bundle's
 `<language>.lproj` is tried, then its base language (`de` for `de_DE`), and
 finally `Base.lproj`. The first `InfoPlist.strings` that holds the key wins;
 otherwise the value in `Info.plist` is used.

 `LSUIElement` and `LSBackgroundOnly` accept a boolean, and also the strings `1`,
 `YES`, `yes`, `true` and `TRUE`, which bundles in the wild use. Apple's key
 reference describes the boolean only; the string forms were not verified against
 LaunchServices.

 Not done: the bundle's icon file is only named, never read or located (the
 `.icns` decoding is out of scope); flat (iOS-style) bundles without `Contents/`
 are not recognised.
*>
module bleu::plist::app_bundle;
import bleu::error, bleu::plist, bleu::plist::value, std::io, std::collections::list;

const String CONTENTS_DIRECTORY      = "Contents";
const String INFO_PLIST_FILE         = "Info.plist";
const String RESOURCES_DIRECTORY     = "Resources";
const String STRINGS_FILE            = "InfoPlist.strings";
const String LPROJ_SUFFIX            = ".lproj";
const String BASE_LOCALIZATION       = "Base";
const String APPLICATION_SUFFIX      = ".app";
const char LANGUAGE_REGION_SEPARATOR = '_';
const char LANGUAGE_SCRIPT_SEPARATOR = '-';
const String KEY_IDENTIFIER          = "CFBundleIdentifier";
const String KEY_NAME                = "CFBundleName";
const String KEY_DISPLAY_NAME        = "CFBundleDisplayName";
const String KEY_EXECUTABLE          = "CFBundleExecutable";
const String KEY_ICON_FILE           = "CFBundleIconFile";
const String KEY_ICON_NAME           = "CFBundleIconName";
const String KEY_SHORT_VERSION       = "CFBundleShortVersionString";
const String KEY_CATEGORY            = "LSApplicationCategoryType";
const String KEY_UI_ELEMENT          = "LSUIElement";
const String KEY_BACKGROUND_ONLY     = "LSBackgroundOnly";
const String KEY_URL_TYPES           = "CFBundleURLTypes";
const String KEY_URL_NAME            = "CFBundleURLName";
const String KEY_URL_SCHEMES         = "CFBundleURLSchemes";
const String[5] TRUE_STRINGS         = { "1", "YES", "yes", "true", "TRUE" };
const String SYSTEM_APPLICATIONS     = "/System/Applications";
const String APPLICATIONS            = "/Applications";
const String USER_APPLICATIONS       = "Applications";
const String SYSTEM_UTILITIES        = "/System/Applications/Utilities";

<* A URL scheme a bundle handles (`CFBundleURLTypes`). *>
struct UrlType
{
	String name;
	String[] schemes;
}

<*
 An application bundle, with the keys a launcher, a dock or a menu needs. Missing
 strings are empty and missing flags are false.
*>
struct AppBundle
{
	String path;
	String bundle_id;
	String name;
	String display_name;
	String executable;
	String icon_file;
	String icon_name;
	String short_version;
	String category;
	bool ui_element;
	bool background_only;
	UrlType[] url_types;
}

<*
 Read the `Info.plist` of the bundle at `bundle_path`, resolving the localized
 names for `languages` (most preferred first, for example `de_DE`, `en`).

 @param [&inout] allocator : "Allocator for every string and array in the result"
 @param bundle_path : "The path of the `.app` directory"
 @param languages : "Preferred language identifiers; may be empty"
 @return? NOT_FOUND : "There is no Contents/Info.plist"
 @return? error::PROTOCOL : "Info.plist is malformed or its root is not a dictionary"
 @return? error::PERMISSION_DENIED : "Info.plist exists but the OS refuses to read it"
 @return? error::OUT_OF_RANGE : "Info.plist is larger than the reader accepts"
 @return? error::BACKEND_FAILURE : "Info.plist exists but could not be read for another reason"
*>
fn AppBundle? read(Allocator allocator, String bundle_path, String[] languages)
{
	String info_path = string::tformat("%s/%s/%s", bundle_path.trim_right("/"), CONTENTS_DIRECTORY, INFO_PLIST_FILE);
	char[]? bytes    = load_plist_file(info_path);
	if (catch err = bytes)
	{
		if (err == io::FILE_NOT_FOUND || err == io::PATH_COULD_NOT_BE_FOUND) return NOT_FOUND~;
		if (err == io::NO_PERMISSION) return error::PERMISSION_DENIED~;
		if (err == error::OUT_OF_RANGE) return err~;
		return error::raise(error::BACKEND_FAILURE, error::Domain.INTERNAL, 0, "could not read %s", info_path)~;
	}
	Value info = plist::read(tmem, bytes)!;
	if (!info.is(
		DICT
	)) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "Info.plist root is not a dictionary")~;
	return {
		.path = bundle_path.copy(allocator),
		.bundle_id = plain_string(&info, allocator, KEY_IDENTIFIER),
		.name = localized_string(allocator, bundle_path, languages, &info, KEY_NAME),
		.display_name = localized_string(allocator, bundle_path, languages, &info, KEY_DISPLAY_NAME),
		.executable = plain_string(&info, allocator, KEY_EXECUTABLE),
		.icon_file = plain_string(&info, allocator, KEY_ICON_FILE),
		.icon_name = plain_string(&info, allocator, KEY_ICON_NAME),
		.short_version = plain_string(&info, allocator, KEY_SHORT_VERSION),
		.category = plain_string(&info, allocator, KEY_CATEGORY),
		.ui_element = flag(&info, KEY_UI_ELEMENT),
		.background_only = flag(&info, KEY_BACKGROUND_ONLY),
		.url_types = url_types(&info, allocator),
	};
}

<*
 The directories where applications live, in the Finder's search order:
 `/Applications`, `/System/Applications`, `~/Applications` (when `home` is not
 empty) and `/System/Applications/Utilities`.

 @param [&inout] allocator : "Allocator for the array and its strings"
 @param home : "The user's home directory, or empty to leave out ~/Applications"
*>
fn String[] applications_directories(String home, Allocator allocator)
{
	List{String} directories;
	directories.init(allocator);
	directories.push(APPLICATIONS.copy(allocator));
	directories.push(SYSTEM_APPLICATIONS.copy(allocator));
	if (home.len > 0) directories.push(string::tformat("%s/%s", home.trim_right("/"), USER_APPLICATIONS)
		.copy(allocator));
	directories.push(SYSTEM_UTILITIES.copy(allocator));
	return directories.to_aligned_array(allocator);
}

<*
 The `.app` bundles directly inside each of `applications_directories`. A
 directory that cannot be read is skipped.

 @param [&inout] allocator : "Allocator for the array and its strings"
 @param home : "The user's home directory, or empty to leave out ~/Applications"
*>
fn String[] bundle_paths(String home, Allocator allocator)
{
	List{String} found;
	found.init(allocator);
	foreach (directory : applications_directories(home, tmem))
	{
		PathList? entries = io::path::ls(tmem, (Path)directory);
		if (catch err = entries) continue;
		foreach (entry : entries)
		{
			if (!entry.ends_with(APPLICATION_SUFFIX)) continue;
			String path = string::tformat("%s/%s", directory, entry);
			if (io::file::is_dir(path)) found.push(path.copy(allocator));
		}
	}
	return found.to_aligned_array(allocator);
}

// A string key of `info` that is not localized, or "".
fn String plain_string(Value* info, Allocator allocator, String key) @local
{
	if (try found = info.get(key))
	{
		if (try text = found.as_string()) return text.copy(allocator);
	}
	return "";
}

// A boolean key of `info`, false when absent or not one of the accepted forms.
fn bool flag(Value* info, String key) @local
{
	if (try found = info.get(key))
	{
		if (try truth = found.as_bool()) return truth;
		if (try text = found.as_string())
		{
			foreach (accepted : TRUE_STRINGS)
			{
				if (text == accepted) return true;
			}
		}
	}
	return false;
}

// The localized value of `key`: the first `InfoPlist.strings` in the language order that holds it, else `info`'s own.
fn String localized_string(Allocator allocator, String bundle_path, String[] languages, Value* info, String key) @local
{
	foreach (language : languages)
	{
		if (try text = strings_value(bundle_path, language, key, allocator)) return text;
		String base = language_base(language);
		if (base.len > 0 && base != language)
		{
			if (try text = strings_value(bundle_path, base, key, allocator)) return text;
		}
	}
	if (try text = strings_value(bundle_path, BASE_LOCALIZATION, key, allocator)) return text;
	return plain_string(info, allocator, key);
}

// The string `key` of `<language>.lproj/InfoPlist.strings`, when that file exists and holds it.
fn String? strings_value(String bundle_path, String language, String key, Allocator allocator) @local
{
	if (!is_path_component(language)) return NOT_FOUND~;
	String path = string::tformat(
		"%s/%s/%s/%s%s/%s",
		bundle_path.trim_right("/"),
		CONTENTS_DIRECTORY,
		RESOURCES_DIRECTORY,
		language,
		LPROJ_SUFFIX,
		STRINGS_FILE
	);
	if (!io::file::is_file(path)) return NOT_FOUND~;
	char[]? bytes = load_plist_file(path);
	if (catch err = bytes) return NOT_FOUND~;
	// A strings file that does not parse holds nothing, so the lookup moves on.
	if (try strings = plist::read(tmem, bytes))
	{
		if (!strings.is(DICT)) return NOT_FOUND~;
		if (try found = strings.get(key))
		{
			if (try text = found.as_string()) return text.copy(allocator);
		}
	}
	return NOT_FOUND~;
}

// The largest property list the bundle reader loads, in bytes. Real Info.plist and
// InfoPlist.strings files are a few kilobytes; a bundle a user can write must not
// make the reader load a gigabyte.
const long MAX_PLIST_FILE_BYTES = 1024 * 1024;

// The whole property list at `path`, which must be at most `MAX_PLIST_FILE_BYTES`.
// An oversized file is refused as OUT_OF_RANGE before it is read.
fn char[]? load_plist_file(String path) @local
{
	long size = io::file::get_size(path)!;
	if (size > MAX_PLIST_FILE_BYTES) return error::raise(
		error::OUT_OF_RANGE,
		error::Domain.INTERNAL,
		0,
		"%s is %d bytes, more than the %d the reader accepts",
		path,
		size,
		MAX_PLIST_FILE_BYTES
	)~;
	return io::file::load(tmem, path);
}

// Whether `name` can be one path component: not empty, and without a separator or `..`.
// A language identifier from the caller is joined into a path, so it must pass this.
fn bool is_path_component(String name) @local
{
	return name.len > 0 && !name.contains("/") && !name.contains("\\") && !name.contains("..");
}

// The language without its region or script: `de` for `de_DE` or `de-AT`, else "".
fn String language_base(String language) @local
{
	if (try cut = language.index_of_char(LANGUAGE_REGION_SEPARATOR)) return language[:cut];
	if (try cut = language.index_of_char(LANGUAGE_SCRIPT_SEPARATOR)) return language[:cut];
	return "";
}

// The `CFBundleURLTypes` entries that are dictionaries with a scheme list.
fn UrlType[] url_types(Value* info, Allocator allocator) @local
{
	List{UrlType} types;
	types.init(allocator);
	if (try list = info.get(KEY_URL_TYPES))
	{
		if (list.is(ARRAY))
		{
			foreach (&entry : list.items)
			{
				if (!entry.is(DICT)) continue;
				types.push(
					{
						.name = plain_string(entry, allocator, KEY_URL_NAME),
						.schemes = schemes(entry, allocator),
					}
				);
			}
		}
	}
	return types.to_aligned_array(allocator);
}

// The strings in a URL type's `CFBundleURLSchemes` array.
fn String[] schemes(Value* entry, Allocator allocator) @local
{
	List{String} found;
	found.init(allocator);
	if (try list = entry.get(KEY_URL_SCHEMES))
	{
		if (list.is(ARRAY))
		{
			foreach (&item : list.items)
			{
				if (try text = item.as_string()) found.push(text.copy(allocator));
			}
		}
	}
	return found.to_aligned_array(allocator);
}