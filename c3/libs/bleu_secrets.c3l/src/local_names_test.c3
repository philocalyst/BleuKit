module bleu::secrets::local_test;
import std::time, bleu::error, bleu::secrets, bleu::secrets::local, bleu::secrets::keychain;

fn void target_names_round_trip_with_separators() @test
{
	String name = local::target_name(tmem, "wifi:home", "a%b")!!;
	assert(name == "bleu:wifi%3Ahome:a%25b", "separators and percent signs are escaped");
	String service;
	String account;
	local::split_target(tmem, name, &service, &account)!!;
	assert(service == "wifi:home" && account == "a%b");
}

fn void foreign_target_names_are_not_ours() @test
{
	String service;
	String account;
	assert(@catch(local::split_target(tmem, "git:ssh", &service, &account)) == NOT_FOUND);
	assert(@catch(local::split_target(tmem, "bleu:nocolon", &service, &account)) == error::PROTOCOL);
}

fn void bad_escapes_are_refused() @test
{
	assert(@catch(local::unescape_part(tmem, "a%2")) == error::PROTOCOL);
	assert(@catch(local::unescape_part(tmem, "a%ZZx")) == error::PROTOCOL);
}

fn void filetime_epoch_is_the_unix_epoch() @test
{
	assert(local::filetime_to_time(local::FILETIME_UNIX_EPOCH) == (Time)0);
	// 2000-01-01T00:00:00Z is 946684800 s after the Unix epoch.
	Time y2k = local::filetime_to_time(local::FILETIME_UNIX_EPOCH + 946684800UL * 10000000UL);
	assert((long)y2k == 946684800000000L, "one second is one million microseconds");
}

fn void keychain_codes_map_to_excuses() @test
{
	assert(keychain::status_fault(keychain::ERR_SEC_ITEM_NOT_FOUND) == NOT_FOUND);
	assert(keychain::status_fault(keychain::ERR_SEC_AUTH_FAILED) == error::AUTH_REQUIRED);
	assert(keychain::status_fault(keychain::ERR_SEC_USER_CANCELED) == error::AUTH_REQUIRED);
	assert(keychain::status_fault(keychain::ERR_SEC_NOT_AVAILABLE) == error::UNAVAILABLE);
	assert(keychain::status_fault(keychain::ERR_SEC_PARAM) == error::INVALID_ARGUMENT);
	assert(keychain::status_fault(-25308) == error::BACKEND_FAILURE, "unmapped codes stay generic");
}

fn void attributes_round_trip_and_damage_is_refused() @test
{
	Attribute[] attributes = { { .key = "ssid", .value = "home" }, { .key = "empty", .value = "" } };
	char[] blob = local::encode_attributes(tmem, attributes);
	Attribute[] back = local::decode_attributes(tmem, (String)blob)!!;
	assert(back.len == 2 && back[0].key == "ssid" && back[0].value == "home" && back[1].value == "");
	assert(@catch(local::decode_attributes(tmem, (String)blob[0 : blob.len - 1])) == error::PROTOCOL, "a cut blob is refused");
}
