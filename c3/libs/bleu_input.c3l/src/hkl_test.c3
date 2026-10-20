// Unit tests for the HKL and KLID decoding; the values are the Learn and Wine examples cited in hkl.c3.
module bleu::input::hkl_test;
import std::core::test, bleu::input::hkl;

fn void decodes_language_and_device() @test
{
	test::eq(hkl::language_id(0x04090409), (ushort)0x0409);
	test::eq(hkl::device_word(0x00010409), 0x0001u);
	test::eq(hkl::device_word(0x04090409), 0x0409u);
}

fn void klid_values() @test
{
	test::eq(hkl::klid_value(0x04090409), 0x00000409u);   // primary U.S. English, KLID 00000409
	test::eq(hkl::klid_value(0x00010409), 0x00010409u);   // U.S. Dvorak, KLID 00010409
	test::eq(hkl::klid_value(0x00000407), 0x00000407u);   // German, device word zero
	test::eq(hkl::klid_value(0xF0010409), 0xF0010409u);   // device-specific: unchanged
}

fn void klid_text_is_eight_digits() @test
{
	@pool()
	{
		test::eq((String)hkl::klid_text(0x04090409, tmem), "00000409");
		test::eq((String)hkl::klid_text(0x00010409, tmem), "00010409");
		test::eq((String)hkl::klid_text(0xA0000407, tmem), "a0000407");
	};
}
