<*
 The Linux route against a scripted compositor: the read-only route (wl_output with xdg-output), and
 the wlr route (heads, a test then an apply, and a rollback nobody confirmed). The session and the
 real client run on the test thread; the compositor is a MockServer scenario on another thread,
 expecting each request in order and answering it.
*>
module bleu::display::linux_test @feat(LINUX);
import bleu::display, bleu::display::linux_wayland, bleu::wl, bleu::wl::testing, bleu::wl::wire, bleu::wl::proto::wayland, bleu::wl::proto::xdg_output, bleu::wl::proto::wlr_output_management, bleu::rt::unix, bleu::rt::foreign, bleu::operation, bleu::error, bleu::observe, bleu::availability, std::core::test, std::thread, std::time::clock;

// wl_display's id, and the events and requests the scenarios use (opcodes from the protocol XML).
const uint WL_DISPLAY                     = 1;
const ushort DISPLAY_SYNC                 = 0;
const ushort DISPLAY_GET_REGISTRY         = 1;
const ushort DISPLAY_DELETE_ID            = 1;
const ushort REGISTRY_BIND                = 0;
const ushort CALLBACK_DONE                = 0;
const ushort WL_OUTPUT_GEOMETRY           = 0;
const ushort WL_OUTPUT_MODE               = 1;
const ushort WL_OUTPUT_DONE               = 2;
const ushort WL_OUTPUT_SCALE              = 3;
const ushort WL_OUTPUT_NAME               = 4;
const ushort XDG_MANAGER_GET_OUTPUT       = 1;
const ushort XDG_OUTPUT_LOGICAL_POSITION  = 0;
const ushort XDG_OUTPUT_LOGICAL_SIZE      = 1;
const ushort XDG_OUTPUT_DONE              = 2;
const ushort MANAGER_CREATE_CONFIGURATION = 0;
const ushort MANAGER_HEAD                 = 0;
const ushort MANAGER_DONE                 = 1;
const ushort HEAD_NAME                    = 0;
const ushort HEAD_PHYSICAL_SIZE           = 2;
const ushort HEAD_MODE                    = 3;
const ushort HEAD_ENABLED                 = 4;
const ushort HEAD_CURRENT_MODE            = 5;
const ushort HEAD_POSITION                = 6;
const ushort HEAD_TRANSFORM               = 7;
const ushort HEAD_SCALE                   = 8;
const ushort HEAD_MAKE                    = 10;
const ushort MODE_SIZE                    = 0;
const ushort MODE_REFRESH                 = 1;
const ushort CONFIG_ENABLE_HEAD           = 0;
const ushort CONFIG_APPLY                 = 2;
const ushort CONFIG_TEST                  = 3;
const ushort CONFIG_DESTROY               = 4;
const ushort CONFIG_SUCCEEDED             = 0;
const ushort CONFIG_HEAD_SET_MODE         = 0;
const ushort CONFIG_HEAD_SET_POSITION     = 2;
const ushort CONFIG_HEAD_SET_TRANSFORM    = 3;
const ushort CONFIG_HEAD_SET_SCALE        = 4;

const uint SERIAL                     = 7;
const uint CONFIG_TIMEOUT_NANOS_AHEAD = 2_000_000_000;

// Globals of the scenarios, and the ids the compositor gives the head and mode it creates.
const uint OUTPUT_GLOBAL  = 1;
const uint XDG_GLOBAL     = 2;
const uint MANAGER_GLOBAL = 5;
const uint HEAD_OBJECT    = 0xFF000003;
const uint MODE_OBJECT    = 0xFF000004;

fn void expect(bool ok, String what)
{
	if (!ok) unreachable(what);
}

fn testing::Message expect_request(testing::MockServer* s, uint object, ushort opcode)
{
	testing::Message message = s.receive()!!;
	expect(message.object == object && message.opcode == opcode, "unexpected request from the client");
	return message;
}

