module bleu::rt::unix_test @feat(POSIX);
import bleu::rt::unix, bleu::rt::poller, bleu::rt::wakeup, bleu::error, libc, std::core::test, std::core::string, std::os::posix, std::io, std::time, std::time::clock;

fn void errno_values_map_to_the_bleu_vocabulary() @test
{
	test::@check(unix::errno_to_fault((CInt)libc::Errno.ENOENT) == NOT_FOUND, "ENOENT is NOT_FOUND");
	test::@check(
		unix::errno_to_fault((CInt)libc::Errno.EACCES) == error::PERMISSION_DENIED,
		"EACCES is PERMISSION_DENIED"
	);
	test::@check(
		unix::errno_to_fault((CInt)libc::Errno.EPERM) == error::PERMISSION_DENIED,
		"EPERM is PERMISSION_DENIED"
	);
	test::@check(
		unix::errno_to_fault((CInt)libc::Errno.ECONNREFUSED) == error::DISCONNECTED,
		"ECONNREFUSED is DISCONNECTED"
	);
	test::@check(unix::errno_to_fault((CInt)libc::Errno.EPIPE) == error::DISCONNECTED, "EPIPE is DISCONNECTED");
	test::@check(unix::errno_to_fault((CInt)libc::Errno.ETIMEDOUT) == TIMEOUT, "ETIMEDOUT is TIMEOUT");
	test::@check(unix::errno_to_fault((CInt)libc::Errno.EAGAIN) == error::BUSY, "EAGAIN is BUSY");
	test::@check(
		unix::errno_to_fault((CInt)libc::Errno.EINVAL) == error::INVALID_ARGUMENT,
		"EINVAL is INVALID_ARGUMENT"
	);
	test::@check(unix::errno_to_fault((CInt)libc::Errno.ENOMEM) == error::NO_MEMORY, "ENOMEM is NO_MEMORY");
	test::@check(
		unix::errno_to_fault((CInt)libc::Errno.EBADF) == error::BACKEND_FAILURE,
		"unlisted errno is BACKEND_FAILURE"
	);
}

fn void socket_pair_carries_bytes() @test
{
	unix::SocketPair pair = unix::socket_pair(SEQPACKET)!!;
	defer (void)pair.first.close();
	defer (void)pair.second.close();
	test::eq((usz)5, pair.first.send("hello")!!);
	char[16] buffer;
	unix::RecvResult got = pair.second.recv(buffer[..], { })!!;
	test::eq((usz)5, got.bytes);
	test::eq((usz)0, got.fds);
	test::@check((String)buffer[:5] == "hello", "the bytes arrive unchanged");
}

