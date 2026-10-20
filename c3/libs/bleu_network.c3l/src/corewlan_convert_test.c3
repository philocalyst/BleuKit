module bleu::network::corewlan_convert_test;
import bleu::error, bleu::network, bleu::network::corewlan_convert;

fn void security_classes_follow_the_header() @test
{
	assert(corewlan_convert::security_from_cw(0) == OPEN);
	assert(corewlan_convert::security_from_cw(1) == WEP);
	assert(corewlan_convert::security_from_cw(4) == WPA2_PSK);
	assert(corewlan_convert::security_from_cw(11) == WPA3_SAE);
	assert(corewlan_convert::security_from_cw(13) == WPA2_PSK, "a WPA3 transition is reported as WPA2");
	assert(corewlan_convert::security_from_cw(14) == OWE);
	assert(corewlan_convert::security_from_cw(9) == ENTERPRISE);
	assert(corewlan_convert::security_from_cw(99) == UNKNOWN);
}

fn void bands_and_channels_give_frequencies() @test
{
	assert(corewlan_convert::band_from_cw(2) == GHZ_5);
	assert(corewlan_convert::frequency_from_channel(1, 6)!! == (MegaHertz)2437);
	assert(corewlan_convert::frequency_from_channel(1, 14)!! == (MegaHertz)2484, "channel 14 is off the 5 MHz grid");
	assert(@catch(corewlan_convert::frequency_from_channel(1, 15)) == NOT_FOUND);
	assert(corewlan_convert::frequency_from_channel(2, 36)!! == (MegaHertz)5180);
	assert(corewlan_convert::frequency_from_channel(3, 5)!! == (MegaHertz)5975);
	assert(@catch(corewlan_convert::frequency_from_channel(0, 6)) == NOT_FOUND);
}

fn void cw_errors_map_to_excuses() @test
{
	assert(corewlan_convert::fault_from_cw_error(-3905) == TIMEOUT);
	assert(corewlan_convert::fault_from_cw_error(
		-3924
	) == error::AUTH_REQUIRED, "an invalid PMK is a refused password");
	assert(corewlan_convert::fault_from_cw_error(-3930) == error::PERMISSION_DENIED);
	assert(corewlan_convert::fault_from_cw_error(-3931) == error::BACKEND_FAILURE, "kCWErr has no class of its own");
}

// D5: an association is one with a name, a BSSID, a signal or a rate, even when the name is withheld.
fn void an_association_with_withheld_names_is_still_an_association() @test
{
	assert(corewlan_convert::is_associated(false, false, -61, 0.0), "a signal and no name: associated");
	assert(corewlan_convert::is_associated(false, false, 0, 866.0), "a rate and no name: associated");
	assert(corewlan_convert::is_associated(true, false, 0, 0.0));
	assert(!corewlan_convert::is_associated(false, false, 0, 0.0), "nothing at all: not associated");
}

// D6: a withheld name without Location authorization is a permission problem, not an absent network.
fn void a_withheld_name_is_a_permission_problem() @test
{
	assert(corewlan_convert::missing_network_fault(LocationAccess.DENIED, true) == error::PERMISSION_DENIED);
	assert(corewlan_convert::missing_network_fault(LocationAccess.NOT_DETERMINED, true) == error::PERMISSION_DENIED);
	assert(corewlan_convert::missing_network_fault(
		LocationAccess.AUTHORIZED,
		true
	) == NOT_FOUND, "authorized: not there");
	assert(corewlan_convert::missing_network_fault(LocationAccess.DENIED, false) == NOT_FOUND, "nothing withheld");
}

// D32: the access point refusing this client is not a password problem.
fn void an_association_refusal_is_not_a_password_problem() @test
{
	assert(corewlan_convert::fault_from_cw_error(-3909) == error::PERMISSION_DENIED);
	assert(corewlan_convert::fault_from_cw_error(-3924) == error::AUTH_REQUIRED, "an invalid PMK is still a password");
}