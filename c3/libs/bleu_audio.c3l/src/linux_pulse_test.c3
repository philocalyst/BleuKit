// The Linux backend's ownership and discovery rules, checked without a server.
// Live behaviour (refresh, stop during a reply, hostile replies) is in tests/.
module bleu::audio::linux_pulse_test @feat(LINUX);
import bleu::audio, bleu::audio::linux_pulse, bleu::error;

// The cookie path of a backend whose cookie was not found is the empty literal,
// which owns nothing: destroy must free the socket path and the backend only.
fn void destroy_skips_the_empty_cookie_path() @test
{
	linux_pulse::PulseBackend* backend = alloc::new(
		mem,
		linux_pulse::PulseBackend,
		{ .socket_path = "/tmp/bleu-audio-test".copy(mem), .cookie_path = "" }
	);
	linux_pulse::destroy(mem, backend);
}

// An explicit cookie file that does not exist fails the open with NOT_FOUND. The
// root directory stands in for the socket: discovery only checks that it exists.
fn void missing_explicit_cookie_fails_the_open() @test
{
	Options options = { .backend = Backend.PULSE, .server = "/", .cookie_file = "/nonexistent/bleu-cookie" };
	Audio*? opened  = audio::open(mem, options);
	if (catch err = opened)
	{
		assert(err == NOT_FOUND, "a missing cookie file is NOT_FOUND");
		return;
	}
	Audio* service = opened;
	service.close();
	assert(false, "a missing explicit cookie file opened the service");
}

// PULSE_SERVER names a unix socket, possibly after other addresses; a value with
// no unix address is refused rather than replaced by another server.
fn void pulse_server_must_name_a_unix_socket() @test
{
	assert(linux_pulse::unix_socket_of("unix:/run/bleu-a")!! == "/run/bleu-a", "a unix address is used");
	assert(linux_pulse::unix_socket_of(
		"tcp:example.org:4713 unix:/run/bleu-b"
	)!! == "/run/bleu-b", "the first unix address of a list is used");
	test::@error(linux_pulse::unix_socket_of("tcp:example.org:4713"), error::UNSUPPORTED);
}