fn uint expect_bind(testing::MockServer* s, uint registry, uint name, String interface_name, uint version)
{
	testing::Message bind = expect_request(s, registry, REGISTRY_BIND);
	wire::Reader r        = s.reader(bind);
	expect(r.get_uint()!! == name, "bind of the wrong global");
	expect(r.get_string()!! == interface_name, "bind of the wrong interface");
	expect(r.get_uint()!! == version, "bind at the wrong version");
	return r.get_new_id()!!;
}

fn void send_global(testing::MockServer* s, uint registry, uint name, String interface_name, uint version)
{
	wire::Writer w;
	w.begin(registry, 0);
	w.put_uint(name)!!;
	w.put_string(interface_name)!!;
	w.put_uint(version)!!;
	s.send(&w)!!;
}

// Answer a sync: `done`, then the callback id is released.
fn void answer_sync(testing::MockServer* s, uint callback)
{
	wire::Writer done;
	done.begin(callback, CALLBACK_DONE);
	done.put_uint(1)!!;
	s.send(&done)!!;
	wire::Writer released;
	released.begin(WL_DISPLAY, DISPLAY_DELETE_ID);
	released.put_uint(callback)!!;
	s.send(&released)!!;
}

// The first half of a connection: the registry with the given globals, and the first sync answered.
fn uint serve_registry(testing::MockServer* s, bool wlr)
{
	testing::Message get = expect_request(s, WL_DISPLAY, DISPLAY_GET_REGISTRY);
	uint registry        = s.reader(get).get_new_id()!!;
	if (wlr)
	{
		send_global(s, registry, MANAGER_GLOBAL, "zwlr_output_manager_v1", 4);
	}
	else
	{
		send_global(s, registry, OUTPUT_GLOBAL, "wl_output", 4);
		send_global(s, registry, XDG_GLOBAL, "zxdg_output_manager_v1", 3);
	}
	testing::Message sync = expect_request(s, WL_DISPLAY, DISPLAY_SYNC);
	answer_sync(s, s.reader(sync).get_new_id()!!);
	return registry;
}

// The wl_output and xdg-output events for the one output: 1920x1080 at 60 Hz, scale 1, named DP-1.
// `output` and `xdg` are the ids the client chose for them.
fn void send_output(testing::MockServer* s, uint output, uint xdg)
{
	wire::Writer geometry;
	geometry.begin(output, WL_OUTPUT_GEOMETRY);
	geometry.put_int(0)!!;
	geometry.put_int(0)!!;
	geometry.put_int(340)!!;
	geometry.put_int(190)!!;
	geometry.put_uint(0)!!;
	geometry.put_string("ACME")!!;
	geometry.put_string("Panel")!!;
	geometry.put_int(0)!!;
	s.send(&geometry)!!;
	wire::Writer mode;
	mode.begin(output, WL_OUTPUT_MODE);
	mode.put_uint(3)!!; // current | preferred
	mode.put_int(1920)!!;
	mode.put_int(1080)!!;
	mode.put_int(60000)!!;
	s.send(&mode)!!;
	wire::Writer scale;
	scale.begin(output, WL_OUTPUT_SCALE);
	scale.put_int(1)!!;
	s.send(&scale)!!;
	wire::Writer name;
	name.begin(output, WL_OUTPUT_NAME);
	name.put_string("DP-1")!!;
	s.send(&name)!!;
	wire::Writer done;
	done.begin(output, WL_OUTPUT_DONE);
	s.send(&done)!!;
	wire::Writer position;
	position.begin(xdg, XDG_OUTPUT_LOGICAL_POSITION);
	position.put_int(0)!!;
	position.put_int(0)!!;
	s.send(&position)!!;
	wire::Writer size;
	size.begin(xdg, XDG_OUTPUT_LOGICAL_SIZE);
	size.put_int(1920)!!;
	size.put_int(1080)!!;
	s.send(&size)!!;
	wire::Writer xdg_done;
	xdg_done.begin(xdg, XDG_OUTPUT_DONE);
	s.send(&xdg_done)!!;
}

