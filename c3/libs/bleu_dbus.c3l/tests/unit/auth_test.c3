// Unit tests for bleu::dbus::auth: command formatting and reply parsing, using
// the specification's own example ("AUTH EXTERNAL 31303030" for uid 1000).
module bleu::dbus::auth_test;
import bleu::dbus::auth, bleu::dbus::testing, bleu::error;

fn void formats_external_with_hex_uid() @test
{
	@pool()
	{
		DString line;
		line.init(tmem);
		auth::format_external(&line, 1000);
		assert(line.str_view() == "AUTH EXTERNAL 31303030\r\n");
		DString root;
		root.init(tmem);
		auth::format_external(&root, 0);
		assert(root.str_view() == "AUTH EXTERNAL 30\r\n");
		DString high;
		high.init(tmem);
		auth::format_external(&high, 65534);
		assert(high.str_view() == "AUTH EXTERNAL 3635353334\r\n");
	};
}

fn void formats_the_other_commands() @test
{
	@pool()
	{
		DString out;
		out.init(tmem);
		auth::format_negotiate_unix_fd(&out);
		auth::format_begin(&out);
		assert(out.str_view() == "NEGOTIATE_UNIX_FD\r\nBEGIN\r\n");
	};
}

fn void finds_complete_lines_only() @test
{
	assert((auth::find_line_end("OK abc\r\nrest") ?? 99) == 6);
	testing::@expect_fault(auth::find_line_end("OK abc\nrest"), NOT_FOUND);
	testing::@expect_fault(auth::find_line_end("partial"), NOT_FOUND);
}

fn void parses_replies() @test
{
	assert(auth::parse_reply("OK 0123abcd")!!.kind == OK);
	assert(auth::parse_reply("OK 0123abcd")!!.argument == "0123abcd");
	assert(auth::parse_reply("REJECTED EXTERNAL ANONYMOUS")!!.kind == REJECTED);
	assert(auth::parse_reply("REJECTED EXTERNAL ANONYMOUS")!!.argument == "EXTERNAL ANONYMOUS");
	assert(auth::parse_reply("AGREE_UNIX_FD")!!.kind == AGREE_UNIX_FD);
	assert(auth::parse_reply("AGREE_UNIX_FD")!!.argument.len == 0);
	assert(auth::parse_reply("ERROR not understood")!!.kind == ERROR);
	assert(auth::parse_reply("FUTURE thing")!!.kind == OTHER);
}

fn void refuses_empty_and_non_ascii_replies() @test
{
	testing::@expect_fault(auth::parse_reply(""), error::PROTOCOL);
	testing::@expect_fault(auth::parse_reply("OK \xc3\xa9"), error::PROTOCOL);
}