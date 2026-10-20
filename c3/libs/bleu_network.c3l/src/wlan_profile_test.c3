module bleu::network::wlan_profile_test;
import bleu::error, bleu::network, bleu::network::wlan_profile;

fn bool has(String text, String part) @local => text.contains(part);

fn void open_profile_has_no_key() @test
{
	@pool()
	{
		String xml = wlan_profile::profile_xml(tmem, (char[])"Cafe", OPEN, "", true)!!;
		assert(has(xml, "<authentication>open</authentication>"));
		assert(has(xml, "<encryption>none</encryption>"));
		assert(has(xml, "<connectionMode>auto</connectionMode>"));
		assert(has(xml, "<hex>43616665</hex>"), "the SSID's octets, in hex");
		assert(!has(xml, "sharedKey"), "an open network has no key");
	};
}

fn void wpa2_profile_carries_the_passphrase() @test
{
	@pool()
	{
		String xml = wlan_profile::profile_xml(tmem, (char[])"Office", WPA2_PSK, "correct horse", false)!!;
		assert(has(xml, "<authentication>WPA2PSK</authentication>"));
		assert(has(xml, "<encryption>AES</encryption>"));
		assert(has(xml, "<keyType>passPhrase</keyType>"));
		assert(has(xml, "<protected>false</protected>"));
		assert(has(xml, "<keyMaterial>correct horse</keyMaterial>"));
		assert(has(xml, "<connectionMode>manual</connectionMode>"));
		assert(has(xml, "<name>Office</name>"), "a UTF-8 SSID is also written as text");
	};
}

fn void sae_profile_uses_wpa3() @test
{
	@pool()
	{
		String xml = wlan_profile::profile_xml(tmem, (char[])"Guest", WPA3_SAE, "sae-password", true)!!;
		assert(has(xml, "<authentication>WPA3SAE</authentication>"));
		assert(has(xml, "<keyMaterial>sae-password</keyMaterial>"));
	};
}

fn void markup_in_text_is_escaped() @test
{
	@pool()
	{
		String xml = wlan_profile::profile_xml(tmem, (char[])"A&B", WPA2_PSK, "p<w>\"&'", false)!!;
		assert(has(xml, "<keyMaterial>p&lt;w&gt;&quot;&amp;&apos;</keyMaterial>"));
		assert(has(xml, "<name>A&amp;B</name>"));
	};
}

fn void non_text_ssid_gets_a_hex_name() @test
{
	@pool()
	{
		char[] legacy = (char[])"\xff\xfeLegacy";
		assert(wlan_profile::profile_name(tmem, legacy) == "bleu-fffe4c6567616379", "the octets in hex");
		String xml = wlan_profile::profile_xml(tmem, legacy, OPEN, "", false)!!;
		assert(has(xml, "<hex>fffe4c6567616379</hex>"));
		assert(!has(xml, "<name>\xff"), "no invented text for non-UTF-8 octets");
	};
}

fn void keyed_profiles_need_a_passphrase_and_others_are_refused() @test
{
	@pool()
	{
		assert(@catch(
			wlan_profile::profile_xml(tmem, (char[])"Office", WPA2_PSK, "", true)
		) == error::INVALID_ARGUMENT);
		assert(@catch(wlan_profile::profile_xml(tmem, (char[])"Shared", WEP, "key", true)) == error::UNSUPPORTED);
		assert(@catch(wlan_profile::profile_xml(tmem, (char[])"Corp", ENTERPRISE, "", true)) == error::UNSUPPORTED);
	};
}