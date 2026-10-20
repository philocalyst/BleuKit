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

// D4: the profile is written per user: WLAN_PROFILE_USER (2), never the all-user flag 0.
fn void profiles_are_per_user_and_named_by_their_ssid() @test
{
	@pool()
	{
		assert(wlan_profile::profile_scope_flags() == 2, "WLAN_PROFILE_USER: a per-user profile");
		assert(wlan_profile::profile_scope_flags() != 0, "flag 0 is the all-user profile, which needs a DACL grant");
		// D13: bleu's profile names carry its prefix and the SSID's hex: no text name can take another's.
		assert(wlan_profile::profile_name(tmem, (char[])"Office") == "bleu-4f6666696365");
	};
}

// D3: a keyed network with no passphrase connects by its saved profile and writes nothing.
fn void a_keyed_network_without_a_passphrase_uses_its_saved_profile() @test
{
	assert(wlan_profile::connect_route(WPA2_PSK, false) == wlan_profile::ConnectRoute.USE_SAVED_PROFILE);
	assert(wlan_profile::connect_route(WPA3_SAE, false) == wlan_profile::ConnectRoute.USE_SAVED_PROFILE);
	assert(wlan_profile::connect_route(
		WPA2_PSK,
		true
	) == wlan_profile::ConnectRoute.WRITE_PROFILE, "a passphrase is written");
	assert(wlan_profile::connect_route(
		OPEN,
		false
	) == wlan_profile::ConnectRoute.WRITE_PROFILE, "an open network is keyless");
}

// D22, D23: a control character in the SSID never reaches the XML; the octets stay the identity.
fn void a_control_character_never_reaches_the_profile() @test
{
	@pool()
	{
		String xml = wlan_profile::profile_xml(tmem, (char[])"Home\x01", WPA2_PSK, "correct horse", false)!!;
		assert(!has(xml, "\x01"), "no XML-invalid character");
		assert(!has(xml, "\t\t\t<name>"), "the SSID's display name is left out");
		assert(has(xml, "<hex>486f6d6501</hex>"), "the octets are still written");
	};
}