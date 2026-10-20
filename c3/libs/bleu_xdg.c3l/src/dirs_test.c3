// Unit tests for the Base Directory rules. Every case injects its environment,
// so no test depends on the machine running it.
module bleu::xdg::dirs;
import bleu::error, std::core::test;

fn void defaults_come_from_home() @test
{
	Variables vars = { .names = { "HOME" }, .values = { "/home/ann" } };
	test::eq("/home/ann/.local/share", data_home(&vars, tmem)!!);
	test::eq("/home/ann/.config", config_home(&vars, tmem)!!);
	test::eq("/home/ann/.cache", cache_home(&vars, tmem)!!);
	test::eq("/home/ann/.local/state", state_home(&vars, tmem)!!);
}

fn void absolute_variables_win_over_home() @test
{
	Variables vars = {
		.names = { "HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME" },
		.values = { "/home/ann", "/data", "/conf/" },
	};
	test::eq("/data", data_home(&vars, tmem)!!);
	test::eq("/conf/", config_home(&vars, tmem)!!);
}

fn void relative_variables_are_ignored() @test
{
	Variables vars = {
		.names = { "HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME" },
		.values = { "/home/ann", "data", "./cache" },
	};
	test::eq("/home/ann/.local/share", data_home(&vars, tmem)!!);
	test::eq("/home/ann/.cache", cache_home(&vars, tmem)!!);
}

fn void empty_variables_mean_unset() @test
{
	Variables vars = {
		.names = { "HOME", "XDG_STATE_HOME" },
		.values = { "/home/ann", "" },
	};
	test::eq("/home/ann/.local/state", state_home(&vars, tmem)!!);
}

fn void missing_home_is_unavailable() @test
{
	Variables vars = { .names = { }, .values = { } };
	test::@error(data_home(&vars, tmem), error::UNAVAILABLE);
	test::@error(config_home(&vars, tmem), error::UNAVAILABLE);
}

fn void userprofile_is_the_windows_home_fallback() @test
{
	Variables vars = { .names = { "USERPROFILE" }, .values = { "C:\\Users\\ann" } };
	test::eq("C:\\Users\\ann/.local/share", data_home(&vars, tmem)!!);
	Variables relative = { .names = { "HOME" }, .values = { "home" } };
	test::@error(data_home(&relative, tmem), error::UNAVAILABLE);
}

fn void root_home_does_not_double_the_separator() @test
{
	Variables vars = { .names = { "HOME" }, .values = { "/" } };
	test::eq("/.cache", cache_home(&vars, tmem)!!);
}

fn void runtime_dir_has_no_default() @test
{
	Variables vars = { .names = { "HOME" }, .values = { "/home/ann" } };
	test::@error(runtime_dir(&vars, tmem), error::UNAVAILABLE);
	Variables relative = { .names = { "XDG_RUNTIME_DIR" }, .values = { "run/user" } };
	test::@error(runtime_dir(&relative, tmem), error::UNAVAILABLE);
	Variables set = { .names = { "XDG_RUNTIME_DIR" }, .values = { "/run/user/1000" } };
	test::eq("/run/user/1000", runtime_dir(&set, tmem)!!);
}

fn void data_dirs_default_and_filtering() @test
{
	Variables none    = { .names = { }, .values = { } };
	String[] defaults = data_dirs(&none, tmem);
	test::eq(2, defaults.len);
	test::eq("/usr/local/share/", defaults[0]);
	test::eq("/usr/share/", defaults[1]);

	Variables messy = { .names = { "XDG_DATA_DIRS" }, .values = { "a:/x::/y:" } };
	String[] kept   = data_dirs(&messy, tmem);
	test::eq(2, kept.len);
	test::eq("/x", kept[0]);
	test::eq("/y", kept[1]);
}

fn void config_dirs_default_is_etc_xdg() @test
{
	Variables none = { .names = { }, .values = { } };
	String[] dirs  = config_dirs(&none, tmem);
	test::eq(1, dirs.len);
	test::eq("/etc/xdg", dirs[0]);
}

fn void absolute_paths_are_recognised() @test
{
	test::@check(is_absolute("/x"), "unix root is absolute");
	test::@check(is_absolute("C:\\x"), "drive letter is absolute");
	test::@check(!is_absolute("x/y"), "bare relative path");
	test::@check(!is_absolute("1:/x"), "digit is not a drive letter");
	test::@check(!is_absolute(""), "empty is not absolute");
}