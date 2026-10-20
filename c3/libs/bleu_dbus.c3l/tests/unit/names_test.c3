// Unit tests for bleu::dbus::names. Cases come from the D-Bus specification
// ("Basic types", "Valid Object Paths", "Valid Names").
module bleu::dbus::names_test;
import bleu::dbus::names;

fn void accepts_strict_utf8() @test
{
	assert(names::is_utf8_text(""));
	assert(names::is_utf8_text("abc"));
	assert(names::is_utf8_text("\xc3\xa9")); // U+00E9
	assert(names::is_utf8_text("\xe2\x82\xac")); // U+20AC
	assert(names::is_utf8_text("\xf0\x90\x8d\x88")); // U+10348
	assert(names::is_utf8_text("\xef\xb7\x90")); // U+FDD0, a noncharacter: allowed
}

fn void rejects_bad_utf8() @test
{
	assert(!names::is_utf8_text("a\0b")); // NUL is not text
	assert(!names::is_utf8_text("\xc0\x80")); // overlong NUL
	assert(!names::is_utf8_text("\xe0\x80\xaf")); // overlong '/'
	assert(!names::is_utf8_text("\xed\xa0\x80")); // surrogate U+D800
	assert(!names::is_utf8_text("\xf4\x90\x80\x80")); // above U+10FFFF
	assert(!names::is_utf8_text("\xe2\x82")); // truncated sequence
	assert(!names::is_utf8_text("\x80")); // continuation byte alone
	assert(!names::is_utf8_text("\xff")); // never a UTF-8 byte
}

fn void validates_object_paths() @test
{
	assert(names::is_object_path("/"));
	assert(names::is_object_path("/a"));
	assert(names::is_object_path("/org/freedesktop/DBus"));
	assert(names::is_object_path("/a_1/B2"));
	assert(!names::is_object_path(""));
	assert(!names::is_object_path("a"));
	assert(!names::is_object_path("/a/"));
	assert(!names::is_object_path("//"));
	assert(!names::is_object_path("/a//b"));
	assert(!names::is_object_path("/a-b"));
	assert(!names::is_object_path("/a.b"));
}

fn void validates_interfaces_and_errors() @test
{
	assert(names::is_interface("org.freedesktop.DBus"));
	assert(names::is_interface("org.freedesktop"));
	assert(names::is_interface("org._7_zip.Plugin"));
	assert(!names::is_interface("org"));
	assert(!names::is_interface("1a.b"));
	assert(!names::is_interface("a..b"));
	assert(!names::is_interface("a.b-c"));
	assert(!names::is_interface(".a.b"));
	assert(names::is_error_name("org.freedesktop.DBus.Error.Failed"));
	assert(!names::is_error_name("org.freedesktop.DBus.Error.Fail-ed"));
}

fn void validates_members() @test
{
	assert(names::is_member("Hello"));
	assert(names::is_member("_x9"));
	assert(!names::is_member(""));
	assert(!names::is_member("1x"));
	assert(!names::is_member("a.b"));
	assert(!names::is_member("a-b"));
}

fn void validates_bus_names() @test
{
	assert(names::is_bus_name("org.freedesktop.DBus"));
	assert(names::is_bus_name("org.example-app"));
	assert(names::is_bus_name(":1.42"));
	assert(names::is_unique_name(":1.42"));
	assert(!names::is_unique_name("org.example"));
	assert(!names::is_bus_name("org"));
	assert(!names::is_bus_name("org..x"));
	assert(!names::is_bus_name("1.foo"));
	assert(!names::is_bus_name(".org.x"));
}