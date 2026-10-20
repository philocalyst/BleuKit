// Mutation fuzzing of the Reader. Valid messages are corrupted at random (bytes
// flipped, truncated, extended, read under the wrong signature). The Reader must
// return a fault or a value for every input, and never read outside the data:
// in safe builds an out-of-bounds slice traps, which fails this test.
module bleu::dbus::marshal_fuzz_test;
import bleu::dbus::marshal, bleu::dbus::testing;

<* Corrupted inputs tried per run. *>
const ITERATIONS = 200000;

<* Largest number of mutations applied to one input. *>
const MAX_MUTATIONS = 4;

<* Longest run of random bytes appended to an input. *>
const MAX_APPENDED = 8;

<* A valid marshalled value with the signature it was written under. *>
struct Sample
{
	String hex;
	String sig;
	bool big_endian;
}

<* xorshift64*: a small, fixed-seed generator, so every run tries the same inputs. *>
struct Rng
{
	ulong state;
}

fn ulong Rng.next(&self)
{
	ulong x = self.state;
	x ^= x >> 12;
	x ^= x << 25;
	x ^= x >> 27;
	self.state = x;
	return x * 0x2545F4914F6CDD1D;
}

// A number in [0, n), or 0 when n is 0.
fn usz Rng.below(&self, usz n) => n == 0 ? 0 : (usz)(self.next() % n);

fn void reader_never_breaks_on_corrupted_input() @test
{
	Sample[] samples = {
		{ "03 00 00 00 66 6f 6f 00 01 00 00 00 2b 00 00 00 03 00 00 00 62 61 72 00", "sss", false },
		{ "01 74 00 00 00 00 00 00 05 00 00 00 00 00 00 00", "v", false },
		{ "00 00 00 08 00 00 00 00 00 00 00 00 00 00 00 05", "ax", true },
		{ "18 00 00 00 08 00 00 00 01 00 00 00 02 00 00 00 00 00 00 00 04 00 00 00 03 00 00 00", "aai", false },
		{ "01 00 fe ff 03 00", "(ynq)", false },
		{
			"18 00 00 00 00 00 00 00 01 01 73 00 01 00 00 00 78 00 00 00 00 00 00 00 02 01 75 00 09 00 00 00",
			"a(yv)",
			false
		},
		{
			"60 00 00 00 00 00 00 00 04 00 00 00 4e 61 6d 65 00 01 73 00 04 00 00 00 62 6c 65 75 00 00 00 00 05 00 00 00 43 6f 75 6e 74 00 01 75 00 00 00 00 07 00 00 00 00 00 00 00 06 00 00 00 4e 65 73 74 65 64 00 05 61 7b 73 76 7d 00 00 00 18 00 00 00 01 00 00 00 6b 00 01 76 00 01 64 00 00 00 00 00 00 00 00 00 00 00 f8 3f",
			"a{sv}",
			false
		},
	};
	Rng rng = { .state = 0x9E3779B97F4A7C15 };
	for (int iteration = 0; iteration < ITERATIONS; iteration++)
	{
		@pool()
		{
			Sample sample = samples[rng.below(samples.len)];
			// Half the time read the bytes under another sample's signature.
			String sig    = rng.below(2) == 0 ? sample.sig : samples[rng.below(samples.len)].sig;
			char[] bytes  = mutate(&rng, testing::from_hex(sample.hex));
			Reader r;
			if (try r.init((String)bytes, sig, sample.big_endian)) read_everything(&r);
		};
	}
}

// Reads the whole input both ways; the outcomes are not checked, only that they return.
fn void read_everything(Reader* r) @private
{
	if (catch r.read_value(tmem))
	{
	} // a malformed input is expected to fail here
	Reader skipping;
	if (try skipping.init(r.data, r.frames[0].sig, r.big_endian))
	{
		while (skipping.has_more())
		{
			if (catch skipping.skip_value()) break; // a fault ends the walk
		}
		if (catch skipping.finish())
		{
		} // trailing bytes are a fault, not a crash
	}
}

// A copy of `input` with 1 to MAX_MUTATIONS random edits applied.
fn char[] mutate(Rng* rng, String input) @private
{
	usz capacity = input.len + MAX_APPENDED;
	char[] bytes = alloc::new_array(tmem, char, (sz)capacity);
	for (usz i = 0; i < input.len; i++) bytes[i] = input[i];
	usz len   = input.len;
	usz edits = 1 + rng.below(MAX_MUTATIONS);
	for (usz e = 0; e < edits; e++)
	{
		switch (rng.below(4))
		{
			case 0:
				if (len > 0) bytes[rng.below(len)] = (char)rng.next();
			case 1:
				if (len > 0) bytes[rng.below(len)] ^= (char)(1 << rng.below(8));
			case 2:
				len = rng.below(len + 1);
			default:
				usz extra = 1 + rng.below(MAX_APPENDED);
				for (usz k = 0; k < extra && len < capacity; k++) bytes[len++] = (char)rng.next();
		}
	}
	return bytes[:len];
}