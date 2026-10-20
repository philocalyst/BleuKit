module bleu::network::scan_test;
import std::collections::list, std::collections::maybe, bleu::error, bleu::network, bleu::unit;

// An access point with a SSID, a security class, a quality in percent and a BSSID.
fn AccessPoint access_point(char[] ssid, Security security, float quality, String bssid, bool in_use) @local
{
	return {
		.ssid = network::make_ssid(tmem, ssid),
		.bssid = bssid,
		.quality = maybe::value(unit::from_percent(quality)),
		.security = security,
		.in_use = in_use,
	};
}

// D11, D30: a network the scan did not show, or whose class is unknown, cannot be joined.
fn void only_a_scanned_network_with_a_known_class_is_joined() @test
{
	@pool()
	{
		AccessPoint[] scanned = {
			access_point((char[])"Office", WPA2_PSK, 90, "", false),
			access_point((char[])"Mystery", UNKNOWN, 50, "", false),
		};
		assert(network::security_in(scanned, (char[])"Office")!! == WPA2_PSK);
		assert(@catch(network::security_in(scanned, (char[])"Nowhere")) == NOT_FOUND, "not in the last scan");
		assert(network::joinable_in(scanned, (char[])"Office")!! == WPA2_PSK);
		assert(@catch(
			network::joinable_in(scanned, (char[])"Nowhere")
		) == NOT_FOUND, "not in the last scan: NOT_FOUND");
		assert(@catch(
			network::joinable_in(scanned, (char[])"Mystery")
		) == error::UNSUPPORTED, "a class that is not known is refused: nothing is saved for it");
	};
}

// D15: one entry per network, with the strongest access point's BSSID and in use when any is.
fn void access_points_of_one_network_are_one_entry() @test
{
	@pool()
	{
		List{AccessPoint} merged;
		merged.init(tmem);
		network::merge_access_point(&merged, access_point((char[])"Office", WPA2_PSK, 40, "aa:aa:aa:aa:aa:01", false));
		network::merge_access_point(&merged, access_point((char[])"Office", WPA2_PSK, 85, "aa:aa:aa:aa:aa:02", true));
		network::merge_access_point(&merged, access_point((char[])"Office", WPA2_PSK, 60, "aa:aa:aa:aa:aa:03", false));
		assert(merged.len() == 1, "three access points of one network are one entry");
		AccessPoint entry = merged.get(0);
		assert(entry.bssid == "aa:aa:aa:aa:aa:02", "the strongest access point's BSSID");
		assert(entry.in_use, "in use when any of its access points is");
		network::merge_access_point(&merged, access_point((char[])"", WPA2_PSK, 70, "", false));
		network::merge_access_point(&merged, access_point((char[])"", WPA2_PSK, 30, "", false));
		assert(merged.len() == 3, "withheld names cannot be matched: one entry each");
	};
}