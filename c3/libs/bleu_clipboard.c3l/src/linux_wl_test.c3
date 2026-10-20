<*
 The Wayland session against the in-process compositor stand-in, `bleu::wl::testing::MockServer`:
 the session on the test thread, a scenario on a second thread that plays the compositor over
 a socket pair. Covers a copy from another application (kept in the history), a concealed copy
 (never read), our own source (served on `send`, released on `cancelled`), the size cap on a
 capture, and a fetch of a live offer through an operation.
*>
module bleu::clipboard::linux_wl @feat(LINUX);
import bleu::clipboard, bleu::operation, bleu::rt, bleu::rt::foreign, bleu::rt::unix, bleu::rt::wakeup, bleu::wl, bleu::wl::display, bleu::wl::testing, bleu::wl::wire, bleu::wl::proto::wayland, bleu::wl::proto::ext_data_control, std::core::test, std::core::mem, std::thread, std::time;

// pipe(2): the scenarios make the pipes the compositor writes into.
extern fn CInt sys_pipe(CInt* fds) @cname("pipe");

// Object ids the compositor gives its own objects (wayland.xml: server ids start at 0xff000000).
const uint SERVER_OFFER = 0xFF000001;
const uint SERVER_ECHO  = 0xFF000002;
const Duration TICK     = (Duration)20_000;
const usz TEST_PAYLOAD  = 1024;

// Fails the scenario thread with a message when a scenario sees something unexpected.
fn void expect(bool ok, String what)
{
	if (!ok) unreachable(what);
}

// Receive the next request and check its object and opcode.
fn testing::Message expect_request(testing::MockServer* s, uint object, ushort opcode)
{
	testing::Message message = s.receive()!!;
	expect(message.object == object && message.opcode == opcode, "unexpected request");
	return message;
}

// Advertise one global from the registry.
fn void send_global(testing::MockServer* s, uint registry, uint name, String interface_name, uint version)
{
	wire::Writer w;
	w.begin(registry, 0);
	w.put_uint(name)!!;
	w.put_string(interface_name)!!;
	w.put_uint(version)!!;
	s.send(&w)!!;
}

// Answer a sync request with `done`, then release its id.
fn void answer_sync(testing::MockServer* s, uint callback)
{
	wire::Writer done;
	done.begin(callback, 0);
	done.put_uint(1)!!;
	s.send(&done)!!;
	wire::Writer released;
	released.begin(display::DISPLAY_ID, 1);
	released.put_uint(callback)!!;
	s.send(&released)!!;
}

// Bind request from the client: checks the global, the interface and the version, returns the new id.
fn uint expect_bind(testing::MockServer* s, uint registry, uint name, String interface_name, uint version)
{
	testing::Message bind = expect_request(s, registry, 0);
	wire::Reader r        = s.reader(bind);
	expect(r.get_uint()!! == name, "bind of the wrong global");
	expect(r.get_string()!! == interface_name, "bind of the wrong interface");
	expect(r.get_uint()!! == version, "bind at the wrong version");
	return r.get_new_id()!!;
}

// What the scenarios need to talk to the device the session made.
struct Setup
{
	uint manager;
	uint device;
}

// Play the compositor's side of connecting: globals, the sync, the binds, and the device.
fn Setup serve_device(testing::MockServer* s)
{
	testing::Message get = expect_request(s, display::DISPLAY_ID, 1);
	uint registry        = s.reader(get).get_new_id()!!;
	send_global(s, registry, 4, "wl_seat", 7);
	send_global(s, registry, 6, "ext_data_control_manager_v1", 1);
	testing::Message sync = expect_request(s, display::DISPLAY_ID, 0);
	answer_sync(s, s.reader(sync).get_new_id()!!);
	// The session binds the manager first (ext-data-control is preferred), then the seat.
	uint manager            = expect_bind(s, registry, 6, "ext_data_control_manager_v1", 1);
	uint seat               = expect_bind(s, registry, 4, "wl_seat", 7);
	testing::Message device = expect_request(s, manager, 1);
	wire::Reader r          = s.reader(device);
	uint id                 = r.get_new_id()!!;
	expect(r.get_object()!! == seat, "device for the wrong seat");
	return { .manager = manager, .device = id };
}

