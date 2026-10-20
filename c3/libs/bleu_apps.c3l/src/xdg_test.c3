module bleu::apps::xdg_test @feat(LINUX);
import std::io, std::io::path, std::thread, std::time, std::time::clock, bleu::apps, bleu::error, bleu::operation, bleu::rt::fs, bleu::stream;

// A fresh fake XDG tree: system entries under usr/share, user entries under home/.local/share.
fn String make_tree(String stem) @local
{
	String root = string::tformat("/tmp/bleu-apps-%s-%d", stem, clock::now());
	path::mkdir((Path)string::tformat("%s/usr/share/applications", root), true)!!;
	path::mkdir((Path)string::tformat("%s/home/.local/share/applications", root), true)!!;
	return root;
}

fn void write_entry(String root, String dir, String file, String text) @local
{
	fs::write_text(string::tformat("%s/%s/applications/%s", root, dir, file), text)!!;
}

fn void catalogue_lists_listed_entries_only() @test
{
	String root = make_tree("catalogue");
	write_entry(
		root,
		"usr/share",
		"one.desktop",
		"[Desktop Entry]\nType=Application\nName=App One\nGenericName=Editor\nKeywords=write;text;\nExec=/bin/true %F\nActions=Second;\n\n[Desktop Action Second]\nName=Second window\nExec=/bin/true --new\n"
	);
	write_entry(
		root,
		"usr/share",
		"hidden.desktop",
		"[Desktop Entry]\nType=Application\nName=Hidden App\nHidden=true\nExec=/bin/true\n"
	);
	write_entry(
		root,
		"usr/share",
		"helper.desktop",
		"[Desktop Entry]\nType=Application\nName=Hidden Helper\nNoDisplay=true\nExec=/bin/true\n"
	);
	write_entry(
		root,
		"usr/share",
		"link.desktop",
		"[Desktop Entry]\nType=Link\nName=A link\nURL=https://example.org\n"
	);
	write_entry(root, "usr/share", "broken.desktop", "this is not a desktop entry\n");
	write_entry(
		root,
		"usr/share",
		"shadow.desktop",
		"[Desktop Entry]\nType=Application\nName=System Shadow\nExec=/bin/true\n"
	);
	write_entry(
		root,
		"home/.local/share",
		"shadow.desktop",
		"[Desktop Entry]\nType=Application\nName=User Shadow\nHidden=true\nExec=/bin/true\n"
	);
	Apps* apps = apps::open(mem, { .backend = XDG_DESKTOP, .root = root, .settle = time::ms(50) })!!;
	defer apps.close();
	assert(apps.backend_name() == "xdg-desktop");
	CatalogueSnapshot* snapshot = apps.wait_after(0, time::ms(3000))!!;
	defer snapshot.release();
	State* state = &snapshot.value;
	assert(state.apps.len == 2, "App One and Hidden Helper; hidden, link, broken and shadowed entries are left out");
	App* one = &state.apps[0];
	assert(one.name == "App One" && one.id == "one.desktop" && one.launch == EXEC);
	assert(one.keywords.len == 2 && one.keywords[0] == "write");
	assert(one.actions.len == 1 && one.actions[0].id == "Second" && one.actions[0].name == "Second window");
	assert(!one.no_display);
	App* helper = &state.apps[1];
	assert(helper.no_display, "NoDisplay entries are listed but flagged");
}

fn void launches_an_exec_line_with_uris() @test
{
	String root   = make_tree("launch");
	String marker = string::tformat("%s/ran.txt", root);
	write_entry(
		root,
		"usr/share",
		"writer.desktop",
		string::tformat(
			"[Desktop Entry]\nType=Application\nName=Writer\nExec=/bin/sh -c \"echo ran > %s\" sh %%U\n",
			marker
		)
	);
	Apps* apps = apps::open(mem, { .backend = XDG_DESKTOP, .root = root, .settle = time::ms(50) })!!;
	defer apps.close();
	apps.wait_after(0, time::ms(3000))!!.release();
	String[] uris = { "file:///tmp/example.txt" };
	LaunchOperation* op = apps.launch(
		"writer.desktop",
		{ .uris = uris, .startup_id = "bleu_test_1", .activation_token = "tok" }
	)!!;
	defer op.release();
	Launched started = op.wait(time::ms(5000))!!;
	assert(started.route == SPAWN && started.pid > 0);
	// The child runs asynchronously: wait up to two seconds for its marker file.
	bool ran = false;
	for (int i = 0; i < 200 && !ran; i++)
	{
		ran = io::file::exists(marker);
		if (!ran) thread::sleep_ms(10)!!;
	}
	assert(ran, "the Exec line ran the shell, which wrote the marker");
	String text = fs::read_file(mem, marker)!!;
	defer alloc::free(mem, text.ptr);
	assert(text == "ran\n", "the shell wrote its text and the URI reached Exec as $1 (unused here)");
}

fn void unknown_app_fails_with_not_found() @test
{
	String root = make_tree("unknown");
	Apps* apps  = apps::open(mem, { .backend = XDG_DESKTOP, .root = root, .settle = time::ms(50) })!!;
	defer apps.close();
	apps.wait_after(0, time::ms(3000))!!.release();
	LaunchOperation* op = apps.launch("missing.desktop")!!;
	defer op.release();
	assert(@catch(op.wait(time::ms(5000))) == NOT_FOUND);
}

fn void new_desktop_files_are_noticed() @test
{
	String root = make_tree("watch");
	Apps* apps  = apps::open(mem, { .backend = XDG_DESKTOP, .root = root, .settle = time::ms(50) })!!;
	defer apps.close();
	assert(apps.capability(WATCH).ok(), "inotify is available on Linux");
	Reader{Event}* events = apps.subscribe()!!;
	defer events.release();
	CatalogueSnapshot* first = apps.wait_after(0, time::ms(3000))!!;
	ulong generation         = first.generation;
	first.release();
	write_entry(
		root,
		"usr/share",
		"late.desktop",
		"[Desktop Entry]\nType=Application\nName=Late Arrival\nExec=/bin/true\n"
	);
	CatalogueSnapshot* second = apps.wait_after(generation, time::ms(3000))!!;
	defer second.release();
	assert(second.value.apps.len == 1 && second.value.apps[0].name == "Late Arrival");
	Packet{Event}* packet = events.next(time::ms(1000))!!;
	defer packet.release();
	assert(packet.value.kind == APP_ADDED && packet.value.app_id == "late.desktop");
}

fn void icons_absolute_paths_and_missing_names() @test
{
	String root = make_tree("icons");
	path::mkdir((Path)string::tformat("%s/usr/share/pixmaps", root), true)!!;
	String picture = string::tformat("%s/usr/share/pixmaps/picture.png", root);
	fs::write_text(picture, "not really a png")!!;
	Apps* apps = apps::open(mem, { .backend = XDG_DESKTOP, .root = root, .settle = time::ms(50) })!!;
	defer apps.close();
	String found = apps.icon_file(picture, 48, 1, mem)!!;
	defer alloc::free(mem, found.ptr);
	assert(found == picture, "an absolute path that exists is its own file");
	assert(@catch(apps.icon_file("/nonexistent/icon.png", 48, 1, mem)) == NOT_FOUND);
	assert(@catch(apps.icon_file("no-such-icon-name", 48, 1, mem)) == NOT_FOUND);
}