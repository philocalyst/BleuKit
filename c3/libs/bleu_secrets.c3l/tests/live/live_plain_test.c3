// Live test against secret_service_mock.py in MODE refuse-dh (run by ../run.sh).
module bleu::secrets::live_plain_test;
import std::time, bleu::error, bleu::availability, bleu::observe, bleu::operation, bleu::stream, bleu::secrets;

fn void refused_dh_is_reported_and_refused_without_permission() @test
{
	Keyring* keyring = secrets::open(mem)!!;
	defer keyring.close();
	assert(!keyring.capability(ENCRYPTED_TRANSPORT).ok(), "the mock refuses the DH session");
	assert(keyring.capability(ENCRYPTED_TRANSPORT).reason == availability::Reason.UNSUPPORTED_BACKEND);
	Operation{Entry}* stored = keyring.store({ .service = "bleu.a", .account = "b" }, (char[])"v")!!;
	defer stored.release();
	assert(@catch(stored.wait(time::sec(10))) == error::UNSUPPORTED, "no silent plaintext fallback");
}

fn void plain_transport_round_trips_when_allowed() @test
{
	Keyring* keyring = secrets::open(mem, { .allow_plain_transport = true })!!;
	defer keyring.close();
	Entry key                = { .service = "bleu.plain", .account = "c" };
	Operation{Entry}* stored = keyring.store(key, (char[])"plain value")!!;
	defer stored.release();
	stored.wait(time::sec(10))!!;
	Operation{Secret}* read = keyring.read(key)!!;
	defer read.release();
	Secret secret = read.wait(time::sec(10))!!;
	assert((String)secret.bytes == "plain value");
	secret.wipe();
	Snapshot{State}* state = keyring.latest()!!;
	defer state.release();
	assert(state.value.transport == PLAIN, "the state says the value travelled in plain");
}