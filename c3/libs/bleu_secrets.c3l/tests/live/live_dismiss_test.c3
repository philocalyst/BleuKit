// Live test against secret_service_mock.py in MODE dismiss (run by ../run.sh).
module bleu::secrets::live_dismiss_test;
import std::time, bleu::error, bleu::operation, bleu::secrets;

// MODE dismiss: the user dismisses the prompt, so the store fails with AUTH_REQUIRED.
fn void a_dismissed_prompt_fails_the_operation() @test
{
	Keyring* keyring = secrets::open(mem)!!;
	defer keyring.close();
	Operation{Entry}* stored = keyring.store({ .service = "bleu.dismiss", .account = "e" }, (char[])"x")!!;
	defer stored.release();
	assert(@catch(stored.wait(time::sec(10))) == error::AUTH_REQUIRED);
}
