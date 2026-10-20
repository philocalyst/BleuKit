// Unit tests for icon theme parsing, the size rules, and lookup over a real tree
// that holds a theme, its parent, hicolor and an unthemed fallback.
module bleu::xdg::icon;
import bleu::error, bleu::xdg::dirs, std::io, std::core::test;

const String INDEX_A = `[Icon Theme]
Name=Theme A
Directories=48x48/apps,32x32/apps,scalable/apps,16x16@2/apps
Inherits=parent

[48x48/apps]
Size=48

[32x32/apps]
Size=32
Type=Fixed

[scalable/apps]
Size=64
Type=Scalable
MinSize=8
MaxSize=256

[16x16@2/apps]
Size=16
Scale=2
`;

fn Directory dir(DirectoryType type, int size, int scale, int threshold = 2) @inline
{
	return { .path = "d", .type = type, .size = size, .scale = scale, .min_size = size, .max_size = size, .threshold = threshold };
}

fn void index_defaults_and_types() @test
{
	Theme theme = parse_index(tmem, "theme-a", INDEX_A)!!;
	test::eq("theme-a", theme.name);
	test::eq("Theme A", theme.display_name);
	test::eq(1, theme.inherits.len);
	test::eq(4, theme.directories.len);
	test::eq(DirectoryType.THRESHOLD, theme.directories[0].type);
	test::eq(2, theme.directories[0].threshold);
	test::eq(1, theme.directories[0].scale);
	test::eq(DirectoryType.FIXED, theme.directories[1].type);
	test::eq(DirectoryType.SCALABLE, theme.directories[2].type);
	test::eq(8, theme.directories[2].min_size);
	test::eq(256, theme.directories[2].max_size);
	test::eq(2, theme.directories[3].scale);
}

fn void index_needs_its_group_and_sizes() @test
{
	test::@error(parse_index(tmem, "t", "[Other]\nName=x\n"), error::PROTOCOL);
	test::@error(parse_index(tmem, "t", "[Icon Theme]\nDirectories=a/b\n[a/b]\nContext=Apps\n"), error::PROTOCOL);
	test::@error(parse_index(tmem, "t", "[Icon Theme]\nDirectories=a/b\n[a/b]\nSize=ten\n"), error::PROTOCOL);
	test::@error(parse_index(tmem, "t", "[Icon Theme]\nDirectories=a/b\n[a/b]\nSize=4\nType=Stretchy\n"), error::PROTOCOL);
	// A listed directory with no section is skipped, not an error.
	Theme theme = parse_index(tmem, "t", "[Icon Theme]\nDirectories=missing/apps\n")!!;
	test::eq(0, theme.directories.len);
}

fn void threshold_matching_and_distance() @test
{
	Directory d = dir(DirectoryType.THRESHOLD, 48, 1);
	test::@check(d.matches(46, 1) && d.matches(50, 1), "inside the threshold");
	test::@check(!d.matches(45, 1) && !d.matches(51, 1), "outside the threshold");
	test::@check(!d.matches(48, 2), "scale must match");
	test::eq(0, d.distance(48, 1));
	test::eq(2, d.distance(44, 1));
	test::eq(2, d.distance(52, 1));
	// Scale 2 puts the threshold window at 92..100 scaled pixels; a 48 px request is 44 away.
	test::eq(44, dir(DirectoryType.THRESHOLD, 48, 2).distance(48, 1));
}

fn void fixed_and_scalable_rules() @test
{
	Directory fixed = dir(DirectoryType.FIXED, 32, 1);
	test::@check(fixed.matches(32, 1) && !fixed.matches(33, 1), "fixed is exact");
	test::eq(8, fixed.distance(24, 1));
	Directory scalable = { .path = "s", .type = DirectoryType.SCALABLE, .size = 64, .scale = 1, .min_size = 8, .max_size = 256, .threshold = 2 };
	test::@check(scalable.matches(100, 1) && !scalable.matches(4, 1), "scalable range");
	test::eq(4, scalable.distance(4, 1));
	test::eq(44, scalable.distance(300, 1));
	test::eq(0, scalable.distance(64, 1));
	Directory hi_dpi = dir(DirectoryType.FIXED, 16, 2);
	test::@check(hi_dpi.matches(16, 2) && !hi_dpi.matches(16, 1), "16@2 only matches scale 2");
}

