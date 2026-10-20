module bleu::appearance::convert_test;
import std::collections::maybe, bleu::appearance, bleu::appearance::convert, bleu::unit;

fn void portal_values_map_to_enums() @test
{
	assert(convert::scheme_from_portal(0) == NO_PREFERENCE);
	assert(convert::scheme_from_portal(1) == DARK);
	assert(convert::scheme_from_portal(2) == LIGHT);
	assert(convert::scheme_from_portal(77) == NO_PREFERENCE, "unknown values are no preference");
	assert(convert::contrast_from_portal(1) == HIGH);
	assert(convert::contrast_from_portal(0) == NORMAL);
	assert(convert::reduced_from_portal(1));
	assert(!convert::reduced_from_portal(0));
}

fn void gnome_spellings_map_to_enums() @test
{
	assert(convert::scheme_from_gnome("prefer-dark") == DARK);
	assert(convert::scheme_from_gnome("prefer-light") == LIGHT);
	assert(convert::scheme_from_gnome("default") == NO_PREFERENCE);
	assert(convert::scheme_to_gnome(DARK) == "prefer-dark");
	assert(convert::scheme_to_gnome(NO_PREFERENCE) == "default");
	assert(convert::clock_from_gnome("12h") == H12);
	assert(convert::clock_from_gnome("24h") == H24);
	assert(convert::clock_from_gnome("default") == UNKNOWN);
}

fn void windows_dword_maps_to_scheme() @test
{
	assert(convert::scheme_from_apps_use_light_theme(0) == DARK);
	assert(convert::scheme_from_apps_use_light_theme(1) == LIGHT);
	assert(convert::apps_use_light_theme(DARK) == 0);
	assert(convert::apps_use_light_theme(LIGHT) == 1);
}

fn void accent_channels_must_be_unit_numbers() @test
{
	Maybe{Rgb} accent = convert::accent_from_channels(0.0, 0.5, 1.0);
	assert(accent.has_value);
	assert((float)accent.value.green == 0.5f);
	assert(!convert::accent_from_channels(1.5, 0.0, 0.0).has_value, "above 1 is unset");
	assert(!convert::accent_from_channels(-0.1, 0.0, 0.0).has_value, "below 0 is unset");
	assert(!convert::accent_from_channels(0.0, 0.0, bitcast((ulong)0x7FF8000000000000, double)).has_value, "NaN is unset");
}

fn void abgr_accent_is_read_red_first() @test
{
	// 0xFF0080FF: alpha FF, blue 00, green 80, red FF (AABBGGRR).
	Maybe{Rgb} accent = convert::accent_from_abgr(0xFF0080FF);
	assert(accent.has_value);
	assert((float)accent.value.red == 1.0f);
	assert(accent.value.green > 0.50f && accent.value.green < 0.51f);
	assert((float)accent.value.blue == 0.0f);
}

fn void gvariant_strings_round_trip() @test
{
	assert(convert::unquote(mem, "'prefer-dark'\n")! == "prefer-dark");
	String quoted = convert::quote(mem, "it's a \\ test");
	defer alloc::free(mem, quoted.ptr);
	assert(quoted == "'it\\'s a \\\\ test'");
	String back = convert::unquote(mem, quoted)!;
	defer alloc::free(mem, back.ptr);
	assert(back == "it's a \\ test");
	assert(@catch(convert::unquote(mem, "prefer-dark")) == error::PROTOCOL, "unquoted text is refused");
}

fn void gnome_numbers_and_booleans_parse() @test
{
	assert((float)convert::scale_from_gnome("1.25").value == 1.25f);
	assert(!convert::scale_from_gnome("big").has_value);
	assert(convert::bool_from_gnome("true")! == true);
	assert(@catch(convert::bool_from_gnome("maybe")) == error::INVALID_ARGUMENT);
}

fn void file_uri_escapes_and_decodes() @test
{
	String uri = convert::file_uri(mem, "/home/a b/pic%1.png");
	defer alloc::free(mem, uri.ptr);
	assert(uri == "file:///home/a%20b/pic%251.png", "space and percent are escaped, slashes kept");
	String path = convert::path_from_file_uri(mem, uri)!;
	defer alloc::free(mem, path.ptr);
	assert(path == "/home/a b/pic%1.png");
	assert(@catch(convert::path_from_file_uri(mem, "https://x/y")) == error::INVALID_ARGUMENT);
}

fn void template_arguments_get_the_path() @test
{
	String[3] template = { "swww", "img", "{path}" };
	String[] argv = convert::substitute(mem, template[..], "/x/y.png");
	defer {
		foreach (arg : argv) alloc::free(mem, arg.ptr);
		alloc::free(mem, argv.ptr);
	}
	assert(argv.len == 3 && argv[0] == "swww" && argv[2] == "/x/y.png");
	String[1] inline_path = { "--file={path}" };
	String[] joined = convert::substitute(mem, inline_path[..], "/a");
	defer {
		alloc::free(mem, joined[0].ptr);
		alloc::free(mem, joined.ptr);
	}
	assert(joined[0] == "--file=/a");
}