// The wlr head for the one output with its current mode, and the manager's `done` at SERIAL.
fn void send_head(testing::MockServer* s, uint manager)
{
	wire::Writer head;
	head.begin(manager, MANAGER_HEAD);
	head.put_new_id(HEAD_OBJECT)!!;
	s.send(&head)!!;
	wire::Writer name;
	name.begin(HEAD_OBJECT, HEAD_NAME);
	name.put_string("DP-1")!!;
	s.send(&name)!!;
	wire::Writer physical;
	physical.begin(HEAD_OBJECT, HEAD_PHYSICAL_SIZE);
	physical.put_int(340)!!;
	physical.put_int(190)!!;
	s.send(&physical)!!;
	wire::Writer mode;
	mode.begin(HEAD_OBJECT, HEAD_MODE);
	mode.put_new_id(MODE_OBJECT)!!;
	s.send(&mode)!!;
	wire::Writer size;
	size.begin(MODE_OBJECT, MODE_SIZE);
	size.put_int(1920)!!;
	size.put_int(1080)!!;
	s.send(&size)!!;
	wire::Writer refresh;
	refresh.begin(MODE_OBJECT, MODE_REFRESH);
	refresh.put_int(60000)!!;
	s.send(&refresh)!!;
	wire::Writer enabled;
	enabled.begin(HEAD_OBJECT, HEAD_ENABLED);
	enabled.put_int(1)!!;
	s.send(&enabled)!!;
	wire::Writer current;
	current.begin(HEAD_OBJECT, HEAD_CURRENT_MODE);
	current.put_object(MODE_OBJECT)!!;
	s.send(&current)!!;
	wire::Writer position;
	position.begin(HEAD_OBJECT, HEAD_POSITION);
	position.put_int(0)!!;
	position.put_int(0)!!;
	s.send(&position)!!;
	wire::Writer transform;
	transform.begin(HEAD_OBJECT, HEAD_TRANSFORM);
	transform.put_uint(0)!!;
	s.send(&transform)!!;
	wire::Writer scale;
	scale.begin(HEAD_OBJECT, HEAD_SCALE);
	scale.put_fixed(wire::fixed_from_double(1.0))!!;
	s.send(&scale)!!;
	wire::Writer make;
	make.begin(HEAD_OBJECT, HEAD_MAKE);
	make.put_string("ACME")!!;
	s.send(&make)!!;
	wire::Writer done;
	done.begin(manager, MANAGER_DONE);
	done.put_uint(SERIAL)!!;
	s.send(&done)!!;
}

// Expect the request sequence that sends a configuration of the one head: its mode, place and transform, and
// scale when `with_scale` is set (the rollback names the scale it restores).
fn uint expect_configure(testing::MockServer* s, uint manager, bool with_scale)
{
	testing::Message create = expect_request(s, manager, MANAGER_CREATE_CONFIGURATION);
	wire::Reader c          = s.reader(create);
	uint config             = c.get_new_id()!!;
	expect(c.get_uint()!! == SERIAL, "configuration created with a stale serial");
	testing::Message enable = expect_request(s, config, CONFIG_ENABLE_HEAD);
	wire::Reader e          = s.reader(enable);
	uint config_head        = e.get_new_id()!!;
	expect(e.get_object()!! == HEAD_OBJECT, "enabled the wrong head");
	expect(s.reader(expect_request(s, config_head, CONFIG_HEAD_SET_MODE))
		.get_object()!! == MODE_OBJECT, "set the wrong mode");
	testing::Message position = expect_request(s, config_head, CONFIG_HEAD_SET_POSITION);
	expect(s.reader(position).get_int()!! == 0, "moved the output");
	expect_request(s, config_head, CONFIG_HEAD_SET_TRANSFORM);
	if (with_scale) expect_request(s, config_head, CONFIG_HEAD_SET_SCALE);
	return config;
}

fn void send_config_result(testing::MockServer* s, uint config, ushort event)
{
	wire::Writer result;
	result.begin(config, event);
	s.send(&result)!!;
}

