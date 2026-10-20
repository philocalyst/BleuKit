module bleu::windows;
import std::core::test;

// A zeroed value must not claim a connection nobody made: the zero of Connection is DISCONNECTED.
fn void a_zeroed_state_is_disconnected() @test
{
	State state = { };
	test::@check(state.connection == Connection.DISCONNECTED, "a state nobody filled in reads as disconnected");
}
