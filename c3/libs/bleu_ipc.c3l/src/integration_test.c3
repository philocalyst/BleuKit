// In-process tests: a real server on a real socket, with the C3 client and raw
// sockets as peers. Each test owns its server and its socket path.
module bleu::ipc::integration_test @feat(POSIX);
import bleu::ipc, bleu::ipc::client, bleu::ipc::wire, bleu::error, bleu::rt::unix, bleu::rt::foreign, std::core::test, std::thread, std::time, std::os::posix, std::atomic, std::io;

<* How long a test waits for something that should happen promptly. *>
const Duration WAIT = (Duration)5_000_000;

<* How long a test waits to confirm that nothing else arrives. *>
const Duration QUIET = (Duration)200_000;

<* Name of the app in the test configurations. *>
const String APP = "bleu-test";

<* A heap copy of a string the test releases with `release`. *>
fn String heap(String text)
{
	return text.copy(mem);
}

<* Release a heap copy made by `heap`, `Client` or the server. *>
fn void release(String text)
{
	alloc::free(mem, text.ptr);
}

<* A socket path unique to this test process and to `tag`. Fits the 108-byte limit. *>
fn String socket_path(String tag)
{
	String path;
	@pool()
	{
		path = string::tformat("/tmp/bleu-ipc-%d-%s.sock", posix::getpid(), tag).copy(mem);
	};
	// A socket file left by an earlier run that died would make bind fail.
	if (catch io::path::delete((io::path::Path)path))
	{
	}
	return path;
}

<* Consume lines until one equals `expected`, failing on anything else in between. *>
fn void expect_line(client::Client* c, String expected)
{
	String line = c.next_line(WAIT)!!;
	defer release(line);
	test::eq(line, expected);
}

<* True when no frame arrives within QUIET. *>
fn bool quiet(client::Client* c)
{
	String? line = c.next_line(QUIET);
	if (catch err = line) return err == TIMEOUT;
	release(line);
	return false;
}

<* Send text on a raw socket. *>
fn void send_text(unix::UnixSocket* socket, String text)
{
	socket.send_all((char[])text)!!;
}

// -- Handlers -----------------------------------------------------------------

<* Shared by the handlers of one test. *>
struct Probe
{
	Atomic{bool} second_refused;
	Atomic{bool} second_checked;
}

fn void answer_ok(void* context, ipc::Call* call)
{
	call.respond_raw("{\"ok\":true}");
}

fn void answer_twice(void* context, ipc::Call* call)
{
	Probe* probe = (Probe*)context;
	call.respond_raw("{\"first\":true}");
	bool refused = false;
	if (catch err = call.respond_raw("{\"second\":true}")) refused = err == error::INVALID_STATE;
	probe.second_refused.store(refused);
	probe.second_checked.store(true);
}

fn void answer_nothing(void* context, ipc::Call* call)
{
}

<* A deferred request, finished on a thread of its own. *>
struct Later
{
	ipc::Deferred deferred;
}

fn void answer_later(void* context, ipc::Call* call)
{
	Later* later = alloc::new(mem, Later);
	later.deferred = call.defer_reply();
	Thread worker;
	worker.create(&complete_later, later)!!;
	worker.detach();
}

fn int complete_later(void* arg)
{
	foreign::@foreign_entry()
	{
		Later* later = (Later*)arg;
		thread::sleep_ms(20);
		later.deferred.respond_raw("{\"late\":true}");
		alloc::free(mem, later);
	};
	return 0;
}

// -- Server set-up ------------------------------------------------------------

<* A server with the test's app name, api version and a generous write stall. *>
fn ipc::Config config_for(String path)
{
	return { .app_name = APP, .api_version = 38, .socket_path = path };
}

// -- Tests --------------------------------------------------------------------

fn void handshake_and_ping_round_trip() @test
{
	String path = socket_path("ping");
	defer release(path);
	ipc::Server server;
	server.init(mem, config_for(path))!!;
	defer server.free();
	server.start()!!;
	defer server.stop();

	client::Client c;
	c.connect(mem, path, WAIT)!!;
	defer c.free();
	test::eq(c.api_version, 38);
	String reply = c.request("ping", "null", WAIT)!!;
	defer release(reply);
	test::eq(reply, "{\"id\":1,\"result\":{\"pong\":true}}");
}

