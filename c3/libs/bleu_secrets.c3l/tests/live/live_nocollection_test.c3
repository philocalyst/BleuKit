// Live test against secret_service_mock.py in MODE no-collection (run by ../run.sh).
module bleu::secrets::live_nocollection_test;
import std::time, bleu::operation, bleu::secrets;

fn void the_default_collection_is_created_when_missing() @test
{
	Keyring* keyring = secrets::open(mem)!!;
	defer keyring.close();
	Entry key = { .service = "bleu.new", .account = "h" };
	Operation{Entry}* stored = keyring.store(key, (char[])"made fresh")!!;
	defer stored.release();
	stored.wait(time::sec(10))!!;
	Operation{Secret}* read = keyring.read(key)!!;
	defer read.release();
	Secret secret = read.wait(time::sec(10))!!;
	assert((String)secret.bytes == "made fresh");
	secret.wipe();
}
