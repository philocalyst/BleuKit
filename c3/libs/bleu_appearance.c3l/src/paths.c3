<*
 What counts as an absolute path for a wallpaper, on each platform. Pure text rules: no file is touched, so
 every host runs the tests in `paths_test.c3`.
*>
module bleu::appearance;

<*
 Whether `path` is absolute on the platform being compiled: "/" first on POSIX; on Windows a drive
 ("C:\" or "C:/") or a UNC path ("\\server\share", and the "\\?\" long form).
*>
fn bool is_absolute_path(String path)
{
	$switch:
		$case env::WIN32:
			return is_absolute_windows_path(path);
		$default:
			return is_absolute_posix_path(path);
	$endswitch
}

<* Absolute on POSIX: the path starts with a slash. *>
fn bool is_absolute_posix_path(String path) => path.len > 0 && path[0] == '/';

<*
 Absolute on Windows: a drive letter, a colon and a separator ("C:\pictures\a.png"), or two separators and a
 name ("\\server\share\a.png", and "\\?\C:\a.png"). A rooted path without a drive ("\a.png") and a
 drive-relative one ("C:a.png") are not absolute.
*>
fn bool is_absolute_windows_path(String path)
{
	if (path.len >= 3 && is_drive_letter(path[0]) && path[1] == ':' && is_path_separator(path[2])) return true;
	return path.len >= 3 && is_path_separator(path[0]) && is_path_separator(path[1]) && !is_path_separator(path[2]);
}

fn bool is_drive_letter(char c) @private => (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');

fn bool is_path_separator(char c) @private => c == '\\' || c == '/';
