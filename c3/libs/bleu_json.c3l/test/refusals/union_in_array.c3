// EXPECT: not plain data at value.items[].payload
module refusal_union;
import std::io, bleu::json;
union Payload
{
	int a;
	float b;
}
struct Item
{
	long id;
	Payload payload;
}
struct Holder
{
	Item[] items;
}
fn void main()
{
	Holder value;
	io::printfn("%s", json::to_json(mem, value)!!);
}