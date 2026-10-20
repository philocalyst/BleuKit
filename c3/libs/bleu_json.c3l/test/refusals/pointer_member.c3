// EXPECT: not plain data at value.inner.ptr
module refusal_pointer;
import std::io, bleu::json;
struct Inner
{
	int* ptr;
}
struct Outer
{
	Inner inner;
}
fn void main()
{
	Outer value;
	io::printfn("%s", json::to_json(mem, value)!!);
}