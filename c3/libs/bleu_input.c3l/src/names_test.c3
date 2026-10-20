// Unit tests for the pure name helpers: xkb names, short codes, the BCP-47 table and the compositor name map.
module bleu::input::names_test;
import std::core::test, bleu::input::names, bleu::input::languages, bleu::input;

fn void parses_variants() @test
{
	names::XkbName plain = names::parse_xkb("us");
	test::eq((String)plain.layout, "us");
	test::eq((String)plain.variant, "");
	names::XkbName variant = names::parse_xkb("de(nodeadkeys)");
	test::eq((String)variant.layout, "de");
	test::eq((String)variant.variant, "nodeadkeys");
	names::XkbName empty = names::parse_xkb("de()");
	test::eq((String)empty.layout, "de");
	test::eq((String)empty.variant, "");
	names::XkbName open = names::parse_xkb("de(nodeadkeys");
	test::eq((String)open.layout, "de(nodeadkeys");
}

fn void composes_xkb_names() @test
{
	@pool()
	{
		test::eq((String)names::xkb_name("us", "", tmem), "us");
		test::eq((String)names::xkb_name("de", "nodeadkeys", tmem), "de(nodeadkeys)");
	};
}

fn void short_codes() @test
{
	@pool()
	{
		test::eq((String)names::short_code_of("de", tmem), "DE");
		test::eq((String)names::short_code_of("ara", tmem), "ARA");
		test::eq((String)names::short_code_of("english", tmem), "ENG");
		test::eq((String)names::short_code_from_tag("en-US", tmem), "US");
		test::eq((String)names::short_code_from_tag("de", tmem), "DE");
		test::eq((String)names::short_code_from_tag("sr-Latn-RS", tmem), "RS");
	};
}

fn void table_lookups() @test
{
	Entry? us = by_xkb("us");
	test::eq(us.has_value, true);
	test::eq((String)us.value.language, "en-US");
	test::eq(by_xkb("zz") ?? false, false);
	Entry? german = by_description("German");
	test::eq((String)german.value.xkb, "de");
	test::eq(by_description("No such layout") ?? false, false);
}

fn void maps_compositor_names() @test
{
	@pool()
	{
		Layout described = names::layout_from_name("English (US)", tmem);
		test::eq((String)described.id, "us");
		test::eq((String)described.name, "English (US)");
		test::eq((String)described.language, "en-US");
		test::eq((String)described.short_code, "US");
		Layout xkb = names::layout_from_name("de(nodeadkeys)", tmem);
		test::eq((String)xkb.id, "de(nodeadkeys)");
		test::eq((String)xkb.name, "German (nodeadkeys)");
		test::eq((String)xkb.variant, "nodeadkeys");
		Layout unknown = names::layout_from_name("Klingon", tmem);
		test::eq((String)unknown.id, "Klingon");
		test::eq((String)unknown.language, "");
	};
}