fn void unknown_methods_and_bad_lines_get_error_replies() @test
{
	String path = socket_path("errors");
	defer release(path);
	ipc::Server server;
	server.init(mem, config_for(path))!!;
	defer server.free();
	server.start()!!;
	defer server.stop();

	client::Client c;
	c.connect(mem, path, WAIT)!!;
	defer c.free();
	String unknown = c.request("nope", "null", WAIT)!!;
	defer release(unknown);
	test::eq(unknown, "{\"id\":1,\"error\":\"unknown method: nope\"}");

	// A line that is not JSON gets an error reply with no id, as dankgo sends it, and
	// the connection stays usable.
	unix::UnixSocket raw = unix::connect(path, unix::SocketKind.STREAM)!!;
	defer raw.close();
	String handshake = read_raw_line(&raw);
	release(handshake);
	send_text(&raw, "this is not json\n");
	String bad = read_raw_line(&raw);
	defer release(bad);
	test::eq(bad, "{\"error\":\"invalid json: malformed JSON\"}");
}

fn void a_request_with_a_non_object_params_is_refused() @test
{
	String path = socket_path("params");
	defer release(path);
	ipc::Server server;
	server.init(mem, config_for(path))!!;
	defer server.free();
	server.register_method("ok", &answer_ok, null)!!;
	server.start()!!;
	defer server.stop();

	unix::UnixSocket raw = unix::connect(path, unix::SocketKind.STREAM)!!;
	defer raw.close();
	String handshake = read_raw_line(&raw);
	release(handshake);
	send_text(&raw, "{\"id\":4,\"method\":\"ok\",\"params\":[1,2]}\n");
	String refused = read_raw_line(&raw);
	defer release(refused);
	test::eq(refused, "{\"error\":\"invalid json: params must be an object\"}");
}

fn void handlers_answer_once_and_a_second_answer_is_refused() @test
{
	String path = socket_path("once");
	defer release(path);
	Probe probe;
	probe.second_refused.store(false);
	probe.second_checked.store(false);
	ipc::Server server;
	server.init(mem, config_for(path))!!;
	defer server.free();
	server.register_method("twice", &answer_twice, &probe)!!;
	server.start()!!;
	defer server.stop();

	client::Client c;
	c.connect(mem, path, WAIT)!!;
	defer c.free();
	String reply = c.request("twice", "{}", WAIT)!!;
	defer release(reply);
	test::eq(reply, "{\"id\":1,\"result\":{\"first\":true}}");
	// The second answer is checked on the handler thread; wait for it to report.
	for (int i = 0; i < 500 && !probe.second_checked.load(); i++) thread::sleep_ms(10);
	test::@check(probe.second_refused.load());
}

fn void a_handler_that_returns_unanswered_gets_an_error() @test
{
	String path = socket_path("silent");
	defer release(path);
	ipc::Server server;
	server.init(mem, config_for(path))!!;
	defer server.free();
	server.register_method("silent", &answer_nothing, null)!!;
	server.start()!!;
	defer server.stop();

	client::Client c;
	c.connect(mem, path, WAIT)!!;
	defer c.free();
	String reply = c.request("silent", "null", WAIT)!!;
	defer release(reply);
	test::eq(reply, "{\"id\":1,\"error\":\"handler returned without a response\"}");
}

fn void a_deferred_reply_completes_from_another_thread() @test
{
	String path = socket_path("defer");
	defer release(path);
	ipc::Server server;
	server.init(mem, config_for(path))!!;
	defer server.free();
	server.register_method("later", &answer_later, null)!!;
	server.start()!!;
	defer server.stop();

	client::Client c;
	c.connect(mem, path, WAIT)!!;
	defer c.free();
	String reply = c.request("later", "null", WAIT)!!;
	defer release(reply);
	test::eq(reply, "{\"id\":1,\"result\":{\"late\":true}}");
}

