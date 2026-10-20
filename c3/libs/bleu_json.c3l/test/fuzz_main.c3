// Emits random inputs and what bleu_json writes for them, one case per line, for
// check_fuzz.py to verify with python3's json module and its own UTF-8 and
// float formatting. Lines:
//   S <hex of the input bytes> <json string>
//   D <hex of the IEEE 754 binary64 bits> <json number or null>
//   F <hex of the IEEE 754 binary32 bits> <json number or null>
module fuzz_main;
import std::io, std::math, bleu::json;

const int STRING_CASES = 4000;
const int NUMBER_CASES = 4000;
const usz MAX_STRING   = 48;

// xorshift64: deterministic, so a failing line can be replayed.
ulong rng_state = 0x9E3779B97F4A7C15;

fn ulong next_random()
{
	rng_state ^= rng_state << 13;
	rng_state ^= rng_state >> 7;
	rng_state ^= rng_state << 17;
	return rng_state;
}

// Bytes drawn from the classes that break JSON writers: controls, quote,
// backslash, ASCII, UTF-8 leads and continuations, and the bytes that are never valid.
fn char random_byte()
{
	char[12] interesting = { 0x00, 0x08, 0x0C, 0x1F, '"', '\\', '/', 0x7F, 0x80, 0xBF, 0xC3, 0xF4 };
	ulong pick           = next_random();
	if (pick % 3 == 0) return interesting[pick % 12];
	return (char)(next_random() % 256);
}

fn void print_hex(char[] bytes)
{
	foreach (c : bytes)
	{
		io::printf("%02x", c);
	}
}

fn void print_strings(JsonWriter* w, DString* out)
{
	char[MAX_STRING] input;
	for (int n = 0; n < STRING_CASES; n++)
	{
		usz length = next_random() % (MAX_STRING + 1);
		for (usz i = 0; i < length; i++)
		{
			input[i] = random_byte();
		}
		out.clear();
		w.init_dstring(out);
		w.put_string((String)input[0:length])!!;
		io::printf("S ");
		print_hex(input[0:length]);
		io::printfn(" %s", out.str_view());
	}
}

fn void print_doubles(JsonWriter* w, DString* out)
{
	for (int n = 0; n < NUMBER_CASES; n++)
	{
		ulong bits   = next_random();
		double value = bitcast(bits, double);
		out.clear();
		w.init_dstring(out);
		w.put_double(value)!!;
		io::printfn("D %016x %s", bits, out.str_view());
	}
}

fn void print_floats(JsonWriter* w, DString* out)
{
	for (int n = 0; n < NUMBER_CASES; n++)
	{
		uint bits   = (uint)next_random();
		float value = bitcast(bits, float);
		out.clear();
		w.init_dstring(out);
		w.put_float(value)!!;
		io::printfn("F %08x %s", bits, out.str_view());
	}
}

fn void main()
{
	DString out;
	out.init(mem);
	JsonWriter w;
	print_strings(&w, &out);
	print_doubles(&w, &out);
	print_floats(&w, &out);
}