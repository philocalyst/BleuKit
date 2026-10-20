// Unit tests for the absolute-path rules of the wallpaper request: POSIX, and Windows drive and UNC paths.
module bleu::appearance::paths_test;
import bleu::appearance;

fn void posix_paths_are_absolute_from_the_root() @test
{
	assert(appearance::is_absolute_posix_path("/usr/share/a.png"));
	assert(!appearance::is_absolute_posix_path("a.png"));
	assert(!appearance::is_absolute_posix_path(""));
	assert(!appearance::is_absolute_posix_path("C:\\a.png"), "a Windows drive is not POSIX-absolute");
}

fn void windows_drive_and_unc_paths_are_absolute() @test
{
	assert(appearance::is_absolute_windows_path("C:\\Users\\a.png"), "drive, colon, backslash");
	assert(appearance::is_absolute_windows_path("d:/pictures/a.png"), "a forward slash also separates");
	assert(appearance::is_absolute_windows_path("\\\\server\\share\\a.png"), "UNC path");
	assert(appearance::is_absolute_windows_path("\\\\?\\C:\\a.png"), "long-path form");
}

fn void windows_relative_and_rooted_paths_are_refused() @test
{
	assert(!appearance::is_absolute_windows_path("a.png"), "relative");
	assert(!appearance::is_absolute_windows_path("C:a.png"), "drive-relative");
	assert(!appearance::is_absolute_windows_path("\\a.png"), "rooted without a drive");
	assert(!appearance::is_absolute_windows_path("/usr/a.png"), "rooted without a drive");
	assert(!appearance::is_absolute_windows_path("\\\\"), "two separators and no name");
	assert(!appearance::is_absolute_windows_path(""));
}