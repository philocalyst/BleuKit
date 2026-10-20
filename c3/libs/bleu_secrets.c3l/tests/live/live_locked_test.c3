// Live test against secret_service_mock.py in MODE locked (run by ../run.sh).
module bleu::secrets::live_locked_test;
import std::time, bleu::error, bleu::operation, bleu::stream, bleu::secrets;

fn void an_unlock_prompt_is_shown_and_accepted() @test
{
	Keyring* keyring = secrets::open(mem)!!;
	defer keyring.close();
	Reader{Event}* events = keyring.subscribe()!!;
	defer events.release();
	Operation{Entry}* stored = keyring.store({ .service = "bleu.lock", .account = "d" }, (char[])"after unlock")!!;
	defer stored.release();
	stored.wait(time::sec(10))!!;
	bool shown = false;
	bool ended = false;
	for (int i = 0; i < 8; i++)
	{
		if (try packet = events.next(time::ms(100)))
		{
			if (packet.value.kind == PROMPT_SHOWN) shown = true;
			if (packet.value.kind == PROMPT_ENDED) ended = true;
			packet.release();
		}
	}
	assert(shown && ended, "the prompt is announced as shown and then ended");
}

fn void explicit_unlock_reports_the_lock() @test
{
	Keyring* keyring = secrets::open(mem)!!;
	defer keyring.close();
	Operation{Lock}* unlocked = keyring.unlock()!!;
	defer unlocked.release();
	assert(unlocked.wait(time::sec(10))!! == UNLOCKED);
}