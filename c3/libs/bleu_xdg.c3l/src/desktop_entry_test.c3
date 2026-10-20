// Unit tests for desktop entries: parsing, localisation, actions, visibility,
// and scanning a real directory tree for precedence and desktop file IDs.
module bleu::xdg::desktop_entry;
import bleu::error, bleu::xdg::dirs, bleu::xdg::keyfile, std::io, std::collections::list, std::core::test;

const String SAMPLE = `[Desktop Entry]
Type=Application
Name=Foo Viewer
Name[de]=Foo-Betrachter
GenericName=Image Viewer
Comment=View pictures
Icon=fooview
Exec=fooview %F
TryExec=fooview
Terminal=false
StartupNotify=true
Categories=Graphics;Viewer;
Keywords=image;picture;
MimeType=image/x-foo;image/png;
Actions=Gallery;Create;Ghost;
OnlyShowIn=GNOME;KDE;

[Desktop Action Gallery]
Name=Browse Gallery
Exec=fooview --gallery

[Desktop Action Create]
Name=Create a new Foo!
Icon=fooview-new
Exec=fooview --create-new

[Desktop Action Ghost]
Exec=fooview --nothing
`;

fn void sample_fields_and_localisation() @test
{
	DesktopEntry* entry = parse(mem, SAMPLE, "de_DE.UTF-8")!!;
	defer entry.release();
	test::eq(EntryType.APPLICATION, entry.type);
	test::eq("Foo-Betrachter", entry.name);
	test::eq("Image Viewer", entry.generic_name);
	test::eq("fooview %F", entry.exec);
	test::@check(entry.startup_notify && !entry.terminal && !entry.no_display, "boolean keys");
	test::eq(2, entry.categories.len);
	test::eq("Viewer", entry.categories[1]);
	test::eq(2, entry.keywords.len);
	test::eq(2, entry.mime_types.len);
	DesktopEntry* untranslated = parse(mem, SAMPLE, "")!!;
	defer untranslated.release();
	test::eq("Foo Viewer", untranslated.name);
}

fn void actions_need_a_group_and_a_name() @test
{
	DesktopEntry* entry = parse(mem, SAMPLE, "")!!;
	defer entry.release();
	// "Ghost" has no Name, so it is dropped; the order of Actions is kept.
	test::eq(2, entry.actions.len);
	test::eq("Gallery", entry.actions[0].id);
	test::eq("Browse Gallery", entry.actions[0].name);
	test::eq("fooview-new", entry.actions[1].icon);
}

fn void show_in_follows_only_and_not_lists() @test
{
	DesktopEntry* entry = parse(mem, SAMPLE, "")!!;
	defer entry.release();
	test::@check(entry.show_in({ "GNOME" }), "GNOME is listed");
	test::@check(!entry.show_in({ "XFCE" }), "an OnlyShowIn list hides everything else");
	test::@check(entry.show_in({ "XFCE", "KDE" }), "the first matching name decides");
	test::@check(!entry.show_in({ }), "no desktop names: default is hidden with OnlyShowIn");

	DesktopEntry* open = parse(mem, "[Desktop Entry]\nType=Application\nName=A\nExec=a\nNotShowIn=KDE;\n", "")!!;
	defer open.release();
	test::@check(open.show_in({ "GNOME" }), "no match takes the default: shown");
	test::@check(!open.show_in({ "KDE" }), "NotShowIn hides");
}

fn void current_desktop_names_are_split() @test
{
	Variables vars = { .names = { "XDG_CURRENT_DESKTOP" }, .values = { "GNOME:Unity:" } };
	String[] names = current_desktops(&vars, tmem);
	test::eq(2, names.len);
	test::eq("Unity", names[1]);
}

fn void structural_errors_are_reported() @test
{
	test::@error(parse(mem, "[Desktop Entry]\nType=Application\nExec=a\n", ""), error::PROTOCOL);
	test::@error(parse(mem, "[Desktop Entry]\nType=Widget\nName=A\nExec=a\n", ""), error::PROTOCOL);
	test::@error(parse(mem, "[Desktop Entry]\nName=A\nExec=a\n", ""), error::PROTOCOL);
	test::@error(parse(mem, "[Desktop Entry]\nType=Application\nName=A\n", ""), error::PROTOCOL);
	test::@error(parse(mem, "[Other]\nName=A\n", ""), error::PROTOCOL);
	test::@error(parse(mem, "[Desktop Entry]\nType=Application\nName=A\nHidden=yes\nExec=a\n", ""), error::PROTOCOL);
}

fn void dbus_activation_replaces_exec_and_links_need_none() @test
{
	DesktopEntry* dbus = parse(mem, "[Desktop Entry]\nType=Application\nName=A\nDBusActivatable=true\n", "")!!;
	defer dbus.release();
	test::@check(dbus.dbus_activatable && dbus.exec.len == 0, "D-Bus application without Exec");
	DesktopEntry* link = parse(mem, "[Desktop Entry]\nType=Link\nName=Docs\nURL=https://example.org/\n", "")!!;
	defer link.release();
	test::eq(EntryType.LINK, link.type);
}