fn void a_snapshot_published_before_start_is_the_first_state_a_subscriber_sees() @test
{
	String path = socket_path("snapshot");
	defer release(path);
	ipc::Server server;
	server.init(mem, config_for(path))!!;
	defer server.free();
	ipc::Topic* network = server.register_topic("network")!!;
	network.publish("{\"wifi\":false}")!!;
	server.start()!!;
	defer server.stop();

	client::Client c;
	c.connect(mem, path, WAIT)!!;
	defer c.free();
	// The subscribe is this client's first request, so its id is 1.
	long id = c.subscribe({ "network" }, WAIT)!!;
	test::eq(id, (long)1);
	expect_line(&c, "{\"id\":1,\"result\":{\"service\":\"network\",\"data\":{\"wifi\":false}}}");
	network.publish("{\"wifi\":true}")!!;
	expect_line(&c, "{\"id\":1,\"result\":{\"service\":\"network\",\"data\":{\"wifi\":true}}}");
}

fn void the_first_subscription_frame_is_the_server_info() @test
{
	String path = socket_path("serverinfo");
	defer release(path);
	ipc::Server server;
	server.init(
		mem,
		{ .app_name = APP, .api_version = 38, .socket_path = path, .capabilities = { "network", "bluetooth" } }
	)!!;
	defer server.free();
	server.start()!!;
	defer server.stop();

	client::Client c;
	c.connect(mem, path, WAIT)!!;
	defer c.free();
	test::eq(c.handshake, "{\"apiVersion\":38,\"capabilities\":[\"network\",\"bluetooth\"]}");
	long id = c.subscribe({ }, WAIT)!!;
	test::eq(id, (long)1);
	// The server frame was consumed by subscribe; a notification is the next frame.
	server.notify_capabilities_changed()!!;
	expect_line(
		&c,
		"{\"id\":1,\"result\":{\"service\":\"server\",\"data\":{\"apiVersion\":38,\"capabilities\":[\"network\",\"bluetooth\"]}}}"
	);
}

fn void all_leaves_out_explicit_topics_but_naming_one_includes_it() @test
{
	String path = socket_path("explicit");
	defer release(path);
	ipc::Server server;
	server.init(mem, config_for(path))!!;
	defer server.free();
	ipc::Topic* state    = server.register_topic("state")!!;
	ipc::Topic* commands = server.register_topic("commands", { .explicit_only = true })!!;
	server.start()!!;
	defer server.stop();

	client::Client wide;
	wide.connect(mem, path, WAIT)!!;
	defer wide.free();
	wide.subscribe({ "all" }, WAIT)!!;
	commands.publish_event("{\"cmd\":\"play\"}")!!;
	test::@check(quiet(&wide));
	state.publish_event("{\"s\":1}")!!;
	expect_line(&wide, "{\"id\":1,\"result\":{\"service\":\"state\",\"data\":{\"s\":1}}}");

	client::Client named;
	named.connect(mem, path, WAIT)!!;
	defer named.free();
	named.subscribe({ "commands" }, WAIT)!!;
	commands.publish_event("{\"cmd\":\"stop\"}")!!;
	expect_line(&named, "{\"id\":1,\"result\":{\"service\":\"commands\",\"data\":{\"cmd\":\"stop\"}}}");
}

fn void events_are_neither_kept_nor_coalesced() @test
{
	String path = socket_path("events");
	defer release(path);
	ipc::Server server;
	server.init(mem, config_for(path))!!;
	defer server.free();
	ipc::Topic* events = server.register_topic("events")!!;
	events.publish_event("{\"n\":0}")!!;
	server.start()!!;
	defer server.stop();

	client::Client c;
	c.connect(mem, path, WAIT)!!;
	defer c.free();
	c.subscribe({ "events" }, WAIT)!!;
	test::@check(quiet(&c));
	events.publish_event("{\"n\":1}")!!;
	events.publish_event("{\"n\":2}")!!;
	events.publish_event("{\"n\":3}")!!;
	expect_line(&c, "{\"id\":1,\"result\":{\"service\":\"events\",\"data\":{\"n\":1}}}");
	expect_line(&c, "{\"id\":1,\"result\":{\"service\":\"events\",\"data\":{\"n\":2}}}");
	expect_line(&c, "{\"id\":1,\"result\":{\"service\":\"events\",\"data\":{\"n\":3}}}");
}

