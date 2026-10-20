// Unit tests for the key-file parser: syntax, escapes, lists, locale matching
// and malformed input. Parsed files are heap-allocated and freed explicitly so
// the test runner's leak tracking covers them.
module bleu::xdg::keyfile;
import bleu::error, std::core::test;

fn void syntax_comments_blanks_and_spacing() @test
{
	KeyFile file = parse(mem, `# leading comment

[Desktop Entry]
  Name = Spaced Name  
# comment between entries
Type=Application
`)!!;
	defer file.free();
	test::@check(file.has_group("Desktop Entry"), "group found");
	test::eq("Spaced Name", file.get_string(tmem, "Desktop Entry", "Name")!!);
	test::eq("Application", file.get_string(tmem, "Desktop Entry", "Type")!!);
}

fn void utf8_bom_and_crlf_are_accepted() @test
{
	KeyFile file = parse(mem, "\xEF\xBB\xBF[Desktop Entry]\r\nName=Crlf\r\n")!!;
	defer file.free();
	test::eq("Crlf", file.get_string(tmem, "Desktop Entry", "Name")!!);
}

fn void empty_file_has_no_groups() @test
{
	KeyFile file = parse(mem, "")!!;
	defer file.free();
	test::@check(!file.has_group("Desktop Entry"), "no groups in an empty file");
}

fn void string_escapes_are_decoded() @test
{
	KeyFile file = parse(mem, `[G]
Plain=a\sb\tc\nd\re\\f\;g
`)!!;
	defer file.free();
	test::eq("a b\tc\nd\re\\f;g", file.get_string(tmem, "G", "Plain")!!);
}

fn void invalid_escapes_are_rejected_with_their_line() @test
{
	test::@error(parse(mem, "[G]\nA=x\\q\n"), error::PROTOCOL);
	test::eq(2, error::last().code);
	test::@error(parse(mem, "[G]\nA=dangling\\"), error::PROTOCOL);
}

fn void lists_split_on_unescaped_semicolons() @test
{
	KeyFile file = parse(mem, `[G]
Plain=a;b;c;
Trailing=a;;
Escaped=x\;y;z
Empty=
Lone=;
`)!!;
	defer file.free();
	String[] plain = file.get_strings(tmem, "G", "Plain")!!;
	test::eq(3, plain.len);
	test::eq("c", plain[2]);
	String[] trailing = file.get_strings(tmem, "G", "Trailing")!!;
	test::eq(2, trailing.len);
	test::eq("", trailing[1]);
	String[] escaped = file.get_strings(tmem, "G", "Escaped")!!;
	test::eq(2, escaped.len);
	test::eq("x;y", escaped[0]);
	test::eq(0, file.get_strings(tmem, "G", "Empty")!!.len);
	test::eq(1, file.get_strings(tmem, "G", "Lone")!!.len);
}

fn void booleans_and_numbers() @test
{
	KeyFile file = parse(mem, `[G]
Yes=true
No=false
Bad=True
Half=0.5
Word=half
`)!!;
	defer file.free();
	test::@check(file.get_boolean("G", "Yes")!!, "true");
	test::@check(!file.get_boolean("G", "No")!!, "false");
	test::@error(file.get_boolean("G", "Bad"), error::PROTOCOL);
	test::eq(0.5, file.get_numeric("G", "Half")!!);
	test::@error(file.get_numeric("G", "Word"), error::PROTOCOL);
	test::@error(file.get_string(tmem, "G", "Missing"), NOT_FOUND);
}

fn void localized_values_follow_the_specification_order() @test
{
	KeyFile file = parse(mem, `[Desktop Entry]
Name=Base
Name[de]=German
Name[de_DE]=German (Germany)
Name[de_DE@euro]=German (Euro)
Name[sr@latin]=Serbian Latin
`)!!;
	defer file.free();
	const String GROUP = "Desktop Entry";
	// lang_COUNTRY@MODIFIER is tried first, then lang_COUNTRY, lang@MODIFIER, lang.
	test::eq("German (Euro)", file.get_localized_string(tmem, GROUP, "Name", "de_DE.UTF-8@euro")!!);
	test::eq("German (Germany)", file.get_localized_string(tmem, GROUP, "Name", "de_DE.UTF-8")!!);
	test::eq("German", file.get_localized_string(tmem, GROUP, "Name", "de_AT.UTF-8")!!);
	test::eq("Serbian Latin", file.get_localized_string(tmem, GROUP, "Name", "sr_RS@latin")!!);
	test::eq("Base", file.get_localized_string(tmem, GROUP, "Name", "fr_FR.UTF-8")!!);
	test::eq("Base", file.get_localized_string(tmem, GROUP, "Name", "")!!);
}

fn void modifier_is_not_matched_when_the_locale_has_none() @test
{
	KeyFile file = parse(mem, `[G]
Name=Base
Name[sr@latin]=Serbian Latin
`)!!;
	defer file.free();
	// "sr" has no modifier, so the sr@latin key must not be chosen.
	test::eq("Base", file.get_localized_string(tmem, "G", "Name", "sr_RS.UTF-8")!!);
	test::eq("Serbian Latin", file.get_localized_string(tmem, "G", "Name", "sr@latin")!!);
}

fn void duplicates_and_structure_are_rejected() @test
{
	test::@error(parse(mem, "[G]\nA=1\n[G]\nB=2\n"), error::PROTOCOL);
	test::eq(3, error::last().code);
	test::@error(parse(mem, "[G]\nA=1\nA=2\n"), error::PROTOCOL);
	test::eq(3, error::last().code);
	test::@error(parse(mem, "[G]\nA[de]=1\nA[de]=2\n"), error::PROTOCOL);
	test::@error(parse(mem, "A=1\n[G]\n"), error::PROTOCOL);
	test::eq(1, error::last().code);
	test::@error(parse(mem, "[G\nA=1\n"), error::PROTOCOL);
	test::@error(parse(mem, "[]\n"), error::PROTOCOL);
	test::@error(parse(mem, "[G]\nNoEquals\n"), error::PROTOCOL);
	test::@error(parse(mem, "[G]\n=value\n"), error::PROTOCOL);
	test::@error(parse(mem, "[G]\nBad_Key=1\n"), error::PROTOCOL);
	test::@error(parse(mem, "[G]\nA[de=1\n"), error::PROTOCOL);
	test::@error(parse(mem, "[G]\nA[]=1\n"), error::PROTOCOL);
	test::@error(parse(mem, "[Gé]\n"), error::PROTOCOL);
}
