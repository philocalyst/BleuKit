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

// D23: a name with control or bidirectional-override characters is shown as nothing; its octets stay.
fn void names_that_hide_or_reorder_text_have_no_label() @test
{
	@pool()
	{
		assert(network::make_ssid(tmem, (char[])"Home\x01").label == "", "a control character");
		assert(network::make_ssid(tmem, (char[])"\xe2\x80\xaeCafe").label == "", "a right-to-left override");
		assert(network::make_ssid(tmem, (char[])"\xe2\x81\xa9x").label == "", "an isolate");
		assert(network::make_ssid(tmem, (char[])"Caf\xc3\xa9").label == "Café", "ordinary UTF-8 is labelled");
		assert(network::make_ssid(tmem, (char[])"Home\x01").bytes.len == 5, "the octets are still the identity");
	};
}
