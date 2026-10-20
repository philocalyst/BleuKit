module bleu::network::nm_convert_test;
import bleu::error, bleu::network, bleu::network::nm_convert;

fn void bands_follow_the_channel_plans() @test
{
	assert(nm_convert::band_from_mhz(2412) == GHZ_2_4);
	assert(nm_convert::band_from_mhz(2484) == GHZ_2_4);
	assert(nm_convert::band_from_mhz(5180) == GHZ_5);
	assert(nm_convert::band_from_mhz(5955) == GHZ_6);
	assert(nm_convert::band_from_mhz(0) == UNKNOWN);
}

fn void security_follows_the_access_point_flags() @test
{
	assert(nm_convert::security_from_flags(0, 0, 0) == OPEN, "no privacy, no WPA element: open");
	assert(nm_convert::security_from_flags(0x2, 0, 0) == OPEN, "WPS bits do not make a network secured");
	assert(nm_convert::security_from_flags(0x1, 0, 0) == WEP, "privacy alone is static WEP");
	assert(nm_convert::security_from_flags(0x1, 0x100, 0) == WPA_PSK, "WPA1 pre-shared key");
	assert(nm_convert::security_from_flags(0x1, 0, 0x100) == WPA2_PSK, "RSN pre-shared key");
	assert(nm_convert::security_from_flags(0x1, 0, 0x400) == WPA3_SAE, "SAE only");
	assert(nm_convert::security_from_flags(0x1, 0, 0x500) == WPA2_PSK, "WPA2/WPA3 transition reports WPA2");
	assert(nm_convert::security_from_flags(0x1, 0, 0x800) == OWE, "OWE");
	assert(nm_convert::security_from_flags(0x1, 0, 0x200) == ENTERPRISE, "802.1X");
}

fn void reasons_map_to_failure_classes() @test
{
	assert(nm_convert::failure_from_reason(0) == NONE);
	assert(nm_convert::failure_from_reason(7) == NO_SECRETS);
	assert(nm_convert::failure_from_reason(9) == SUPPLICANT_FAILED);
	assert(nm_convert::failure_from_reason(11) == SUPPLICANT_TIMEOUT);
	assert(nm_convert::failure_from_reason(17) == DHCP_FAILED);
	assert(nm_convert::failure_from_reason(39) == CANCELLED);
	assert(nm_convert::failure_from_reason(40) == CARRIER_LOST);
	assert(nm_convert::failure_from_reason(53) == SSID_NOT_FOUND);
	assert(nm_convert::failure_from_reason(999) == UNKNOWN, "a reason with no class stays UNKNOWN");
}

fn void device_states_map_to_phases() @test
{
	assert(nm_convert::phase_from_device_state(30) == IDLE);
	assert(nm_convert::phase_from_device_state(50) == CONNECTING);
	assert(nm_convert::phase_from_device_state(60) == AUTH_REQUIRED);
	assert(nm_convert::phase_from_device_state(70) == OBTAINING_ADDRESS);
	assert(nm_convert::phase_from_device_state(100) == CONNECTED);
	assert(nm_convert::phase_from_device_state(110) == DISCONNECTING);
	assert(nm_convert::phase_from_device_state(120) == FAILED);
}

fn void connectivity_and_device_types() @test
{
	assert(nm_convert::connectivity_from(4) == FULL);
	assert(nm_convert::connectivity_from(2) == PORTAL);
	assert(nm_convert::connectivity_from(9) == UNKNOWN);
	assert(nm_convert::kind_from_device_type(2)!! == WIFI);
	assert(nm_convert::kind_from_device_type(1)!! == ETHERNET);
	assert(@catch(nm_convert::kind_from_device_type(8)) == NOT_FOUND, "modems are not reported");
}

fn void strength_is_a_level() @test
{
	float half = (float)nm_convert::quality_from_strength(50);
	assert(half > 0.499f && half < 0.501f);
	assert((float)nm_convert::quality_from_strength(0) == 0.0f);
}

// D25: an unavailable or unmanaged device is its own phase, not idle.
fn void an_unavailable_device_is_its_own_phase() @test
{
	assert(nm_convert::phase_from_device_state(nm_convert::DEVICE_STATE_UNAVAILABLE) == ConnectionPhase.UNAVAILABLE);
	assert(nm_convert::phase_from_device_state(nm_convert::DEVICE_STATE_UNMANAGED) == ConnectionPhase.UNAVAILABLE);
	assert(nm_convert::phase_from_device_state(nm_convert::DEVICE_STATE_DISCONNECTED) == ConnectionPhase.IDLE);
}