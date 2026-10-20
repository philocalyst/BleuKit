// Unit tests for Exec expansion: quoting examples from the specification, field
// codes, invocation counts and refusal of malformed command lines.
module bleu::xdg::exec;
import bleu::error, std::core::test;

fn Context empty_context() @inline => { .files = {}, .urls = {}, .icon = "", .name = "", .location = "" };

fn void quoting_groups_words_and_undoes_escapes() @test
{
	// Exec text: sh -c "echo \"hi\" \$HOME \\ \\\\ \`ls\`"
	String[][] runs = expand(tmem, "sh -c \"echo \\\"hi\\\" \\$HOME \\\\ \\\\\\\\ \\`ls\\`\"", empty_context())!!;
	test::eq(1, runs.len);
	test::eq(3, runs[0].len);
	test::eq("sh", runs[0][0]);
	test::eq("-c", runs[0][1]);
	test::eq("echo \"hi\" $HOME \\ \\\\ `ls`", runs[0][2]);
}

fn void a_quoted_backslash_is_one_backslash() @test
{
	// The spec: a literal backslash in a quoted argument needs four backslashes in
	// the file, which string unescaping reduces to two before quoting reduces them to one.
	String[][] runs = expand(tmem, `app "a\\b"`, empty_context())!!;
	test::eq("a\\b", runs[0][1]);
	String[][] dollar = expand(tmem, `app "\$x"`, empty_context())!!;
	test::eq("$x", dollar[0][1]);
}

fn void whitespace_separates_and_quotes_join() @test
{
	String[][] runs = expand(tmem, "app\t a \"b c\"d  \"\"", empty_context())!!;
	test::eq(4, runs[0].len);
	test::eq("b cd", runs[0][2]);
	test::eq("", runs[0][3]);
}

fn void percent_percent_is_a_literal_percent() @test
{
	String[][] runs = expand(tmem, "app 100%%", empty_context())!!;
	test::eq("100%", runs[0][1]);
	String[][] quoted = expand(tmem, `app "%%"`, empty_context())!!;
	test::eq("%", quoted[0][1]);
}

fn void single_file_code_runs_once_per_file() @test
{
	Context context = empty_context();
	context.files = { "/a b", "/c" };
	String[][] runs = expand(tmem, "app %f", context)!!;
	test::eq(2, runs.len);
	test::eq("/a b", runs[0][1]);
	test::eq("/c", runs[1][1]);
}

fn void single_file_code_without_files_is_removed() @test
{
	String[][] runs = expand(tmem, "app %f --x", empty_context())!!;
	test::eq(1, runs.len);
	test::eq(2, runs[0].len);
	test::eq("--x", runs[0][1]);
}

fn void plural_file_code_keeps_every_file_in_one_run() @test
{
	Context context = empty_context();
	context.files = { "/one", "/two words", "/three" };
	String[][] runs = expand(tmem, "app %F", context)!!;
	test::eq(1, runs.len);
	test::eq(4, runs[0].len);
	test::eq("/two words", runs[0][2]);
}

fn void urls_follow_the_same_rules() @test
{
	Context context = empty_context();
	context.urls = { "https://a/", "https://b/" };
	test::eq(2, expand(tmem, "app %u", context)!!.len);
	String[][] all = expand(tmem, "app %U", context)!!;
	test::eq(1, all.len);
	test::eq(3, all[0].len);
}

fn void file_code_can_sit_inside_an_argument() @test
{
	Context context = empty_context();
	context.files = { "/x" };
	String[][] runs = expand(tmem, "app --file=%f", context)!!;
	test::eq("--file=/x", runs[0][1]);
}

fn void field_values_are_not_expanded_again() @test
{
	Context context = empty_context();
	context.files = { "%f%%" };
	String[][] runs = expand(tmem, "app %f", context)!!;
	test::eq("%f%%", runs[0][1]);
}

fn void icon_expands_to_two_arguments_or_nothing() @test
{
	Context context = empty_context();
	String[][] none = expand(tmem, "app %i", context)!!;
	test::eq(1, none[0].len);
	context.icon = "fooview";
	String[][] some = expand(tmem, "app %i x", context)!!;
	test::eq(4, some[0].len);
	test::eq("--icon", some[0][1]);
	test::eq("fooview", some[0][2]);
}

fn void name_and_location_expand() @test
{
	Context context = empty_context();
	context.name = "Foo Viewer";
	context.location = "/usr/share/applications/foo.desktop";
	String[][] runs = expand(tmem, "app %c %k", context)!!;
	test::eq("Foo Viewer", runs[0][1]);
	test::eq("/usr/share/applications/foo.desktop", runs[0][2]);
}

fn void deprecated_codes_are_removed() @test
{
	String[][] runs = expand(tmem, "app %d %D %n %N %v %m end", empty_context())!!;
	test::eq(2, runs[0].len);
	test::eq("end", runs[0][1]);
}

fn void malformed_command_lines_are_refused() @test
{
	test::@error(expand(tmem, "app %z", empty_context()), error::PROTOCOL);
	test::@error(expand(tmem, "app %", empty_context()), error::PROTOCOL);
	test::@error(expand(tmem, "app %f %u", empty_context()), error::PROTOCOL);
	test::@error(expand(tmem, "app %F %U", empty_context()), error::PROTOCOL);
	test::@error(expand(tmem, "app --icon=%i", empty_context()), error::PROTOCOL);
	test::@error(expand(tmem, "app %F-x", empty_context()), error::PROTOCOL);
	test::@error(expand(tmem, `app "%f"`, empty_context()), error::PROTOCOL);
	test::@error(expand(tmem, `app "unclosed`, empty_context()), error::PROTOCOL);
	test::@error(expand(tmem, "   %d  ", empty_context()), error::PROTOCOL);
}

fn void a_plain_command_has_one_run() @test
{
	String[][] runs = expand(tmem, "/usr/bin/true", empty_context())!!;
	test::eq(1, runs.len);
	test::eq("/usr/bin/true", runs[0][0]);
}
