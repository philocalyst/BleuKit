module bleu::clipboard;
import std::core::test;

fn void utf16_length_stops_at_the_terminator() @test
{
	Char16[4] terminated = { 'a', 'b', 0, 'c' };
	test::eq(utf16_length(terminated[..]), (usz)2);
	Char16[2] unterminated = { 'x', 'y' };
	test::eq(utf16_length(unterminated[..]), (usz)2);
	test::eq(utf16_length({ }), (usz)0);
}