// Records every visited file, in order.
struct Visits
{
	List{String} ids;
	List{String} paths;
}

fn void? record(void* context, DesktopFile file)
{
	Visits* visits = (Visits*)context;
	visits.ids.push(file.id.copy(tmem));
	visits.paths.push(file.path.copy(tmem));
}

// A fresh tree under the temporary directory, named `name`. The caller removes it.
fn String make_tree(String name) @local
{
	String root = string::tformat("%s/bleu-xdg-%s", io::path::temp_directory(tmem)!!, name);
	if (catch io::path::rmtree((Path)root))
	{
	}
	io::path::mkdir((Path)string::tformat("%s/one/applications/foo", root), true)!!;
	io::path::mkdir((Path)string::tformat("%s/two/applications", root), true)!!;
	io::path::mkdir((Path)string::tformat("%s/three", root), true)!!;
	io::file::save(string::tformat("%s/one/applications/foo/bar.desktop", root), (char[])"x")!!;
	io::file::save(string::tformat("%s/one/applications/baz.desktop", root), (char[])"x")!!;
	io::file::save(string::tformat("%s/one/applications/notes.txt", root), (char[])"x")!!;
	io::file::save(string::tformat("%s/two/applications/foo-bar.desktop", root), (char[])"x")!!;
	io::file::save(string::tformat("%s/two/applications/baz.desktop", root), (char[])"x")!!;
	io::file::save(string::tformat("%s/two/applications/qux.desktop", root), (char[])"x")!!;
	return root;
}

fn void scan_applies_precedence_and_ids() @test
{
	String root = make_tree("scan");
	defer (void)io::path::rmtree((Path)root);
	String[] dirs = {
		string::tformat("%s/one", root),
		string::tformat("%s/two", root),
		string::tformat("%s/three", root)
	};
	Visits visits;
	visits.ids.tinit();
	visits.paths.tinit();
	scan(dirs, &visits, &record)!!;
	test::eq(3, visits.ids.len());
	for (sz i = 0; i < visits.ids.len(); i++)
	{
		String id   = visits.ids[i];
		String path = visits.paths[i];
		if (id == "foo-bar.desktop") test::@check(
			path.contains("/one/applications/foo/bar.desktop"),
			"first directory wins"
		);
		if (id == "baz.desktop") test::@check(path.contains("/one/applications/baz.desktop"), "precedence for baz");
		if (id == "qux.desktop") test::@check(path.contains("/two/applications/qux.desktop"), "unique IDs are kept");
		test::@check(id != "notes.txt", "non-desktop files are ignored");
	}
}

fn void scan_stops_when_the_visitor_fails() @test
{
	String root = make_tree("refuse");
	defer (void)io::path::rmtree((Path)root);
	String[] dirs = { string::tformat("%s/one", root) };
	test::@error(scan(dirs, null, &refuse), error::CANCELLED);
}

fn void? refuse(void* context, DesktopFile file)
{
	return error::CANCELLED~;
}
// The example desktop file of the specification's "Example Desktop Entry File" section, verbatim.
fn void specification_example_parses_and_expands() @test
{
	String text         = $embed("../fixtures/foo-viewer.desktop");
	DesktopEntry* entry = parse(mem, text, "")!!;
	defer entry.release();
	test::eq("Foo Viewer", entry.name);
	test::eq("fooview %F", entry.exec);
	test::eq(2, entry.actions.len);
	test::eq("Create a new Foo!", entry.actions[1].name);
	test::eq("fooview-new", entry.actions[1].icon);
	test::eq("fooview --gallery", entry.actions[0].exec);
	test::eq(1, entry.mime_types.len);
	test::eq("image/x-foo", entry.mime_types[0]);
}

// `Type=Link` names its target in `URL`, which the specification requires for links.
fn void link_entries_need_a_url() @test
{
	test::@error(parse(mem, "[Desktop Entry]\nType=Link\nName=Docs\n", ""), error::PROTOCOL);
	DesktopEntry* link = parse(mem, "[Desktop Entry]\nType=Link\nName=Docs\nURL=https://example.org/\n", "")!!;
	defer link.release();
	test::eq("https://example.org/", link.url);
}

// A desktop file over the reader's cap is refused by its size, before it is read.
fn void oversized_desktop_files_are_refused() @test
{
	String path = string::tformat("%s/bleu-xdg-oversized.desktop", io::path::temp_directory(tmem)!!);
	char[] big  = alloc::new_array(tmem, char, (sz)keyfile::MAX_FILE_BYTES + 1);
	io::file::save(path, big)!!;
	defer (void)io::file::delete(path);
	test::@error(load(mem, path, ""), error::OUT_OF_RANGE);
}