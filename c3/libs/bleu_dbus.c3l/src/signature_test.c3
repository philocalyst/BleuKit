module bleu::dbus::signature_test;
import bleu::dbus::signature, std::io;

fn void valid_examples() @test
{
	assert(signature::valid(""));
	assert(signature::valid("aiai"));
	assert(signature::valid("a{sv}"));
	assert(!signature::valid("aa"));
}