fn void subscriber_counts_follow_connections() @test
{
	String path = socket_path("counts");
	defer release(path);
	ipc::Server server;
	server.init(mem, config_for(path))!!;
	defer server.free();
	ipc::Topic* network = server.register_topic("network")!!;
	server.start()!!;
	defer server.stop();

	client::Client first;
	first.connect(mem, path, WAIT)!!;
	first.subscribe({ "network" }, WAIT)!!;
	client::Client second;
	second.connect(mem, path, WAIT)!!;
	second.subscribe({ "network" }, WAIT)!!;
	test::eq(server.subscriber_count(network), 2);
	first.free();
	// The I/O thread notices the closed socket on its own; wait for that.
	for (int i = 0; i < 500 && server.subscriber_count(network) != 1; i++) thread::sleep_ms(10);
	test::eq(server.subscriber_count(network), 1);
	second.free();
}

<*
 Publishes `count` values starting at `first`. Each publication happens under the
 shared order lock, which also records the value in `last`, so the final value
 the server must deliver is known.
*>
struct Storm
{
	ipc::Topic* topic;
	Mutex* order;
	int count;
	int first;
	int* last;
}

fn int storm_publisher(void* arg)
{
	foreign::@foreign_entry()
	{
		Storm* storm = (Storm*)arg;
		for (int i = 0; i < storm.count; i++)
		{
			storm.order.lock()!!;
			String json;
			@pool()
			{
				json = string::tformat("{\"v\":%d}", storm.first + i).copy(mem);
			};
			storm.topic.publish(json)!!;
			release(json);
			*storm.last = storm.first + i;
			storm.order.unlock();
		}
	};
	return 0;
}

fn void concurrent_publishers_leave_every_subscriber_on_the_last_value() @test
{
	String path = socket_path("storm");
	defer release(path);
	ipc::Server server;
	server.init(mem, config_for(path))!!;
	defer server.free();
	ipc::Topic* storm_topic = server.register_topic("storm")!!;
	server.start()!!;
	defer server.stop();

	client::Client[3] clients;
	for (int i = 0; i < 3; i++)
	{
		clients[i].connect(mem, path, WAIT)!!;
		clients[i].subscribe({ "storm" }, WAIT)!!;
	}
	defer
	{
		for (int i = 0; i < 3; i++) clients[i].free();
	}

	Mutex order;
	order.init()!!;
	defer order.destroy();
	int last = -1;
	Storm[3] storms;
	Thread[3] threads;
	for (int i = 0; i < 3; i++)
	{
		storms[i] = { .topic = storm_topic, .order = &order, .count = 400, .first = 1000 * i, .last = &last };
		threads[i].create(&storm_publisher, &storms[i])!!;
	}
	for (int i = 0; i < 3; i++) threads[i].join()!!;

	// The server's final state must be the value the last publication under the lock carried.
	String expected;
	@pool()
	{
		expected = string::tformat("{\"id\":1,\"result\":{\"service\":\"storm\",\"data\":{\"v\":%d}}}", last).copy(mem);
	};
	defer release(expected);
	for (int i = 0; i < 3; i++)
	{
		// Frames may be coalesced, so intermediate values can be skipped, but the final value must arrive.
		bool seen = false;
		for (int n = 0; n < 100000 && !seen; n++)
		{
			String line = clients[i].next_line(WAIT)!!;
			seen = line == expected;
			release(line);
		}
		test::@check(seen);
		test::@check(quiet(&clients[i]));
	}
}