// Connect a client to the server end, which the scenario drives.
fn wl::Client* connect(testing::MockServer* server)
{
	unix::SocketPair pair = unix::socket_pair(unix::SocketKind.STREAM)!!;
	server.attach(pair.second);
	wl::Client* client = alloc::new(mem, wl::Client);
	client.init(mem, pair.first.fd.release())!!;
	return client;
}

// Drive the session until the request in flight is complete.
fn void pump(linux_wayland::Session* session)
{
	while (session.pending != null)
	{
		session.client.flush()!!;
		session.client.dispatch()!!;
		linux_wayland::advance(session, clock::now());
	}
	// The last answer may have queued requests (the destroy of its configuration object) that nothing else sends.
	session.client.flush()!!;
}

fn int read_route_scenario(void* arg)
{
	foreign::@foreign_entry()
	{
		testing::MockServer* s = (testing::MockServer*)arg;
		uint registry          = serve_registry(s, false);
		uint xdg_manager       = expect_bind(s, registry, XDG_GLOBAL, "zxdg_output_manager_v1", 3);
		uint output            = expect_bind(s, registry, OUTPUT_GLOBAL, "wl_output", 4);
		testing::Message get   = expect_request(s, xdg_manager, XDG_MANAGER_GET_OUTPUT);
		wire::Reader g         = s.reader(get);
		uint xdg               = g.get_new_id()!!;
		expect(g.get_object()!! == output, "xdg output for the wrong output");
		testing::Message sync = expect_request(s, WL_DISPLAY, DISPLAY_SYNC);
		send_output(s, output, xdg);
		answer_sync(s, s.reader(sync).get_new_id()!!);
	};
	return 0;
}

fn void read_route_describes_the_outputs_and_is_read_only() @test
{
	testing::MockServer server;
	defer server.close();
	wl::Client* client = connect(&server);
	Thread t;
	t.create(&read_route_scenario, &server)!!;
	linux_wayland::Session* session = linux_wayland::attach(mem, client, "")!!;
	t.join()!!;
	defer session.close();
	@pool()
	{
		display::State state = linux_wayland::build_state(session, tmem);
		assert(state.outputs.len == 1);
		assert(state.outputs[0].id == "DP-1" && state.outputs[0].name == "DP-1");
		assert(state.outputs[0].enabled && state.outputs[0].make == "ACME");
		assert(state.outputs[0].current.has_value && state.outputs[0].current.value.width == 1920);
		assert(state.outputs[0].current.value.refresh == 60000);
		assert(state.outputs[0].scale.has_value && state.outputs[0].scale.value == 1.0);
		assert(state.outputs[0].transform == display::Transform.NORMAL);
	};
	display::Capabilities caps;
	linux_wayland::fill_capabilities(session, &caps);
	assert(caps.values[display::Cap.ENUMERATE.ordinal].ok());
	assert(!caps.values[display::Cap.SET_LAYOUT.ordinal].ok());
	assert(caps.values[display::Cap.SET_LAYOUT.ordinal].reason == availability::Reason.UNSUPPORTED_BACKEND);
}

fn int wlr_test_scenario(void* arg)
{
	foreign::@foreign_entry()
	{
		testing::MockServer* s = (testing::MockServer*)arg;
		uint registry          = serve_registry(s, true);
		uint manager           = expect_bind(s, registry, MANAGER_GLOBAL, "zwlr_output_manager_v1", 4);
		testing::Message sync  = expect_request(s, WL_DISPLAY, DISPLAY_SYNC);
		send_head(s, manager);
		answer_sync(s, s.reader(sync).get_new_id()!!);
		// Test only: the configuration is tested, answered, and destroyed.
		uint config = expect_configure(s, manager, false);
		expect_request(s, config, CONFIG_TEST);
		send_config_result(s, config, CONFIG_SUCCEEDED);
		expect_request(s, config, CONFIG_DESTROY);
	};
	return 0;
}

// A copy of the configuration in the operation's arena, as the public `apply` makes it.
fn display::Config owned(ApplyOp* op, display::Config config)
{
	return display::copy_config(config, op.allocator());
}

