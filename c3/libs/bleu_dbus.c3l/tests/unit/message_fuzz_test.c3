// Mutation fuzzing of whole messages: framing, parsing, and reading the body.
// Corrupted copies of the golden messages must either parse (and then read
// without trapping) or be refused with a fault; they must never crash.
module bleu::dbus::message_fuzz_test;
import bleu::dbus::message, bleu::dbus::testing, bleu::dbus::value, bleu::dbus::marshal;
import bleu::dbus::message_golden_test;

<* Corrupted messages tried per run. *>
const ITERATIONS = 100000;

<* Largest number of edits applied to one message. *>
const MAX_EDITS = 3;

<* xorshift64*, as in the marshalling fuzz test: fixed seed, reproducible runs. *>
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

fn usz Rng.below(&self, usz n) => n == 0 ? 0 : (usz)(self.next() % n);

fn void messages_survive_corruption() @test
{
	String[] golden = {
		message_golden_test::HELLO,
		message_golden_test::HELLO_BIG_ENDIAN,
		message_golden_test::GET_NAME_OWNER,
		message_golden_test::SIGNAL,
		message_golden_test::ERROR,
		message_golden_test::METHOD_RETURN,
	};
	Rng rng = { .state = 0xD1B54A32D192ED03 };
	for (int iteration = 0; iteration < ITERATIONS; iteration++)
	{
		@pool()
		{
			String source = testing::from_hex(golden[rng.below(golden.len)]);
			char[] bytes  = alloc::new_array(tmem, char, (sz)source.len + 4);
			for (usz i = 0; i < source.len; i++) bytes[i] = source[i];
			usz len   = source.len;
			usz edits = 1 + rng.below(MAX_EDITS);
			for (usz e = 0; e < edits && len > 0; e++)
			{
				usz at = rng.below(len);
				switch (rng.below(3))
				{
					case 0: bytes[at] = (char)rng.next();
					case 1: bytes[at] ^= (char)(1 << rng.below(8));
					default: len = at;
				}
			}
			String frame = (String)bytes[0:len];
			if (try total = message::frame_length(frame))
			{
				if (total == frame.len)
				{
					if (try m = message::parse(tmem, frame))
					{
						read_body(m);
						m.release();
					}
				}
			}
		};
	}
}

// Reads the body the way a caller would; any fault is acceptable, a trap is not.
fn void read_body(Message* m) @private
{
	if (try r = m.reader())
	{
		if (catch r.read_value(tmem))
		{
		} // a body that does not match its signature is a fault
	}
	if (m.is_error())
	{
		if (catch m.error_text())
		{
		} // an error without a string argument has no text
	}
}