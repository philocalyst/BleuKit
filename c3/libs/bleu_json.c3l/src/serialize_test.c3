module bleu::json;
import std::collections::maybe;
import std::time;
import bleu::unit;

enum Phase : char { UNKNOWN, NOT_CHARGING, FULL }
bitstruct Caps : uint { bool charge : 0; bool power : 1; }
struct Leaf { Level level; Phase phase; }
struct Sample
{
	String id;
	Phase phase;
	Caps caps;
	Maybe{Level} charge;
	Maybe{long} power;
	Duration time_to_empty;
	char[6] label;
	char[] raw;
	Leaf[] leaves;
	Leaf[2] pair;
	uint[3] numbers;
	Leaf skipped @tag("json", "-");
	Maybe{long} optional @tag("json", "omitempty");
	String note @tag("json", "omitempty");
	long count @tag("json", "omitempty");
	bool flag @tag("json", "wire_flag");
	float ratio;
	double unknown;
}

<* A sample with every field set, so the golden output shows each rule once. *>
fn Sample full_sample(Leaf[] leaves)
{
	return {
		.id = "bat-0",
		.phase = FULL,
		.caps = { .charge = true, .power = false },
		.charge = maybe::value{Level}((Level)0.5f),
		.power = maybe::value{long}(-1200),
		.time_to_empty = (Duration)3_600_000_000,
		.label = "ok",
		.raw = (char[])"\x01\x02\xFF",
		.leaves = leaves,
		.pair = { { (Level)0.25f, NOT_CHARGING }, { (Level)1.0f, UNKNOWN } },
		.numbers = { 1, 2, 3 },
		.optional = maybe::value{long}(7),
		.note = "hi",
		.count = 4,
		.flag = true,
		.ratio = 0.7f,
		.unknown = 0.0 / 0.0,
	};
}

fn void default_options_golden() @test
{
	Leaf[1] leaves = { { (Level)0.5f, FULL } };
	Sample s = full_sample(leaves[..]);
	String json = to_json(mem, s)!!;
	defer json.free(mem);
	assert(json == `{"id":"bat-0","phase":"full","caps":{"charge":true,"power":false},"charge":0.5,"power":-1200,"time_to_empty":3600000000,"label":"ok","raw":"AQL/","leaves":[{"level":0.5,"phase":"full"}],"pair":[{"level":0.25,"phase":"not_charging"},{"level":1,"phase":"unknown"}],"numbers":[1,2,3],"optional":7,"note":"hi","count":4,"wire_flag":true,"ratio":0.7,"unknown":null}`);
}

fn void camel_case_and_upper_enums_golden() @test
{
	Sample s = { .phase = NOT_CHARGING, .time_to_empty = (Duration)5, .unknown = 1.5 };
	Options o = { .enum_style = UPPER_SNAKE, .key_style = CAMEL_CASE };
	String json = to_json(mem, s, o)!!;
	defer json.free(mem);
	assert(json.starts_with(`{"id":"","phase":"NOT_CHARGING","caps":{"charge":false,"power":false},"charge":null,"power":null,"timeToEmpty":5,"label":"","raw":"","leaves":[],"pair":[{"level":0,"phase":"UNKNOWN"},{"level":0,"phase":"UNKNOWN"}],"numbers":[0,0,0],"wire_flag":false,"ratio":0,"unknown":1.5}`));
}

fn void omitempty_drops_only_empty_members() @test
{
	Sample s = { .phase = UNKNOWN };
	String json = to_json(mem, s)!!;
	defer json.free(mem);
	// `optional`, `note` and `count` are empty and tagged omitempty; `flag` is a rename, never omitted.
	assert(json == `{"id":"","phase":"unknown","caps":{"charge":false,"power":false},"charge":null,"power":null,"time_to_empty":0,"label":"","raw":"","leaves":[],"pair":[{"level":0,"phase":"unknown"},{"level":0,"phase":"unknown"}],"numbers":[0,0,0],"wire_flag":false,"ratio":0,"unknown":0}`);
}

fn void enum_names_and_bitstructs() @test
{
	DString out;
	out.init(mem);
	defer out.free();
	JsonWriter w;
	w.init_dstring(&out);
	write(&w, (Caps){ .charge = true, .power = true })!!;
	assert(out.str_view() == `{"charge":true,"power":true}`);
	out.clear();
	w.init_dstring(&out, 0);
	write(&w, Phase.FULL)!!;
	assert(out.str_view() == `"full"`);
}

fn void text_arrays_stop_at_nul_and_bytes_are_base64() @test
{
	char[4] text = { 'a', 0, 'b', 0 };
	char[] bytes = (char[])"foobar";
	DString out;
	out.init(mem);
	defer out.free();
	JsonWriter w;
	w.init_dstring(&out);
	w.begin_array()!!;
	write(&w, text)!!;
	write(&w, bytes)!!;
	w.end_array()!!;
	assert(out.str_view() == `["a","Zm9vYmFy"]`);
}

alias OptionalLong = Maybe{long};

fn void maybe_empty_is_null_and_nests() @test
{
	Maybe{Leaf} none;
	Maybe{OptionalLong} nested = maybe::value{OptionalLong}({});
	assert(to_json(mem, none)!! == "null");
	assert(to_json(mem, nested)!! == "null");
	assert(to_json(mem, maybe::value{OptionalLong}(maybe::value{long}(3)))!! == "3");
}

fn void durations_are_integers_in_their_unit() @test
{
	NanoDuration nanos = (NanoDuration)1_500;
	assert(to_json(mem, (Duration)1_500_000)!! == "1500000");
	assert(to_json(mem, nanos)!! == "1500");
}

struct Renamed
{
	long time_to_empty @tag("json", "timeToEmpty");
	long plain_name;
}

fn void tagged_names_are_exact_wire_names() @test
{
	Renamed r = { .time_to_empty = 2, .plain_name = 3 };
	Options o = { .key_style = CAMEL_CASE };
	assert(to_json(mem, r, o)!! == `{"timeToEmpty":2,"plainName":3}`);
}

fn void to_json_reports_nothing_it_cannot_write() @test
{
	// Nothing in this module is refused at run time: the refusals are compile errors (see README).
	assert(to_json(mem, (uint)7)!! == "7");
}