fn void test_only_reports_the_outcome_and_changes_nothing() @test
{
	testing::MockServer server;
	defer server.close();
	wl::Client* client = connect(&server);
	Thread t;
	t.create(&wlr_test_scenario, &server)!!;
	linux_wayland::Session* session = linux_wayland::attach(mem, client, "")!!;
	defer session.close();
	assert(session.wlr && session.serial == SERIAL);
	ApplyOp* op = operation::begin(mem);
	op.retain();
	// Rotated: a change the platform must make (an unchanged layout completes without asking the compositor).
	display::OutputChange[1] changes = {
		{
			.output_id = "DP-1",
			.enabled = true,
			.mode = { .width = 1920, .height = 1080, .refresh = 60000 },
			.transform = display::Transform.R90
		},
	};
	display::Config config = owned(op, { .outputs = changes[..] });
	linux_wayland::begin_apply(
		session,
		{ .kind = display::CommandKind.APPLY, .op = op, .config = config, .mode = display::ApplyMode.TEST_ONLY },
		clock::now()
	);
	pump(session);
	display::ApplyResult result = op.wait()!!;
	assert(!result.live && !result.revert_armed);
	op.release();
	t.join()!!;
}

// The apply scenario: test, apply, then the rollback that nobody confirms.
fn int wlr_rollback_scenario(void* arg)
{
	foreign::@foreign_entry()
	{
		testing::MockServer* s = (testing::MockServer*)arg;
		uint registry          = serve_registry(s, true);
		uint manager           = expect_bind(s, registry, MANAGER_GLOBAL, "zwlr_output_manager_v1", 4);
		testing::Message sync  = expect_request(s, WL_DISPLAY, DISPLAY_SYNC);
		send_head(s, manager);
		answer_sync(s, s.reader(sync).get_new_id()!!);
		// The test of the new layout.
		uint tested = expect_configure(s, manager, false);
		expect_request(s, tested, CONFIG_TEST);
		send_config_result(s, tested, CONFIG_SUCCEEDED);
		expect_request(s, tested, CONFIG_DESTROY);
		// The apply of the new layout.
		uint applied = expect_configure(s, manager, false);
		expect_request(s, applied, CONFIG_APPLY);
		send_config_result(s, applied, CONFIG_SUCCEEDED);
		expect_request(s, applied, CONFIG_DESTROY);
		// The rollback: the layout before the change, which carries the scale the compositor reported.
		uint rollback = expect_configure(s, manager, true);
		expect_request(s, rollback, CONFIG_APPLY);
		send_config_result(s, rollback, CONFIG_SUCCEEDED);
		expect_request(s, rollback, CONFIG_DESTROY);
	};
	return 0;
}

fn void unconfirmed_change_is_rolled_back() @test
{
	testing::MockServer server;
	defer server.close();
	wl::Client* client = connect(&server);
	Thread t;
	t.create(&wlr_rollback_scenario, &server)!!;
	linux_wayland::Session* session = linux_wayland::attach(mem, client, "")!!;
	defer session.close();
	ApplyOp* op = operation::begin(mem);
	op.retain();
	display::OutputChange[1] changes = {
		{
			.output_id = "DP-1",
			.enabled = true,
			.mode = { .width = 1920, .height = 1080, .refresh = 60000 },
			.transform = display::Transform.R90
		},
	};
	display::Config config = owned(op, { .outputs = changes[..] });
	linux_wayland::begin_apply(
		session,
		{
			.kind = display::CommandKind.APPLY,
			.op = op,
			.config = config,
			.mode = display::ApplyMode.APPLY_WITH_REVERT,
			.revert_after = (Duration)1_000_000
		},
		clock::now()
	);
	pump(session);
	display::ApplyResult result = op.wait()!!;
	assert(result.live && result.revert_armed);
	op.release();
	// Nobody confirmed: once the deadline has passed the previous layout comes back.
	assert(session.guard.armed);
	linux_wayland::advance(session, clock::now() + (Clock)CONFIG_TIMEOUT_NANOS_AHEAD);
	pump(session);
	assert(!session.guard.armed && session.pending == null);
	t.join()!!;
}