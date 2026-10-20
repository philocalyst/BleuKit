module bleu::json;
import std::collections::maybe;
import std::time;
import bleu::unit;

<*
 Compile gate. C3 type-checks a generic body only where it is instantiated, and
 `tools/check.sh` does not build the `@test` functions, so this function names
 one value of every kind the writer handles. It is never called; its job is to
 make `tools/check.sh bleu_core bleu_json` type-check every branch of
 `write_value`, `is_empty` and the tag handling on all six targets.
*>

constset GateFlags : uint { ONE = 1, FOUR = 4 }
enum GateKind : char { FIRST, SECOND }
bitstruct GateBits : uint { bool low : 0; bool high : 1; }
struct GateLeaf { Level level; GateKind kind; }
struct GateTree
{
	String name;
	GateKind kind;
	GateBits bits;
	GateFlags flags;
	Maybe{Level} maybe_level;
	Maybe{Duration} maybe_span;
	char[4] text;
	char[] bytes;
	GateLeaf[] leaves;
	GateLeaf[2] pair;
	uint[3] numbers;
	Gain gain;
	NanoDuration span;
	double precise;
	float ratio;
	bool flag @tag("json", "flag_on_wire");
	GateLeaf hidden @tag("json", "-");
	Maybe{long} optional_count @tag("json", "omitempty");
	String optional_name @tag("json", "omitempty");
	GateLeaf leaf @tag("json", "omitempty");
	char[4] optional_text @tag("json", "omitempty");
	GateKind optional_kind @tag("json", "omitempty");
}


fn void? gate_every_branch_of_the_writer(JsonWriter* writer, Options options) @private
{
	GateTree tree;
	write(writer, tree, options)!;
	write(writer, GateKind.SECOND, options)!;
	write(writer, (Maybe{long}){}, options)!;
	write(writer, GateFlags.FOUR, options)!;
	write(writer, (uint)1, options)!;
	write(writer, (ulong)2, options)!;
	write(writer, (ichar)-3, options)!;
}
