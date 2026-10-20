// Unit tests for the locale1 layout list reader.
module bleu::input::locale1_convert_test;
import std::core::test, bleu::input::locale1_convert;

fn void reads_aligned_lists() @test
{
	@pool()
	{
		Layout[] layouts = layouts_from("us,de", ",nodeadkeys", tmem);
		test::eq(layouts.len, 2);
		test::eq((String)layouts[0].id, "us");
		test::eq((String)layouts[0].variant, "");
		test::eq((String)layouts[1].id, "de(nodeadkeys)");
		test::eq((String)layouts[1].language, "de-DE");
	};
}

fn void skips_empty_layouts_and_missing_variants() @test
{
	@pool()
	{
		Layout[] layouts = layouts_from(",ru,fr", "", tmem);
		test::eq(layouts.len, 2);
		test::eq((String)layouts[0].id, "ru");
		test::eq((String)layouts[1].id, "fr");
	};
	@pool()
	{
		test::eq(layouts_from("", "", tmem).len, 0);
	};
}
