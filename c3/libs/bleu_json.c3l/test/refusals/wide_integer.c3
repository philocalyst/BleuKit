// EXPECT: integers wider than 64 bits have no JSON form
module refusal_wide;
import std::io, bleu::json;
struct Wide
{
	int128 big;
}
fn void main()
{
	Wide value;
	io::printfn("%s", json::to_json(mem, value)!!);
}