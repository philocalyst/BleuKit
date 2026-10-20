module bleu::equal_test;
import std::collections::maybe, bleu::equal, bleu::unit;

enum Mode : char
{
	A,
	B
}
struct Leaf
{
	String name;
	Level level;
	Mode mode;
	Maybe{int} extra;
}
struct Tree
{
	bool flag;
	Leaf[] leaves;
}

fn void equal_structures_compare_equal() @test
{
	Leaf[2] l1 = { { "a", unit::level(0.5f), A, maybe::value{int}(3) }, { "b", unit::level(1.0f), B, { } } };
	Leaf[2] l2 = { { "a", unit::level(0.5f), A, maybe::value{int}(3) }, { "b", unit::level(1.0f), B, { } } };
	assert(equal::deep((Tree) { true, l1[..] }, (Tree) { true, l2[..] }));
}

fn void a_difference_anywhere_is_detected() @test
{
	Leaf[1] l1 = { { "a", unit::level(0.5f), A, { } } };
	Leaf[1] l2 = { { "a", unit::level(0.5f), B, { } } };
	assert(!equal::deep((Tree) { true, l1[..] }, (Tree) { true, l2[..] }));
	Leaf[1] l3 = { { "a", unit::level(0.5f), A, maybe::value{int}(1) } };
	assert(!equal::deep((Tree) { true, l1[..] }, (Tree) { true, l3[..] }));
	assert(!equal::deep((Tree) { true, l1[..] }, (Tree) { true, { } }));
}
fn void nan_compares_equal_to_itself() @test
{
	float nan = bitcast((uint)0x7FC0_0000, float);
	test::@check(equal::deep(nan, nan), "an unchanged NaN is not a change");
	test::@check(equal::deep(0.0f, -0.0f), "zero and negative zero are equal");
}
