module bleu::clipboard;
import std::core::test, std::core::mem;

fn String preview_of(String text)
{
	return make_preview(tmem, (char[])text);
}

fn void plain_text_is_kept_and_collapsed() @test
{
	@pool()
	{
		test::eq(preview_of("hello   world\n"), "hello world");
		test::eq(preview_of("  \t x \r\n "), "x");
		test::eq(preview_of(""), "");
	};
}

fn void invalid_bytes_become_replacement_characters() @test
{
	@pool()
	{
		test::eq(preview_of("a\xFFb"), "a\xEF\xBF\xBDb");
		// Overlong form of NUL and a UTF-16 surrogate are not characters: each byte is replaced.
		test::eq(preview_of("\xC0\x80"), "\xEF\xBF\xBD\xEF\xBF\xBD");
		test::eq(preview_of("\xED\xA0\x80"), "\xEF\xBF\xBD\xEF\xBF\xBD\xEF\xBF\xBD");
	};
}

fn void bidirectional_overrides_become_spaces() @test
{
	@pool()
	{
		test::eq(preview_of("a\xE2\x80\xAEb"), "a b");
	};
}

fn void valid_multibyte_text_is_kept() @test
{
	@pool()
	{
		test::eq(preview_of("caf\xC3\xA9"), "caf\xC3\xA9");
	};
}

fn void preview_stops_before_a_character_that_would_overflow() @test
{
	@pool()
	{
		char[] text = alloc::alloc_array(tmem, char, PREVIEW_LIMIT - 1);
		for (usz i = 0; i < text.len; i++) text[i] = 'a';
		// 511 ASCII bytes then a two-byte character: the character would end at 513 bytes.
		char[] tail = { 0xC3, 0xA9 };
		char[] joined = alloc::alloc_array(tmem, char, text.len + 2);
		mem::copy(&joined[0], &text[0], (sz)text.len);
		mem::copy(&joined[text.len], &tail[0], 2);
		String preview = preview_of((String)joined);
		test::eq(preview.len, (sz)(PREVIEW_LIMIT - 1));
	};
}