// The device announces an offer with `types`, then makes it the clipboard.
fn void offer_selection(testing::MockServer* s, uint device, uint offer, String[] types)
{
	wire::Writer announce;
	announce.begin(device, 0);
	announce.put_new_id(offer)!!;
	s.send(&announce)!!;
	foreach (mime : types)
	{
		wire::Writer w;
		w.begin(offer, 0);
		w.put_string(mime)!!;
		s.send(&w)!!;
	}
	wire::Writer selection;
	selection.begin(device, 1);
	selection.put_object(offer)!!;
	s.send(&selection)!!;
}

// A copy by another application: its text is read. Nothing else is requested.
fn int copy_scenario(void* arg)
{
	foreign::@foreign_entry()
	{
		testing::MockServer* s = (testing::MockServer*)arg;
		Setup setup            = serve_device(s);
		offer_selection(s, setup.device, SERVER_OFFER, { "text/plain;charset=utf-8" });
		serve_text(s, "hello");
	};
	return 0;
}

// A copy by another application with an image as well: the text is read, and the image is for a fetch.
fn int image_copy_scenario(void* arg)
{
	foreign::@foreign_entry()
	{
		testing::MockServer* s = (testing::MockServer*)arg;
		Setup setup            = serve_device(s);
		offer_selection(s, setup.device, SERVER_OFFER, { "text/plain;charset=utf-8", "image/png" });
		serve_text(s, "hello");
		testing::Message image = expect_request(s, SERVER_OFFER, 0);
		wire::Reader ir        = s.reader(image);
		expect(ir.get_string()!! == "image/png", "the image was not requested");
		rt::Native image_fd = ir.get_fd()!!;
		char[] png          = "PNG";
		expect(sys_write(image_fd, png.ptr, (usz)png.len) == 3, "could not write the image");
		display::native_close(image_fd);
	};
	return 0;
}

// Answer the next receive, which must ask for the UTF-8 text, with `text`.
fn void serve_text(testing::MockServer* s, String text)
{
	testing::Message receive = expect_request(s, SERVER_OFFER, 0);
	wire::Reader r           = s.reader(receive);
	expect(r.get_string()!! == "text/plain;charset=utf-8", "the text was not requested");
	rt::Native fd = r.get_fd()!!;
	expect(sys_write(fd, text.ptr, text.len) == text.len, "could not write the copy");
	display::native_close(fd);
}

// A concealed copy: the compositor offers the KDE password hint, and nothing may be read.
fn int concealed_scenario(void* arg)
{
	foreign::@foreign_entry()
	{
		testing::MockServer* s = (testing::MockServer*)arg;
		Setup setup            = serve_device(s);
		offer_selection(s, setup.device, SERVER_OFFER, { "text/plain", "x-kde-passwordManagerHint" });
	};
	return 0;
}

// Our own copy: the session creates a source, offers, selects it, serves a `send`, and releases it.
fn int own_scenario(void* arg)
{
	foreign::@foreign_entry()
	{
		testing::MockServer* s  = (testing::MockServer*)arg;
		Setup setup             = serve_device(s);
		testing::Message create = expect_request(s, setup.manager, 0);
		uint source             = s.reader(create).get_new_id()!!;
		testing::Message offer  = expect_request(s, source, 0);
		expect(s.reader(offer).get_string()!! == "text/plain;charset=utf-8", "the source offered the wrong type");
		testing::Message set = expect_request(s, setup.device, 0);
		expect(s.reader(set).get_object()!! == source, "a different source was selected");
		// The compositor announces our own offer back; the session must not read it.
		offer_selection(s, setup.device, SERVER_ECHO, { "text/plain;charset=utf-8" });
		CInt[2] pipe_fds;
		expect(sys_pipe(&pipe_fds) == 0, "pipe");
		wire::Writer send;
		send.begin(source, 0);
		send.put_string("text/plain;charset=utf-8")!!;
		send.put_fd(pipe_fds[1])!!;
		s.send(&send)!!;
		display::native_close(pipe_fds[1]);
		char[16] received;
		usz total = 0;
		while (total < received.len)
		{
			sz got = sys_read(pipe_fds[0], &received[total], received.len - total);
			if (got <= 0) break;
			total += (usz)got;
		}
		display::native_close(pipe_fds[0]);
		expect((String)received[0:total] == "copied", "the served bytes were wrong");
		// The session destroys the echoed offer (it is ours), then clears the selection.
		expect_request(s, SERVER_ECHO, 1);
		testing::Message clear = expect_request(s, setup.device, 0);
		expect(s.reader(clear).get_object()!! == 0, "clear did not send a null source");
		wire::Writer cancelled;
		cancelled.begin(source, 1);
		s.send(&cancelled)!!;
	};
	return 0;
}