fn String make_tree(String name) @local
{
	String root = string::tformat("%s/bleu-xdg-icons-%s", io::path::temp_directory(tmem)!!, name);
	if (catch io::path::rmtree((Path)root)) {}
	String a = string::tformat("%s/base/theme-a", root);
	String parent = string::tformat("%s/base/parent", root);
	String hicolor = string::tformat("%s/base/hicolor", root);
	io::path::mkdir((Path)string::tformat("%s/48x48/apps", a), true)!!;
	io::path::mkdir((Path)string::tformat("%s/32x32/apps", a), true)!!;
	io::path::mkdir((Path)string::tformat("%s/scalable/apps", a), true)!!;
	io::path::mkdir((Path)string::tformat("%s/16x16@2/apps", a), true)!!;
	io::path::mkdir((Path)string::tformat("%s/16x16/apps", parent), true)!!;
	io::path::mkdir((Path)string::tformat("%s/24x24/apps", hicolor), true)!!;
	io::file::save(string::tformat("%s/index.theme", a), (char[])INDEX_A)!!;
	io::file::save(string::tformat("%s/index.theme", parent), (char[])"[Icon Theme]\nName=Parent\nDirectories=16x16/apps\n[16x16/apps]\nSize=16\n")!!;
	io::file::save(string::tformat("%s/index.theme", hicolor), (char[])"[Icon Theme]\nName=hicolor\nDirectories=24x24/apps\n[24x24/apps]\nSize=24\n")!!;
	io::file::save(string::tformat("%s/48x48/apps/foo.png", a), (char[])"x")!!;
	io::file::save(string::tformat("%s/32x32/apps/bar.svg", a), (char[])"x")!!;
	io::file::save(string::tformat("%s/scalable/apps/baz.svg", a), (char[])"x")!!;
	io::file::save(string::tformat("%s/16x16@2/apps/qq.xpm", a), (char[])"x")!!;
	io::file::save(string::tformat("%s/16x16/apps/only.png", parent), (char[])"x")!!;
	io::file::save(string::tformat("%s/24x24/apps/hic.png", hicolor), (char[])"x")!!;
	io::file::save(string::tformat("%s/base/legacy.xpm", root), (char[])"x")!!;
	return root;
}

fn void lookup_follows_the_specification() @test
{
	String root = make_tree("lookup");
	defer (void)io::path::rmtree((Path)root);
	String[] bases = { string::tformat("%s/base", root) };
	Finder* finder = open(mem, bases, "theme-a");
	defer finder.release();
	String base = bases[0];

	test::eq(string::tformat("%s/theme-a/48x48/apps/foo.png", base), finder.find(tmem, "foo", 48, 1)!!);
	test::eq(string::tformat("%s/theme-a/32x32/apps/bar.svg", base), finder.find(tmem, "bar", 32, 1)!!);
	test::eq(string::tformat("%s/theme-a/scalable/apps/baz.svg", base), finder.find(tmem, "baz", 100, 1)!!);
	test::eq(string::tformat("%s/theme-a/16x16@2/apps/qq.xpm", base), finder.find(tmem, "qq", 16, 2)!!);
	test::eq(string::tformat("%s/parent/16x16/apps/only.png", base), finder.find(tmem, "only", 16, 1)!!);
	test::eq(string::tformat("%s/hicolor/24x24/apps/hic.png", base), finder.find(tmem, "hic", 24, 1)!!);
	test::eq(string::tformat("%s/legacy.xpm", base), finder.find(tmem, "legacy", 22, 1)!!);
	test::@error(finder.find(tmem, "missing", 16, 1), NOT_FOUND);
}

fn void closest_size_is_used_when_no_directory_matches() @test
{
	String root = make_tree("closest");
	defer (void)io::path::rmtree((Path)root);
	String[] bases = { string::tformat("%s/base", root) };
	Finder* finder = open(mem, bases, "theme-a");
	defer finder.release();
	// 40 px matches no fixed or threshold range; the 48 px directory is the closest that has the icon.
	test::eq(string::tformat("%s/base/theme-a/48x48/apps/foo.png", root), finder.find(tmem, "foo", 40, 1)!!);
}

fn void absolute_names_and_inheritance_loops_are_handled() @test
{
	String root = make_tree("loops");
	defer (void)io::path::rmtree((Path)root);
	String[] bases = { string::tformat("%s/base", root) };
	Finder* finder = open(mem, bases, "missing-theme");
	defer finder.release();
	String absolute = string::tformat("%s/base/legacy.xpm", root);
	test::eq(absolute, finder.find(tmem, absolute, 16, 1)!!);
	test::@error(finder.find(tmem, "/does/not/exist.png", 16, 1), NOT_FOUND);
	finder.clear();
	test::@error(finder.find(tmem, "foo", 48, 1), NOT_FOUND);
}

fn void default_base_directories_follow_the_specification() @test
{
	Variables vars = {
		.names = { "HOME", "XDG_DATA_DIRS" },
		.values = { "/home/ann", "/x:/y" },
	};
	String[] bases = default_base_dirs(&vars, tmem);
	test::eq(4, bases.len);
	test::eq("/home/ann/.icons", bases[0]);
	test::eq("/x/icons", bases[1]);
	test::eq("/y/icons", bases[2]);
	test::eq("/usr/share/pixmaps", bases[3]);
}
