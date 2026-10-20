// Live tests against secret_service_mock.py in MODE hang (run by ../run.sh).
module bleu::secrets::live_hang_test;
import std::time, std::thread, bleu::error, bleu::operation, bleu::secrets;

// MODE hang: the prompt never completes; the operation must end at its deadline.
fn void a_prompt_that_never_completes_times_out() @test
{
	Keyring* keyring = secrets::open(mem, { .prompt_timeout = (Duration)300_000 })!!;
	defer keyring.close();
	Operation{Entry}* stored = keyring.store({ .service = "bleu.hang", .account = "f" }, (char[])"x")!!;
	defer stored.release();
	assert(@catch(stored.wait(time::sec(10))) == TIMEOUT, "the wait for the prompt is bounded");
}

// MODE hang: cancelling the operation dismisses the prompt and ends it at once.
fn void cancelling_a_waiting_prompt_ends_the_operation() @test
{
	Keyring* keyring = secrets::open(mem, { .prompt_timeout = (Duration)30_000_000 })!!;
	defer keyring.close();
	Operation{Entry}* stored = keyring.store({ .service = "bleu.cancel", .account = "g" }, (char[])"x")!!;
	defer stored.release();
	thread::sleep((Duration)200_000);
	stored.cancel();
	assert(@catch(stored.wait(time::sec(5))) == error::CANCELLED, "cancel ends the wait promptly");
}