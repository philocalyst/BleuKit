module bleu::rt::unix_test @feat(POSIX);
import bleu::rt::unix, bleu::rt::poller, bleu::rt::wakeup, bleu::error, libc, std::core::test, std::core::string,
	std::os::posix, std::io, std::time, std::time::clock;

fn void errno_values_map_to_the_bleu_vocabulary() @test
{
	test::@check(unix::errno_to_fault((CInt)libc::Errno.ENOENT) == NOT_FOUND, "ENOENT is NOT_FOUND");
	test::@check(unix::errno_to_fault((CInt)libc::Errno.EACCES) == error::PERMISSION_DENIED, "EACCES is PERMISSION_DENIED");
	test::@check(unix::errno_to_fault((CInt)libc::Errno.EPERM) == error::PERMISSION_DENIED, "EPERM is PERMISSION_DENIED");
	test::@check(unix::errno_to_fault((CInt)libc::Errno.ECONNREFUSED) == error::DISCONNECTED, "ECONNREFUSED is DISCONNECTED");
	test::@check(unix::errno_to_fault((CInt)libc::Errno.EPIPE) == error::DISCONNECTED, "EPIPE is DISCONNECTED");
	test::@check(unix::errno_to_fault((CInt)libc::Errno.ETIMEDOUT) == TIMEOUT, "ETIMEDOUT is TIMEOUT");
	test::@check(unix::errno_to_fault((CInt)libc::Errno.EAGAIN) == error::BUSY, "EAGAIN is BUSY");
	test::@check(unix::errno_to_fault((CInt)libc::Errno.EINVAL) == error::INVALID_ARGUMENT, "EINVAL is INVALID_ARGUMENT");
	test::@check(unix::errno_to_fault((CInt)libc::Errno.ENOMEM) == error::NO_MEMORY, "ENOMEM is NO_MEMORY");
	test::@check(unix::errno_to_fault((CInt)libc::Errno.EBADF) == error::BACKEND_FAILURE, "unlisted errno is BACKEND_FAILURE");
}

fn void socket_pair_carries_bytes() @test
{
	unix::SocketPair pair = unix::socket_pair(SEQPACKET)!!;
	defer (void)pair.first.close();
	defer (void)pair.second.close();
	test::eq((usz)5, pair.first.send("hello")!!);
	char[16] buffer;
	unix::RecvResult got = pair.second.recv(buffer[..], {})!!;
	test::eq((usz)5, got.bytes);
	test::eq((usz)0, got.fds);
	test::@check((String)buffer[:5] == "hello", "the bytes arrive unchanged");
}

fn void file_descriptor_passes_through_a_socket() @test
{
	CInt[2] pipes;
	test::eq(0, posix::pipe(&pipes));
	unix::Fd read_end = { .value = pipes[0] };
	unix::Fd write_end = { .value = pipes[1] };
	defer (void)read_end.close();
	defer (void)write_end.close();

	unix::SocketPair pair = unix::socket_pair(STREAM)!!;
	defer (void)pair.first.close();
	defer (void)pair.second.close();

	unix::Fd[1] sent = { read_end };
	test::eq((usz)1, pair.first.send("x", sent[..])!!);

	unix::Fd[1] received;
	char[4] buffer;
	unix::RecvResult got = pair.second.recv(buffer[..], received[..])!!;
	test::eq((usz)1, got.fds);
	defer (void)received[0].close();
	test::@check(received[0].is_open(), "a descriptor arrived");

	// The received descriptor is the same pipe: writing one end, reading the other.
	char[4] ping = { 'p', 'i', 'n', 'g' };
	test::eq((sz)4, libc::write(write_end.raw(), &ping, 4));
	char[4] echoed;
	test::eq((sz)4, libc::read(received[0].raw(), &echoed, 4));
	test::@check((String)echoed[..] == "ping", "the passed descriptor reads the pipe");
}

fn void too_many_descriptors_are_refused() @test
{
	unix::SocketPair pair = unix::socket_pair(STREAM)!!;
	defer (void)pair.first.close();
	defer (void)pair.second.close();
	unix::Fd[17] many;
	test::@error(pair.first.send("x", many[..]), error::INVALID_ARGUMENT);
}

fn void empty_socket_reports_busy_when_non_blocking() @test
{
	unix::SocketPair pair = unix::socket_pair(STREAM)!!;
	defer (void)pair.first.close();
	defer (void)pair.second.close();
	pair.second.fd.set_nonblocking(true)!!;
	char[4] buffer;
	unix::Fd[1] none;
	test::@error(pair.second.recv(buffer[..], none[..]), error::BUSY);
}

fn void closed_peer_reports_disconnected() @test
{
	unix::SocketPair pair = unix::socket_pair(STREAM)!!;
	defer (void)pair.second.close();
	pair.first.close()!!;
	char[4] buffer;
	unix::Fd[1] none;
	test::@error(pair.second.recv(buffer[..], none[..]), error::DISCONNECTED);
}

fn void poller_reports_socket_readiness() @test
{
	unix::SocketPair pair = unix::socket_pair(SEQPACKET)!!;
	defer (void)pair.first.close();
	defer (void)pair.second.close();
	wakeup::Wakeup wake;
	wake.init()!!;
	defer wake.close();
	poller::Poller waiter;
	waiter.init(mem, &wake, 1)!!;
	defer waiter.free();
	waiter.add({ .handle = pair.second.fd.raw(), .interest = { .readable = true }, .tag = 5 })!!;
	test::@error(waiter.wait(time::ms(5)), TIMEOUT);
	pair.first.send("data")!!;
	poller::Ready[] ready = waiter.wait(time::SEC)!!;
	test::eq((sz)1, ready.len);
	test::eq((usz)5, ready[0].tag);
	test::@check(ready[0].events.readable, "the socket is readable");
}

fn void listen_connect_accept_and_identify() @test
{
	String path = string::tformat("/tmp/bleu-rt-unix-%d.sock", clock::now());
	unix::UnixSocket listener = unix::listen(path, STREAM, 4)!!;
	defer (void)listener.close();
	unix::UnixSocket client = unix::connect(path, STREAM)!!;
	defer (void)client.close();
	unix::UnixSocket server = listener.accept()!!;
	defer (void)server.close();
	client.send_all("hello server")!!;
	char[32] buffer;
	unix::Fd[1] none;
	unix::RecvResult got = server.recv(buffer[..], none[..])!!;
	test::@check((String)buffer[:got.bytes] == "hello server", "the message crosses the socket");
	unix::PeerCredentials who = server.peer_credentials()!!;
	test::@check(who.pid > 0, "the peer reports its process id");
	io::file::delete(path)!!;
}

fn void abstract_names_are_linux_only() @test
{
	String name = string::tformat("@bleu-rt-abstract-%d", clock::now());
	$if env::LINUX:
		unix::UnixSocket listener = unix::listen(name, STREAM, 1)!!;
		defer (void)listener.close();
		unix::UnixSocket client = unix::connect(name, STREAM)!!;
		defer (void)client.close();
		unix::UnixSocket server = listener.accept()!!;
		defer (void)server.close();
	$else
		test::@error(unix::connect(name, STREAM), error::UNSUPPORTED);
	$endif
}
