module bleu::compositor::io_test @feat(POSIX);
import bleu::rt::unix, bleu::error, bleu::compositor::io, bleu::compositor::wire, std::core::test, std::time;

// How long a test waits on a peer that stays silent: short, so the test is quick.
const Duration SILENT_WAIT = (Duration)50_000;

// A socket pair whose far end never writes is a compositor that stopped answering.
fn void a_silent_peer_fails_the_read_within_the_timeout() @test
{
	unix::SocketPair pair = unix::socket_pair(unix::SocketKind.STREAM)!!;
	defer (void)pair.first.close();
	defer (void)pair.second.close();
	@pool()
	{
		test::@error(io::read_to_end(&pair.first, SILENT_WAIT), error::DISCONNECTED);
	};
}

fn void a_silent_peer_fails_a_line_read_within_the_timeout() @test
{
	unix::SocketPair pair = unix::socket_pair(unix::SocketKind.STREAM)!!;
	defer (void)pair.first.close();
	defer (void)pair.second.close();
	wire::Buffer buffer;
	buffer.init(mem, 64);
	defer buffer.free();
	@pool()
	{
		test::@error(io::await_line(&pair.first, &buffer, SILENT_WAIT), error::DISCONNECTED);
	};
}

// A reply that arrives inside the timeout is still read in full.
fn void a_prompt_reply_is_read() @test
{
	unix::SocketPair pair = unix::socket_pair(unix::SocketKind.STREAM)!!;
	defer (void)pair.first.close();
	defer (void)pair.second.close();
	wire::Buffer buffer;
	buffer.init(mem, 64);
	defer buffer.free();
	pair.second.send_all("ok\n")!!;
	@pool()
	{
		String line = io::await_line(&pair.first, &buffer, (Duration)1_000_000)!!;
		test::@check(line == "ok", "the line that arrived is returned");
	};
}