fn void a_client_that_stops_reading_is_disconnected_after_the_write_stall() @test
{
	String path = socket_path("stall");
	defer release(path);
	ipc::Server server;
	server.init(mem, { .app_name = APP, .api_version = 38, .socket_path = path, .write_stall = (Duration)300_000 })!!;
	defer server.free();
	ipc::Topic* big = server.register_topic("big")!!;
	server.start()!!;
	defer server.stop();

	unix::UnixSocket stuck = unix::connect(path, unix::SocketKind.STREAM)!!;
	defer stuck.close();
	String handshake = read_raw_line(&stuck);
	release(handshake);
	send_text(&stuck, "{\"id\":1,\"method\":\"subscribe\",\"params\":{\"services\":[\"big\"]}}\n");
	// Wait for the subscription to exist before publishing.
	for (int i = 0; i < 500 && server.subscriber_count(big) != 1; i++) thread::sleep_ms(10);
	test::eq(server.subscriber_count(big), 1);

	// A payload far larger than the socket buffers, published repeatedly. The client never reads.
	usz size       = 512 * 1024;
	char[] payload = alloc::new_array(mem, char, (sz)size);
	defer alloc::free(mem, payload.ptr);
	mem::set(payload.ptr, 'a', (sz)size);
	for (int i = 0; i < 8; i++)
	{
		String wrapped = wrap_blob((String)payload[0:(sz)size]);
		big.publish(wrapped)!!;
		release(wrapped);
	}
	for (int i = 0; i < 500 && server.subscriber_count(big) != 0; i++) thread::sleep_ms(10);
	test::eq(server.subscriber_count(big), 0);
}

// The payload as a JSON string value, `"aaaa..."`. Allocated with `mem`.
fn String wrap_blob(String body)
{
	wire::Writer w;
	w.init(mem, body.len + 2);
	w.put("\"");
	w.put(body);
	w.put("\"");
	return w.finish();
}

fn void a_line_longer_than_the_limit_closes_the_connection() @test
{
	String path = socket_path("oversize");
	defer release(path);
	ipc::Server server;
	server.init(mem, { .app_name = APP, .api_version = 38, .socket_path = path, .max_line = 256 })!!;
	defer server.free();
	server.start()!!;
	defer server.stop();

	unix::UnixSocket raw = unix::connect(path, unix::SocketKind.STREAM)!!;
	defer raw.close();
	String handshake = read_raw_line(&raw);
	release(handshake);
	char[512] junk;
	mem::set(&junk[0], 'j', 512);
	raw.send_all(junk[..])!!;
	// The server closes the socket: reading reaches end of stream.
	char[64] buffer;
	bool closed = false;
	for (int i = 0; i < 1000 && !closed; i++)
	{
		RecvResult? got = raw.recv(buffer[..], { });
		if (catch err = got)
		{
			closed = err != error::BUSY;
		}
		else
		{
			closed = got.bytes == 0;
		}
	}
	test::@check(closed);
}

fn void a_stopped_server_refuses_publications_and_late_registration() @test
{
	String path = socket_path("lifecycle");
	defer release(path);
	ipc::Server server;
	server.init(mem, config_for(path))!!;
	defer server.free();
	ipc::Topic* topic = server.register_topic("t")!!;
	server.start()!!;
	test::@error(server.register_method("late", &answer_ok, null), error::INVALID_STATE);
	test::@error(server.start(), error::INVALID_STATE);
	test::@error(server.register_topic("later"), error::INVALID_STATE);
	server.stop();
	server.stop();
	test::@error(topic.publish("{}"), error::UNAVAILABLE);
	test::@error(topic.publish("{\n}"), error::INVALID_ARGUMENT);
}

// Read one line from a raw socket, byte by byte, into a heap copy. Blocks until it arrives.
fn String read_raw_line(unix::UnixSocket* socket)
{
	DString line;
	line.init(mem, 64);
	defer line.free();
	char[1] one;
	while (true)
	{
		RecvResult got = socket.recv(one[..], { })!!;
		if (got.bytes == 0) break;
		if (one[0] == '\n') break;
		line.append_char(one[0]);
	}
	return line.copy_str(mem);
}