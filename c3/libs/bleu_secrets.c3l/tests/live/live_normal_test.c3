// Live test against secret_service_mock.py in MODE normal (run by ../run.sh).
module bleu::secrets::live_normal_test;
import std::time, bleu::error, bleu::observe, bleu::operation, bleu::stream, bleu::secrets;

fn Keyring* open_keyring(Options options = { }) @local
{
	return secrets::open(mem, options)!!;
}

fn void encrypted_round_trip_with_events() @test
{
	Keyring* keyring = open_keyring();
	defer keyring.close();
	assert(keyring.backend_name() == "secret-service");
	assert(keyring.capability(ENCRYPTED_TRANSPORT).ok(), "the mock offers the DH session");
	Reader{Event}* events = keyring.subscribe()!!;
	defer events.release();

	Entry key = {
		.service = "bleu.wifi",
		.account = "home",
		.label = "Home Wi-Fi",
		.attributes = { { .key = "ssid", .value = "home" } }
	};
	String password          = "correct horse battery";
	Operation{Entry}* stored = keyring.store(key, (char[])password)!!;
	defer stored.release();
	Entry saved = stored.wait(time::sec(10))!!;
	assert(saved.service == "bleu.wifi" && saved.account == "home");

	Operation{Secret}* read = keyring.read(key)!!;
	defer read.release();
	Secret secret = read.wait(time::sec(10))!!;
	assert((String)secret.bytes == password, "the value comes back decrypted");
	secret.wipe();
	assert(secret.bytes[0] == 0, "wipe zeroes the bytes");

	Snapshot{State}* state = keyring.latest()!!;
	defer state.release();
	assert(state.value.transport == ENCRYPTED, "the published state reports the encrypted transport");
	assert(state.value.lock == UNLOCKED);

	Packet{Event}* first = events.next(time::sec(5))!!;
	defer first.release();
	assert(first.value.kind == STORED && first.value.service == "bleu.wifi", "the store is announced");
}

fn void search_finds_by_attribute_and_delete_removes() @test
{
	Keyring* keyring = open_keyring();
	defer keyring.close();
	Entry key = { .service = "bleu.vpn", .account = "work", .attributes = { { .key = "profile", .value = "office" } } };
	Operation{Entry}* stored = keyring.store(key, (char[])"s3cret")!!;
	defer stored.release();
	stored.wait(time::sec(10))!!;

	Operation{Entry[]}* found = keyring.search({ .attributes = profile })!!;
	defer found.release();
	Entry[] hits = found.wait(time::sec(10))!!;
	assert(hits.len >= 1, "the search finds the entry");
	bool seen = false;
	foreach (hit : hits)
	{
		if (hit.service == "bleu.vpn" && hit.account == "work") seen = true;
	}
	assert(seen, "the hit names the service and account");

	Operation{bool}* removed = keyring.delete(key)!!;
	defer removed.release();
	assert(removed.wait(time::sec(10))!!, "something was deleted");
	Operation{bool}* again = keyring.delete(key)!!;
	defer again.release();
	assert(!again.wait(time::sec(10))!!, "a second delete finds nothing");
}

fn void reserved_attribute_keys_are_refused() @test
{
	Keyring* keyring = open_keyring();
	defer keyring.close();
	Entry key = { .service = "bleu.x", .account = "y", .attributes = { { .key = "bleu.owner", .value = "someone" } } };
	assert(@catch(keyring.store(key, (char[])"v")) == error::INVALID_ARGUMENT);
}

fn void unknown_entries_read_as_not_found() @test
{
	Keyring* keyring = open_keyring();
	defer keyring.close();
	Entry key               = { .service = "bleu.none", .account = "nobody" };
	Operation{Secret}* read = keyring.read(key)!!;
	defer read.release();
	assert(@catch(read.wait(time::sec(10))) == NOT_FOUND);
}