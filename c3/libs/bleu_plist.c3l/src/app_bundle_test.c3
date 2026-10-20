// Tests for app bundles on a real directory tree: the typed Info.plist model,
// InfoPlist.strings localisation in both encodings, and the application directories.
module bleu::plist::app_bundle;
import bleu::error, std::io, std::core::test;

// A bundle named `name` under `root`, with the fixture Info.plist and two localizations.
fn String make_bundle(String root, String name) @local
{
	String bundle = string::tformat("%s/%s", root, name);
	io::path::mkdir((Path)string::tformat("%s/Contents/Resources/de.lproj", bundle), true)!!;
	io::path::mkdir((Path)string::tformat("%s/Contents/Resources/en.lproj", bundle), true)!!;
	io::file::save(string::tformat("%s/Contents/Info.plist", bundle), (char[])$embed("../fixtures/info.plist"))!!;
	io::file::save(string::tformat("%s/Contents/Resources/de.lproj/InfoPlist.strings", bundle), (char[])$embed("../fixtures/InfoPlist-de.strings"))!!;
	io::file::save(string::tformat("%s/Contents/Resources/en.lproj/InfoPlist.strings", bundle), (char[])$embed("../fixtures/InfoPlist-en.strings"))!!;
	return bundle;
}

fn String make_root(String name) @local
{
	String root = string::tformat("%s/bleu-plist-%s", io::path::temp_directory(tmem)!!, name);
	if (catch io::path::rmtree((Path)root)) {}
	io::path::mkdir((Path)root, true)!!;
	return root;
}

fn void reads_the_typed_model() @test
{
	String root = make_root("typed");
	defer (void)io::path::rmtree((Path)root);
	String bundle = make_bundle(root, "Example.app");
	AppBundle app = read(tmem, bundle, {})!!;
	test::eq("com.example.Example", app.bundle_id);
	test::eq("Example", app.executable);
	test::eq("Example.icns", app.icon_file);
	test::eq("", app.icon_name);
	test::eq("2.3", app.short_version);
	test::eq("public.app-category.developer-tools", app.category);
	test::@check(app.background_only && !app.ui_element, "LSBackgroundOnly and LSUIElement");
	test::eq(1, app.url_types.len);
	test::eq("Example URL", app.url_types[0].name);
	test::eq(2, app.url_types[0].schemes.len);
	test::eq("exm", app.url_types[0].schemes[1]);
}

fn void localized_names_follow_the_language_order() @test
{
	String root = make_root("locale");
	defer (void)io::path::rmtree((Path)root);
	String bundle = make_bundle(root, "Example.app");

	AppBundle german = read(tmem, bundle, { "de_DE" })!!;
	test::eq("Beispiel", german.name);
	test::eq("Beispiel-App", german.display_name);

	// English has no CFBundleName in its strings file, so the Info.plist value stands.
	AppBundle english = read(tmem, bundle, { "en_US" })!!;
	test::eq("Example", english.name);
	test::eq("Example for English", english.display_name);

	AppBundle unknown = read(tmem, bundle, { "fr_FR" })!!;
	test::eq("Example", unknown.name);
	test::eq("Example App", unknown.display_name);
}

fn void missing_and_malformed_bundles() @test
{
	String root = make_root("missing");
	defer (void)io::path::rmtree((Path)root);
	test::@error(read(tmem, string::tformat("%s/Absent.app", root), {}), NOT_FOUND);
	String broken = string::tformat("%s/Broken.app", root);
	io::path::mkdir((Path)string::tformat("%s/Contents", broken), true)!!;
	io::file::save(string::tformat("%s/Contents/Info.plist", broken), (char[])"not a plist")!!;
	test::@error(read(tmem, broken, {}), error::PROTOCOL);
	String array_root = string::tformat("%s/Array.app", root);
	io::path::mkdir((Path)string::tformat("%s/Contents", array_root), true)!!;
	io::file::save(string::tformat("%s/Contents/Info.plist", array_root), (char[])"<plist><array/></plist>")!!;
	test::@error(read(tmem, array_root, {}), error::PROTOCOL);
}

fn void application_directories_are_listed_in_search_order() @test
{
	String[] with_home = applications_directories("/home/ann", tmem);
	test::eq(4, with_home.len);
	test::eq("/Applications", with_home[0]);
	test::eq("/home/ann/Applications", with_home[2]);
	test::eq("/System/Applications/Utilities", with_home[3]);
	test::eq(3, applications_directories("", tmem).len);
}

fn void bundles_are_found_in_the_home_applications_folder() @test
{
	String root = make_root("scan");
	defer (void)io::path::rmtree((Path)root);
	io::path::mkdir((Path)string::tformat("%s/Applications/Two.app", root), true)!!;
	io::path::mkdir((Path)string::tformat("%s/Applications/Notes", root), true)!!;
	String[] found = bundle_paths(root, tmem);
	test::@check(contains(found, string::tformat("%s/Applications/Two.app", root)), "the bundle is found");
	test::@check(!contains(found, string::tformat("%s/Applications/Notes", root)), "other folders are not bundles");
}

fn bool contains(String[] list, String value) @local
{
	foreach (item : list)
	{
		if (item == value) return true;
	}
	return false;
}
