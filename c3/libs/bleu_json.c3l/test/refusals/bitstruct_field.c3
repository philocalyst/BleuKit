// EXPECT: a bitstruct serialises as an object of booleans
module refusal_bitstruct;
import std::io, bleu::json;
bitstruct Mode : uint
{
	uint level : 0..1;
	bool on : 2;
}
struct Holder
{
	Mode mode;
}
fn void main()
{
	Holder value;
	io::printfn("%s", json::to_json(mem, value)!!);
}