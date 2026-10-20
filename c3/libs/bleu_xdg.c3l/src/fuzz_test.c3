// Robustness tests for the text parsers of this library: key files, desktop
// entries, Exec lines and icon theme indexes. Each attempt runs in its own pool.
// Every input must be accepted or refused, and none may crash or read past its end.
module bleu::xdg::desktop_entry;
import bleu::error, bleu::xdg::exec, bleu::xdg::icon, bleu::xdg::keyfile, std::core::test;

const ulong LCG_MULTIPLIER = 6364136223846793005;
const ulong LCG_INCREMENT  = 1442695040888963407;
const int LCG_SHIFT        = 33;
const int ROUNDS           = 6000;
const usz MAX_INPUT        = 160;
const int STRUCTURAL_BYTES = 16;
const String STRUCTURAL    = "[]=;\\%\"'#\n\r \tAx-";

// A small deterministic generator, so a failure reproduces.
struct Random
{
	ulong state;
}

fn uint Random.next(&self)
{
	self.state = self.state * LCG_MULTIPLIER + LCG_INCREMENT;
	return (uint)(self.state >> LCG_SHIFT);
}

// Mostly structural characters, sometimes any byte, so the parsers reach their deep states.
fn char random_byte(Random* random) @local
{
	if (random.next() % 4 != 0) return STRUCTURAL[random.next() % STRUCTURAL_BYTES];
	return (char)(random.next() & 0xFF);
}

fn void text_parsers_accept_or_refuse_random_input() @test
{
	Random random   = { .state = 0xD15C0 };
	Context context = { .files = { "/a b" }, .urls = { "https://x/" }, .icon = "i", .name = "n", .location = "/l" };
	for (int round = 0; round < ROUNDS; round++)
	{
		usz length   = random.next() % MAX_INPUT;
		char[] input = alloc::new_array(tmem, char, (sz)length);
		for (usz i = 0; i < length; i++) input[i] = random_byte(&random);
		String text = (String)input;
		@pool()
		{
			// Only the absence of a fault matters here: each call must return.
			if (catch keyfile::parse(tmem, text))
			{
			}
			if (catch parse(tmem, text, "de_DE"))
			{
			}
			if (catch exec::expand(tmem, text, context))
			{
			}
			if (catch icon::parse_index(tmem, "theme", text))
			{
			}
		};
	}
}