// A copy by another application whose text the capture may not read: 16 bytes, over an 8-byte cap.
fn int oversize_scenario(void* arg)
{
	foreign::@foreign_entry()
	{
		testing::MockServer* s = (testing::MockServer*)arg;
		Setup setup            = serve_device(s);
		offer_selection(s, setup.device, SERVER_OFFER, { "text/plain" });
		testing::Message text = expect_request(s, SERVER_OFFER, 0);
		rt::Native fd         = s.reader(text).get_fd()!!;
		char[] bytes          = "0123456789ABCDEF";
		expect(sys_write(fd, bytes.ptr, (usz)bytes.len) == 16, "could not write the copy");
		display::native_close(fd);
	};
	return 0;
}

// Run `session` for a few ticks, so that events, transfers and commands are served.
fn void pump_ticks(WlSession* session, int ticks)
{
	for (int i = 0; i < ticks; i++) session.pump(TICK)!!;
}

// Whether any pipe transfer is still in flight.
fn bool transfers_busy(WlSession* session)
{
	for (usz i = 0; i < MAX_TRANSFERS; i++)
	{
		if (session.transfers[i].active) return true;
	}
	return false;
}

// Give the server its end of a new socket pair, and return the client's end. Attach before the scenario starts.
fn rt::Native attach_pair(testing::MockServer* server)
{
	unix::SocketPair pair = unix::socket_pair(unix::SocketKind.STREAM)!!;
	server.attach(pair.second);
	return pair.first.fd.release();
}

fn void copy_from_another_application_is_kept_in_history() @test
{
	testing::MockServer server;
	Board board;
	board.init(mem, clipboard::DEFAULT_HISTORY_ITEMS, clipboard::DEFAULT_HISTORY_BYTES, TEST_PAYLOAD);
	WlSession session;
	session.init(mem, &board, clipboard::DEFAULT_TRANSFER_TIMEOUT);
	wakeup::Wakeup wakeup;
	wakeup.init()!!;
	defer wakeup.close();
	session.wakeup = &wakeup;
	rt::Native client_fd = attach_pair(&server);
	Thread t;
	t.create(&copy_scenario, &server)!!;
	session.connect_fd(client_fd)!!;
	defer
	{
		session.free();
		board.free();
		server.close();
	}
	pump_ticks(&session, 25);
	test::eq(board.items.len(), (sz)1);
	test::eq(board.lane(Slot.CLIPBOARD).preview, "hello");
	test::eq(board.lane(Slot.CLIPBOARD).size, (usz)5);
	test::@check(session.lane_offers[Slot.CLIPBOARD.ordinal] != null);
	t.join()!!;
}

fn void concealed_copy_is_never_read() @test
{
	testing::MockServer server;
	Board board;
	board.init(mem, clipboard::DEFAULT_HISTORY_ITEMS, clipboard::DEFAULT_HISTORY_BYTES, TEST_PAYLOAD);
	WlSession session;
	session.init(mem, &board, clipboard::DEFAULT_TRANSFER_TIMEOUT);
	wakeup::Wakeup wakeup;
	wakeup.init()!!;
	defer wakeup.close();
	session.wakeup = &wakeup;
	rt::Native client_fd = attach_pair(&server);
	Thread t;
	t.create(&concealed_scenario, &server)!!;
	session.connect_fd(client_fd)!!;
	defer
	{
		session.free();
		board.free();
		server.close();
	}
	pump_ticks(&session, 10);
	test::eq(board.lane(Slot.CLIPBOARD).privacy, Privacy.CONCEALED);
	test::@check(!transfers_busy(&session));
	test::eq(board.items.len(), (sz)0);
	t.join()!!;
}

