// Robustness tests: every prefix of every golden fixture, and a deterministic
// stream of random corruptions, must be either decoded or refused. None may crash,
// read out of bounds, or leak temporary memory (each attempt runs in its own pool).
module bleu::plist;
import bleu::error, std::core::test;

const ulong LCG_MULTIPLIER    = 6364136223846793005;
const ulong LCG_INCREMENT     = 1442695040888963407;
const int LCG_SHIFT           = 33;
const int MUTATION_ROUNDS     = 4000;
const int MAX_EDITS_PER_ROUND = 4;

// A small linear congruential generator with a fixed seed, so failures reproduce.
struct Random
{
	ulong state;
}

fn uint Random.next(&self)
{
	self.state = self.state * LCG_MULTIPLIER + LCG_INCREMENT;
	return (uint)(self.state >> LCG_SHIFT);
}

// Decode `input` in a pool of its own, discarding the outcome.
fn void attempt(char[] input) @local
{
	@pool()
	{
		// The outcome is irrelevant here: only that the call returns without faulting.
		if (catch read(tmem, input))
		{
		}
	};
}

fn void every_prefix_of_every_fixture_is_handled() @test
{
	String[] fixtures = {
		$embed("../fixtures/sample.bplist"),
		$embed("../fixtures/uid.bplist"),
		$embed("../fixtures/shared.bplist"),
		$embed("../fixtures/sample.plist"),
		$embed("../fixtures/handwritten.plist"),
		$embed("../fixtures/info.plist"),
		$embed("../fixtures/InfoPlist-en.strings"),
	};
	foreach (fixture : fixtures)
	{
		for (usz length = 0; length <= fixture.len; length++)
		{
			attempt(fixture[0:length]);
		}
	}
}

fn void random_corruptions_are_handled() @test
{
	String[] fixtures = {
		$embed("../fixtures/sample.bplist"),
		$embed("../fixtures/shared.bplist"),
		$embed("../fixtures/sample.plist"),
		$embed("../fixtures/handwritten.plist"),
	};
	Random random = { .state = 0x5EED };
	for (int round = 0; round < MUTATION_ROUNDS; round++)
	{
		String original = fixtures[random.next() % fixtures.len];
		char[] buffer   = alloc::new_array(tmem, char, original.len);
		mem::copy(buffer.ptr, original.ptr, original.len);
		int edits = 1 + (int)(random.next() % MAX_EDITS_PER_ROUND);
		for (int edit = 0; edit < edits; edit++)
		{
			usz position = random.next() % buffer.len;
			buffer[position] = (char)(random.next() & 0xFF);
		}
		usz keep = buffer.len - (random.next() % 4 == 0 ? random.next() % buffer.len : 0);
		attempt(buffer[0:keep]);
	}
}

fn void a_valid_fixture_still_decodes_after_the_fuzzing_helpers() @test
{
	String text = $embed("../fixtures/sample.plist");
	Value root  = read(tmem, text)!!;
	test::eq(Kind.DICT, root.kind);
}