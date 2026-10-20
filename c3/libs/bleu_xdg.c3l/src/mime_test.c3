// Unit tests for MIME associations over a real tree: the mimeapps.list precedence,
// desktop-specific defaults, added and removed associations, the blacklist, and
// the mimeinfo.cache reader.
module bleu::xdg::mime;
import bleu::error, bleu::xdg::dirs, std::io, std::collections::list, std::core::test;

const String DESKTOP_TEXT = "[Desktop Entry]\nType=Application\nName=%s\nExec=%s\nMimeType=%s\n";

const String GENERIC_CONFIG = `[Default Applications]
text/plain=b.desktop;missing.desktop;
image/x-foo=foo.desktop;

[Added Associations]
application/x-bar=bar.desktop;
image/x-foo=extra.desktop;

[Removed Associations]
image/png=gone.desktop;
`;

fn void write_desktop(String path, String mime) @local
{
	String body = string::tformat(DESKTOP_TEXT, "App", "app", mime);
	io::file::save(path, (char[])body)!!;
}

// config/ (mimeapps files), data/applications (desktop files), sys/applications (a lower-precedence copy of a.desktop).
fn String make_tree(String name) @local
{
	String root = string::tformat("%s/bleu-xdg-mime-%s", io::path::temp_directory(tmem)!!, name);
	if (catch io::path::rmtree((Path)root))
	{
	}
	io::path::mkdir((Path)string::tformat("%s/config", root), true)!!;
	io::path::mkdir((Path)string::tformat("%s/data/applications/sub", root), true)!!;
	io::path::mkdir((Path)string::tformat("%s/sys/applications", root), true)!!;
	io::file::save(string::tformat("%s/config/mimeapps.list", root), (char[])GENERIC_CONFIG)!!;
	io::file::save(
		string::tformat("%s/config/gnome-mimeapps.list", root),
		(char[])"[Default Applications]\ntext/plain=a.desktop;\n"
	)!!;
	String apps = string::tformat("%s/data/applications", root);
	write_desktop(string::tformat("%s/a.desktop", apps), "text/plain;");
	write_desktop(string::tformat("%s/b.desktop", apps), "text/plain;text/markdown;");
	write_desktop(string::tformat("%s/foo.desktop", apps), "image/x-foo;");
	write_desktop(string::tformat("%s/bar.desktop", apps), "image/x-other;");
	write_desktop(string::tformat("%s/gone.desktop", apps), "image/png;");
	write_desktop(string::tformat("%s/sub/c.desktop", apps), "text/plain;");
	write_desktop(string::tformat("%s/sys/applications/a.desktop", root), "text/plain;");
	return root;
}

fn void defaults_follow_desktop_specific_then_generic_files() @test
{
	String root = make_tree("defaults");
	defer (void)io::path::rmtree((Path)root);
	Variables env = {
		.names = { "XDG_CONFIG_HOME", "XDG_CONFIG_DIRS", "XDG_DATA_HOME", "XDG_DATA_DIRS", "XDG_CURRENT_DESKTOP" },
		.values = {
			string::tformat("%s/config", root),
			string::tformat("%s/none", root),
			string::tformat("%s/data", root),
			string::tformat("%s/sys", root),
			"GNOME"
		},
	};
	// The GNOME-specific file names a.desktop, which precedes the generic file's b.desktop.
	test::eq("a.desktop", default_application(&env, tmem, "text/plain")!!);
	Variables no_desktop = {
		.names = { "XDG_CONFIG_HOME", "XDG_CONFIG_DIRS", "XDG_DATA_HOME", "XDG_DATA_DIRS" },
		.values = {
			string::tformat("%s/config", root),
			string::tformat("%s/none", root),
			string::tformat("%s/data", root),
			string::tformat("%s/sys", root)
		},
	};
	// Without a desktop the generic file applies: b.desktop, then missing.desktop (skipped as it does not exist).
	test::eq("b.desktop", default_application(&no_desktop, tmem, "text/plain")!!);
	// foo.desktop is listed as the default and declares the type.
	test::eq("foo.desktop", default_application(&no_desktop, tmem, "image/x-foo")!!);
}

