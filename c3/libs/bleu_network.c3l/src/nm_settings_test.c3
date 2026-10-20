module bleu::network::nm_settings_test;
import bleu::error, bleu::network, bleu::network::nm_settings, bleu::dbus::value;

fn String group_string(Value settings, String group, String key)
{
	Value dict = settings.dict_get(group)!!;
	return dict.dict_get(key)!!.as_string()!!;
}

fn void wpa_psk_profile_carries_the_passphrase() @test
{
	@pool()
	{
		char[] ssid = (char[])"Office";
		Value settings = nm_settings::profile_settings(
			tmem,
			{
				.ssid = ssid,
				.id = "Office",
				.uuid = "00000000-0000-0000-0000-000000000001",
				.autoconnect = true,
				.key_mgmt = WPA_PSK,
				.psk = "correct horse",
			}
		)!!;
		assert(settings.sig == "a{sa{sv}}");
		assert(group_string(settings, "connection", "type") == "802-11-wireless");
		assert(group_string(settings, "connection", "id") == "Office");
		assert(group_string(settings, "802-11-wireless", "mode") == "infrastructure");
		assert(group_string(settings, "802-11-wireless-security", "key-mgmt") == "wpa-psk");
		assert(group_string(settings, "802-11-wireless-security", "psk") == "correct horse");
		char[] round_trip = nm_settings::bytes_from(tmem, settings.dict_get("802-11-wireless")!!.dict_get("ssid")!!)!!;
		assert(round_trip == ssid, "the SSID is written as its octets");
	};
}

fn void open_and_owe_profiles_have_no_passphrase() @test
{
	@pool()
	{
		Value open = nm_settings::profile_settings(
			tmem,
			{ .ssid = (char[])"Cafe", .id = "Cafe", .uuid = "u", .autoconnect = false, .key_mgmt = OPEN }
		)!!;
		assert(@catch(open.dict_get("802-11-wireless-security")) == NOT_FOUND, "an open profile has no security group");
		Value owe = nm_settings::profile_settings(
			tmem,
			{ .ssid = (char[])"Lounge", .id = "Lounge", .uuid = "u", .key_mgmt = OWE }
		)!!;
		assert(group_string(owe, "802-11-wireless-security", "key-mgmt") == "owe");
		assert(@catch(
			owe.dict_get("802-11-wireless-security")!!.dict_get("psk")
		) == NOT_FOUND, "OWE has no passphrase");
	};
}

fn void sae_profile_uses_sae_key_management() @test
{
	@pool()
	{
		Value settings = nm_settings::profile_settings(
			tmem,
			{ .ssid = (char[])"Guest", .id = "Guest", .uuid = "u", .key_mgmt = SAE, .psk = "sae-password" }
		)!!;
		assert(group_string(settings, "802-11-wireless-security", "key-mgmt") == "sae");
		assert(group_string(settings, "802-11-wireless-security", "psk") == "sae-password");
	};
}

fn void uuids_are_stable_and_well_formed() @test
{
	@pool()
	{
		String first = nm_settings::uuid_for_ssid(tmem, (char[])"Office");
		String again = nm_settings::uuid_for_ssid(tmem, (char[])"Office");
		String other = nm_settings::uuid_for_ssid(tmem, (char[])"Cafe");
		assert(first.len == 36, "8-4-4-4-12 hex digits");
		assert(first == again, "the same network gets the same profile id");
		assert(first != other, "different networks get different ids");
		assert(first[8] == '-' && first[13] == '-' && first[18] == '-' && first[23] == '-');
	};
}

fn void with_bool_replaces_one_key() @test
{
	@pool()
	{
		Value settings = nm_settings::profile_settings(
			tmem,
			{
				.ssid = (char[])"Office",
				.id = "Office",
				.uuid = "u",
				.autoconnect = true,
				.key_mgmt = WPA_PSK,
				.psk = "correct horse"
			}
		)!!;
		Value quiet      = nm_settings::with_bool(tmem, settings, "connection", "autoconnect", false)!!;
		Value connection = quiet.dict_get("connection")!!;
		assert(connection.dict_get("autoconnect")!!.as_bool()!! == false, "autoconnect is now false");
		assert(connection.dict_get("id")!!.as_string()!! == "Office", "the other keys are kept");
		assert(quiet.dict_get(
			"802-11-wireless-security"
		)!!.dict_get("psk")!!.as_string()!! == "correct horse", "the other groups are kept");
		Value added = nm_settings::with_bool(tmem, settings, "ipv4", "ignore-auto-dns", true)!!;
		assert(added.dict_get("ipv4")!!.dict_get("ignore-auto-dns")!!.as_bool()!!, "a missing group is created");
	};
}

// D12: a saved profile gets only its new secret; its other settings (addresses, DNS, MTU) are kept.
fn void a_saved_profile_keeps_its_settings_when_its_secret_changes() @test
{
	@pool()
	{
		Value base = nm_settings::profile_settings(
			tmem,
			{
				.ssid = (char[])"Office",
				.id = "Office",
				.uuid = "00000000-0000-0000-0000-000000000001",
				.autoconnect = true,
				.key_mgmt = WPA_PSK,
				.psk = "old password",
			}
		)!!;
		Value with_ipv4 = nm_settings::with_bool(tmem, base, "ipv4", "ignore-auto-dns", true)!!;
		Value updated   = nm_settings::with_secret(tmem, with_ipv4, WPA_PSK, "new password")!!;
		assert(group_string(updated, "802-11-wireless-security", "psk") == "new password");
		assert(group_string(updated, "802-11-wireless-security", "key-mgmt") == "wpa-psk");
		assert(group_string(updated, "connection", "id") == "Office", "the id is kept");
		assert(updated.dict_get("ipv4")!!.dict_get("ignore-auto-dns")!!.as_bool()!!, "another group is kept");
		assert(updated.dict_get("connection")!!.dict_get("autoconnect")!!.as_bool()!!, "autoconnect is kept");
	};
}

// D24: the UUID comes from SHA-256 and has the RFC 9562 version 8 and RFC 4122 variant bits.
fn void uuids_are_sha256_with_version_8_and_the_rfc_variant() @test
{
	@pool()
	{
		String id = nm_settings::uuid_for_ssid(tmem, (char[])"Office");
		assert(id[14] == '8', "version 8 (a custom UUID from a hash)");
		assert(id[19] == '8' || id[19] == '9' || id[19] == 'a' || id[19] == 'b', "RFC 4122 variant");
		assert(id != nm_settings::uuid_for_ssid(tmem, (char[])"Office "), "one octet apart: another network");
	};
}
