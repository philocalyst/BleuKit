module bleu::session::common_test;
import std::time, bleu::session;

fn void reached_is_inclusive() @test
{
	Duration minute = (Duration)60_000_000;
	assert(session::reached((Duration)59_999_999, minute) == false);
	assert(session::reached(minute, minute) == true);
	assert(session::reached((Duration)0, time::DURATION_ZERO) == true);
}

fn void session_type_names_map_to_their_variants() @test
{
	assert(session::session_type_of("wayland") == WAYLAND);
	assert(session::session_type_of("x11") == X11);
	assert(session::session_type_of("tty") == TTY);
	assert(session::session_type_of("unspecified") == UNSPECIFIED);
	assert(session::session_type_of("mir") == MIR);
	assert(session::session_type_of("") == UNKNOWN);
	assert(session::session_type_of("Wayland") == UNKNOWN);
}