fn void associations_add_scan_and_remove() @test
{
	String root = make_tree("assoc");
	defer (void)io::path::rmtree((Path)root);
	Variables env = {
		.names = { "XDG_CONFIG_HOME", "XDG_CONFIG_DIRS", "XDG_DATA_HOME", "XDG_DATA_DIRS" },
		.values = {
			string::tformat("%s/config", root),
			string::tformat("%s/none", root),
			string::tformat("%s/data", root),
			string::tformat("%s/sys", root)
		},
	};
	String[] plain = associated_applications(&env, tmem, "text/plain");
	test::@check(has_id(plain, "a.desktop"), "a.desktop declares text/plain");
	test::@check(has_id(plain, "b.desktop"), "b.desktop declares text/plain");
	test::@check(has_id(plain, "sub-c.desktop"), "a subdirectory id is sub-c.desktop");
	test::@check(!has_id(plain, "foo.desktop"), "foo.desktop does not declare text/plain");
	test::eq(1, count(plain, "a.desktop"));

	String[] foo = associated_applications(&env, tmem, "image/x-foo");
	test::@check(has_id(foo, "extra.desktop"), "added association is listed");
	test::@check(has_id(foo, "foo.desktop"), "declared association is listed");

	String[] png = associated_applications(&env, tmem, "image/png");
	test::@check(!has_id(png, "gone.desktop"), "removed association is blacklisted");

	String[] bar = associated_applications(&env, tmem, "application/x-bar");
	test::eq(1, bar.len);
	test::eq("bar.desktop", bar[0]);
}

fn void default_falls_back_to_the_first_association() @test
{
	String root = make_tree("fallback");
	defer (void)io::path::rmtree((Path)root);
	Variables env = {
		.names = { "XDG_CONFIG_HOME", "XDG_CONFIG_DIRS", "XDG_DATA_HOME", "XDG_DATA_DIRS" },
		.values = {
			string::tformat("%s/config", root),
			string::tformat("%s/none", root),
			string::tformat("%s/data", root),
			string::tformat("%s/sys", root)
		},
	};
	// No default is listed for application/x-bar: the added association is used.
	test::eq("bar.desktop", default_application(&env, tmem, "application/x-bar")!!);
	test::@error(default_application(&env, tmem, "video/mp4"), NOT_FOUND);
}

fn bool has_id(String[] list, String value) @local
{
	foreach (item : list)
	{
		if (item == value) return true;
	}
	return false;
}

fn int count(String[] list, String value) @local
{
	int n = 0;
	foreach (item : list)
	{
		if (item == value) n++;
	}
	return n;
}

fn void mimeinfo_cache_lists_applications() @test
{
	String cache = "[MIME Cache]\ntext/plain=a.desktop;b.desktop;\nimage/png=x.desktop;\n";
	String[] ids = cached_applications(cache, tmem, "text/plain");
	test::eq(2, ids.len);
	test::eq("b.desktop", ids[1]);
	test::eq(0, cached_applications(cache, tmem, "video/mp4").len);
	test::eq(0, cached_applications("not a cache [[[", tmem, "text/plain").len);
}

fn void sources_list_desktop_specific_files_first() @test
{
	Variables env = {
		.names = { "XDG_CONFIG_HOME", "XDG_CONFIG_DIRS", "XDG_DATA_HOME", "XDG_DATA_DIRS", "XDG_CURRENT_DESKTOP" },
		.values = { "/c", "/etc/xdg", "/d", "/usr/share", "GNOME:Unity" },
	};
	Source[] all = sources(&env, tmem);
	test::eq("/c/gnome-mimeapps.list", all[0].path);
	test::@check(all[0].desktop_specific, "desktop-specific");
	test::eq("/c/unity-mimeapps.list", all[1].path);
	test::eq("/c/mimeapps.list", all[2].path);
	test::@check(!all[2].desktop_specific, "generic");
	test::eq("", all[2].data_directory);
	// Data locations come after configuration ones, and carry their data directory.
	bool found_data = false;
	foreach (source : all)
	{
		if (source.path == "/d/applications/mimeapps.list") found_data = source.data_directory == "/d";
	}
	test::@check(found_data, "data home mimeapps.list carries its data directory");
}