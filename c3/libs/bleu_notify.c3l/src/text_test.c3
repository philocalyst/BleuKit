module bleu::notify::text_test;
import bleu::notify::text;

fn void truncate_keeps_short_text() @test
{
	assert(text::truncate("abc", 10) == "abc");
	assert(text::truncate("abc", 3) == "abc");
}

fn void truncate_cuts_plain_bytes() @test
{
	assert(text::truncate("abcdef", 4) == "abcd");
}

fn void truncate_never_splits_a_character() @test
{
	// "é" is two bytes (C3 A9): a cut after the first byte must back up to before it.
	assert(text::truncate("aé", 2) == "a");
	assert(text::truncate("aé", 3) == "aé");
	// "€" is three bytes (E2 82 AC).
	assert(text::truncate("€€", 4) == "€");
}