fn void file_descriptor_passes_through_a_socket() @test
{
	CInt[2] pipes;
	test::eq(0, posix::pipe(&pipes));
	unix::Fd read_end  = { .value = pipes[0] };
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
	String path               = string::tformat("/tmp/bleu-rt-unix-%d.sock", clock::now());
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
fn void zero_length_seqpacket_message_is_a_message_not_end_of_file() @test
{
	unix::SocketPair pair = unix::socket_pair(SEQPACKET)!!;
	defer (void)pair.second.close();
	unix::Fd[1] none;
	test::eq((usz)0, pair.first.send("", none[..])!!);
	char[4] buffer;
	unix::RecvResult empty = pair.second.recv(buffer[..], none[..])!!;
	test::eq((usz)0, empty.bytes);
	// The peer is still connected, so it can keep sending.
	test::eq((usz)2, pair.first.send("ok")!!);
	unix::RecvResult next = pair.second.recv(buffer[..], none[..])!!;
	test::eq((usz)2, next.bytes);
	// Once the peer has closed, the zero-byte reading is end of file.
	(void)pair.first.close();
	test::@error(pair.second.recv(buffer[..], none[..]), error::DISCONNECTED);
}

fn void descriptors_without_data_are_refused() @test
{
	unix::SocketPair pair = unix::socket_pair(STREAM)!!;
	defer (void)pair.first.close();
	defer (void)pair.second.close();
	CInt[2] pipes;
	test::eq(0, posix::pipe(&pipes));
	unix::Fd[1] passed = { { .value = pipes[0] } };
	defer (void)passed[0].close();
	defer (void)(unix::Fd){ .value = pipes[1] }.close();
	test::@error(pair.first.send("", passed[..]), error::INVALID_ARGUMENT);
	test::@error(pair.first.send_all("", passed[..]), error::INVALID_ARGUMENT);
}

fn void an_empty_receive_buffer_is_refused() @test
{
	unix::SocketPair pair = unix::socket_pair(STREAM)!!;
	defer (void)pair.first.close();
	defer (void)pair.second.close();
	char[1] unused;
	unix::Fd[1] none;
	test::@error(pair.second.recv(unused[..0], none[..]), error::INVALID_ARGUMENT);
}

fn void excess_descriptors_are_refused_and_closed() @test
{
	unix::SocketPair pair = unix::socket_pair(STREAM)!!;
	defer (void)pair.first.close();
	defer (void)pair.second.close();
	CInt[2] pipes;
	test::eq(0, posix::pipe(&pipes));
	defer (void)(unix::Fd){ .value = pipes[0] }.close();
	defer (void)(unix::Fd){ .value = pipes[1] }.close();
	unix::Fd[3] sent = { { .value = pipes[0] }, { .value = pipes[0] }, { .value = pipes[0] } };
	// The kernel duplicates each descriptor into the message, so three sends of one pipe end are fine.
	test::eq((usz)1, pair.first.send("x", sent[..])!!);
	unix::Fd[2] room;
	char[4] buffer;
	test::@error(pair.second.recv(buffer[..], room[..]), error::PROTOCOL);
	// Whatever did fit was closed again on the error path.
	test::@check(!room[0].is_open() && !room[1].is_open(), "descriptors of a refused message are closed");
}

fn void truncated_message_is_refused_and_its_descriptor_closed() @test
{
	unix::SocketPair pair = unix::socket_pair(SEQPACKET)!!;
	defer (void)pair.first.close();
	defer (void)pair.second.close();
	CInt[2] pipes;
	test::eq(0, posix::pipe(&pipes));
	defer (void)(unix::Fd){ .value = pipes[0] }.close();
	defer (void)(unix::Fd){ .value = pipes[1] }.close();
	unix::Fd[1] sent = { { .value = pipes[0] } };
	test::eq((usz)10, pair.first.send("0123456789", sent[..])!!);
	unix::Fd[1] received;
	char[4] buffer;
	test::@error(pair.second.recv(buffer[..], received[..]), error::PROTOCOL);
	test::@check(!received[0].is_open(), "the descriptor of a truncated message is closed");
}

fn void control_data_truncation_is_a_protocol_error() @test
{
	// 100 descriptors need about 420 bytes of control data; the receiver's control buffer
	// holds 256, so the kernel truncates the control data and sets MSG_CTRUNC.
	const usz PASSED = 100;
	unix::SocketPair pair = unix::socket_pair(SEQPACKET)!!;
	defer (void)pair.first.close();
	defer (void)pair.second.close();
	CInt[2] pipes;
	test::eq(0, posix::pipe(&pipes));
	defer (void)(unix::Fd){ .value = pipes[0] }.close();
	defer (void)(unix::Fd){ .value = pipes[1] }.close();
	char[512] control;
	unix::CmsgHdr* header = (unix::CmsgHdr*)&control;
	usz data_len    = PASSED * CInt::size;
	header.set_rights(data_len);
	CInt* values = (CInt*)(&control[0] + unix::cmsg_align(unix::CMSG_HEADER_SIZE));
	for (usz i = 0; i < PASSED; i++) values[i] = pipes[0];
	char[1] data = { 'x' };
	unix::IoVec iov = { .base = &data, .len = 1 };
	unix::MsgHdr msg;
	msg.attach(&iov, 1, &control, unix::cmsg_align(unix::CMSG_HEADER_SIZE) + data_len);
	test::eq((sz)1, unix::sys_sendmsg(pair.first.fd.raw(), &msg, 0));
	unix::Fd[16] received;
	char[4] buffer;
	test::@error(pair.second.recv(buffer[..], received[..]), error::PROTOCOL);
}