fn void our_own_selection_serves_its_bytes_and_is_released() @test
{
	testing::MockServer server;
	Board board;
	board.init(mem, clipboard::DEFAULT_HISTORY_ITEMS, clipboard::DEFAULT_HISTORY_BYTES, TEST_PAYLOAD);
	WlSession session;
	session.init(mem, &board, clipboard::DEFAULT_TRANSFER_TIMEOUT);
	wakeup::Wakeup wakeup;
	wakeup.init()!!;
	defer wakeup.close();
	session.wakeup = &wakeup;
	rt::Native client_fd = attach_pair(&server);
	Thread t;
	t.create(&own_scenario, &server)!!;
	session.connect_fd(client_fd)!!;
	defer
	{
		session.free();
		board.free();
		server.close();
	}
	Representation[1] offered = { { .mime = "text/plain;charset=utf-8", .bytes = (char[])"copied" } };
	ulong seq                 = session.own(Slot.CLIPBOARD, offered[..])!!;
	pump_ticks(&session, 25);
	test::@check(board.lane(Slot.CLIPBOARD).owned);
	test::eq(board.lane(Slot.CLIPBOARD).seq, seq);
	test::eq(board.items.len(), (sz)1);
	test::@check(session.clear(Slot.CLIPBOARD)!!);
	pump_ticks(&session, 25);
	test::eq(session.sources.len(), (sz)0);
	t.join()!!;
}

fn void a_capture_over_the_size_cap_is_dropped() @test
{
	testing::MockServer server;
	Board board;
	board.init(mem, clipboard::DEFAULT_HISTORY_ITEMS, clipboard::DEFAULT_HISTORY_BYTES, 8);
	WlSession session;
	session.init(mem, &board, clipboard::DEFAULT_TRANSFER_TIMEOUT);
	wakeup::Wakeup wakeup;
	wakeup.init()!!;
	defer wakeup.close();
	session.wakeup = &wakeup;
	rt::Native client_fd = attach_pair(&server);
	Thread t;
	t.create(&oversize_scenario, &server)!!;
	session.connect_fd(client_fd)!!;
	defer
	{
		session.free();
		board.free();
		server.close();
	}
	pump_ticks(&session, 25);
	test::@check(!transfers_busy(&session));
	test::eq(board.lane(Slot.CLIPBOARD).size, (usz)0);
	test::eq(board.items.len(), (sz)0);
	t.join()!!;
}

fn void a_fetch_reads_the_chosen_type_of_the_live_offer() @test
{
	testing::MockServer server;
	Board board;
	board.init(mem, clipboard::DEFAULT_HISTORY_ITEMS, clipboard::DEFAULT_HISTORY_BYTES, TEST_PAYLOAD);
	WlSession session;
	session.init(mem, &board, clipboard::DEFAULT_TRANSFER_TIMEOUT);
	wakeup::Wakeup wakeup;
	wakeup.init()!!;
	defer wakeup.close();
	session.wakeup = &wakeup;
	rt::Native client_fd = attach_pair(&server);
	Thread t;
	t.create(&image_copy_scenario, &server)!!;
	session.connect_fd(client_fd)!!;
	defer
	{
		session.free();
		board.free();
		server.close();
	}
	pump_ticks(&session, 25);
	Operation{Bytes}* op = operation::begin{Bytes}(mem);
	defer op.release();
	ulong seq = board.lane(Slot.CLIPBOARD).seq;
	session.start_receive(session.lane_offers[Slot.CLIPBOARD.ordinal], Slot.CLIPBOARD, seq, "image/png", op.retain())!!;
	pump_ticks(&session, 25);
	Bytes image = op.wait((Duration)1_000_000)!!;
	test::eq((String)image, "PNG");
	t.join()!!;
}