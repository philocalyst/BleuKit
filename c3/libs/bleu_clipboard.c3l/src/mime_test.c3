module bleu::clipboard;
import std::core::test, std::core::mem, std::collections::maybe;

fn void validity_rules() @test
{
	test::@check(!is_valid_mime(""));
	test::@check(is_valid_mime("text/plain;charset=utf-8"));
	test::@check(!is_valid_mime("text/\n plain"));
	test::@check(!is_valid_mime("text/\x7fplain"));
	char[256] long_name;
	for (usz i = 0; i < long_name.len; i++) long_name[i] = 'a';
	test::@check(!is_valid_mime((String)long_name[..]));
	test::@check(is_valid_mime((String)long_name[0:MAX_MIME_LENGTH]));
}

fn void text_type_follows_preference_and_keeps_owner_spelling() @test
{
	maybe::Maybe{String} chosen = choose_text_type({ "image/png", "text/plain", "UTF8_STRING" });
	test::@check(chosen.has_value);
	test::eq(chosen.value, "UTF8_STRING");
	maybe::Maybe{String} legacy = choose_text_type({ "TEXT" });
	test::eq(legacy.value, "TEXT");
	maybe::Maybe{String} none = choose_text_type({ "image/png", "text/html" });
	test::@check(!none.has_value);
}

fn void sanitise_drops_invalid_and_repeated_types() @test
{
	@pool()
	{
		String[] kept = sanitise_offer(tmem, { "text/plain", "", "text/plain", "bad\x01name", "image/png" });
		test::eq(kept.len, (sz)2);
		test::eq(kept[0], "text/plain");
		test::eq(kept[1], "image/png");
	};
}

fn void sanitise_caps_the_number_of_types() @test
{
	@pool()
	{
		String[] offered = alloc::alloc_array(tmem, String, MAX_MIME_TYPES + 8);
		for (usz i = 0; i < offered.len; i++) offered[i] = string::tformat("type/%d", i);
		String[] kept = sanitise_offer(tmem, offered);
		test::eq(kept.len, (sz)MAX_MIME_TYPES);
		test::eq(kept[MAX_MIME_TYPES - 1], "type/31");
	};
}
