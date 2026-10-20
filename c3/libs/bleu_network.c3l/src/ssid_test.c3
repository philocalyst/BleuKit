module bleu::network::ssid_test;
import bleu::network;

fn void label_is_text_only_when_the_bytes_are_utf8() @test
{
	@pool()
	{
		Ssid cafe = network::make_ssid(tmem, (char[])"Café");
		assert(cafe.label == "Café", "valid UTF-8 is labelled");
		assert(cafe.bytes.len == 5, "the bytes are kept: 'é' is two octets");
		Ssid legacy = network::make_ssid(tmem, (char[])"\xff\xfeLegacy");
		assert(legacy.label == "", "non-UTF-8 gets no invented label");
		assert(legacy.bytes.len == 8);
		Ssid none = network::make_ssid(tmem, (char[])"");
		assert(none.bytes.len == 0 && none.label == "");
	};
}

fn void same_network_is_same_octets() @test
{
	@pool()
	{
		assert(network::same_ssid((char[])"Office", (char[])"Office"));
		assert(!network::same_ssid((char[])"Office", (char[])"office"));
		assert(!network::same_ssid((char[])"Office", (char[])"Office "));
	};
}