<*
 End-to-end flows: the real client on the test thread, a MockServer scenario on a second
 thread, talking over a socket pair. Covers the registry and globals (with delete_id and
 id reuse), wl_output with version negotiation, ext-idle-notify, wlr-gamma-control with a
 descriptor, wlr-output-management's configuration round trip with server-created
 objects, wlr-data-control's receive with a pipe, and a compositor protocol error.
*>
module bleu::wl::client_test @feat(POSIX);
import bleu::wl, bleu::wl::display, bleu::wl::testing, bleu::wl::wire, bleu::wl::proto::wayland, bleu::wl::proto::ext_idle_notify, bleu::wl::proto::wlr_gamma_control, bleu::wl::proto::wlr_output_management, bleu::wl::proto::wlr_data_control, bleu::rt, bleu::rt::unix, bleu::rt::foreign, bleu::error, std::core::test, std::thread, std::core::mem;

// libc entry points for the pipes the gamma and data-control scenarios pass around.
extern fn CInt sys_pipe(CInt* fds) @cname("pipe");
extern fn sz sys_read(CInt fd, void* buf, usz count) @cname("read");
extern fn sz sys_write(CInt fd, void* buf, usz count) @cname("write");

// Wayland ids the compositor gives its own objects (wayland.xml: server ids start at 0xff000000).
const uint SERVER_OBJECT_A = 0xFF000001;
const uint SERVER_OBJECT_B = 0xFF000002;
const uint SERVER_OBJECT_C = 0xFF000003;

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

// Send one global advertisement from the registry.
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

// Get the registry and advertise the five globals every scenario binds to. Returns the registry id.
fn uint advertise_registry(testing::MockServer* s)
{
	testing::Message get = expect_request(s, display::DISPLAY_ID, 1);
	uint registry        = s.reader(get).get_new_id()!!;
	send_global(s, registry, 1, "wl_output", 4);
	send_global(s, registry, 2, "zwlr_gamma_control_manager_v1", 1);
	send_global(s, registry, 3, "ext_idle_notifier_v1", 1);
	send_global(s, registry, 4, "wl_seat", 7);
	send_global(s, registry, 5, "zwlr_output_manager_v1", 4);
	send_global(s, registry, 6, "zwlr_data_control_manager_v1", 2);
	return registry;
}

// The first half of every scenario: the registry, then the client's first sync answered.
fn uint serve_registry(testing::MockServer* s)
{
	uint registry         = advertise_registry(s);
	testing::Message sync = expect_request(s, display::DISPLAY_ID, 0);
	answer_sync(s, s.reader(sync).get_new_id()!!);
	return registry;
}

// Bind request from the client: returns the name, the version, and the id it allocated.
fn uint expect_bind(testing::MockServer* s, uint registry, uint name, String interface_name, uint version)
{
	testing::Message bind = expect_request(s, registry, 0);
	wire::Reader r        = s.reader(bind);
	expect(r.get_uint()!! == name, "bind of the wrong global");
	expect(r.get_string()!! == interface_name, "bind of the wrong interface");
	expect(r.get_uint()!! == version, "bind at the wrong version");
	return r.get_new_id()!!;
}

// Thread entry points. Each scenario runs the server side of one flow.

fn int registry_scenario(void* arg)
{
	foreign::@foreign_entry()
	{
		testing::MockServer* s = (testing::MockServer*)arg;
		uint registry          = advertise_registry(s);
		testing::Message first = expect_request(s, display::DISPLAY_ID, 0);
		uint first_callback    = s.reader(first).get_new_id()!!;
		answer_sync(s, first_callback);
		// Second roundtrip: the client reuses the freed callback id, and the gamma global goes away
		// before the answer. The removal must follow the second sync, or the first roundtrip would
		// deliver it along with its own `done`.
		testing::Message second = expect_request(s, display::DISPLAY_ID, 0);
		uint second_callback    = s.reader(second).get_new_id()!!;
		expect(second_callback == first_callback, "the freed callback id was not reused");
		wire::Writer removed;
		removed.begin(registry, 1);
		removed.put_uint(2)!!;
		s.send(&removed)!!;
		answer_sync(s, second_callback);
	};
	return 0;
}

fn int output_scenario(void* arg)
{
	foreign::@foreign_entry()
	{
		testing::MockServer* s = (testing::MockServer*)arg;
		uint registry          = serve_registry(s);
		uint output            = expect_bind(s, registry, 1, "wl_output", 4);
		expect_bind(s, registry, 4, "wl_seat", 7);
		wire::Writer geometry;
		geometry.begin(output, 0);
		geometry.put_int(0)!!;
		geometry.put_int(0)!!;
		geometry.put_int(600)!!;
		geometry.put_int(340)!!;
		geometry.put_int(0)!!;
		geometry.put_string("Acme")!!;
		geometry.put_string("P1")!!;
		geometry.put_int(0)!!;
		s.send(&geometry)!!;
		wire::Writer mode;
		mode.begin(output, 1);
		mode.put_uint(3)!!;
		mode.put_int(2560)!!;
		mode.put_int(1440)!!;
		mode.put_int(60000)!!;
		s.send(&mode)!!;
		wire::Writer done;
		done.begin(output, 2);
		s.send(&done)!!;
	};
	return 0;
}

fn int idle_scenario(void* arg)
{
	foreign::@foreign_entry()
	{
		testing::MockServer* s   = (testing::MockServer*)arg;
		uint registry            = serve_registry(s);
		uint notifier            = expect_bind(s, registry, 3, "ext_idle_notifier_v1", 1);
		uint seat                = expect_bind(s, registry, 4, "wl_seat", 7);
		testing::Message request = expect_request(s, notifier, 1);
		wire::Reader r           = s.reader(request);
		uint notification        = r.get_new_id()!!;
		expect(r.get_uint()!! == 5000, "timeout");
		expect(r.get_object()!! == seat, "idle notification on the wrong seat");
		wire::Writer idled;
		idled.begin(notification, 0);
		s.send(&idled)!!;
		wire::Writer resumed;
		resumed.begin(notification, 1);
		s.send(&resumed)!!;
	};
	return 0;
}

fn int gamma_scenario(void* arg)
{
	foreign::@foreign_entry()
	{
		testing::MockServer* s = (testing::MockServer*)arg;
		uint registry          = serve_registry(s);
		uint output            = expect_bind(s, registry, 1, "wl_output", 4);
		uint manager           = expect_bind(s, registry, 2, "zwlr_gamma_control_manager_v1", 1);
		testing::Message get   = expect_request(s, manager, 0);
		wire::Reader g         = s.reader(get);
		uint control           = g.get_new_id()!!;
		expect(g.get_object()!! == output, "gamma control for the wrong output");
		wire::Writer size;
		size.begin(control, 0);
		size.put_uint(256)!!;
		s.send(&size)!!;
		testing::Message set = expect_request(s, control, 0);
		rt::Native fd        = s.reader(set).get_fd()!!;
		char[6] ramp;
		sz got               = sys_read(fd, &ramp, 6);
		expect(got == 6 && ramp[0] == 1 && ramp[5] == 6, "gamma ramp bytes did not arrive intact");
		display::native_close(fd);
	};
	return 0;
}

fn int output_management_scenario(void* arg)
{
	foreign::@foreign_entry()
	{
		testing::MockServer* s = (testing::MockServer*)arg;
		uint registry          = serve_registry(s);
		uint manager           = expect_bind(s, registry, 5, "zwlr_output_manager_v1", 4);
		wire::Writer head;
		head.begin(manager, 0);
		head.put_new_id(SERVER_OBJECT_A)!!;
		s.send(&head)!!;
		wire::Writer name;
		name.begin(SERVER_OBJECT_A, 0);
		name.put_string("DP-1")!!;
		s.send(&name)!!;
		wire::Writer mode;
		mode.begin(SERVER_OBJECT_A, 3);
		mode.put_new_id(SERVER_OBJECT_B)!!;
		s.send(&mode)!!;
		wire::Writer size;
		size.begin(SERVER_OBJECT_B, 0);
		size.put_int(1920)!!;
		size.put_int(1080)!!;
		s.send(&size)!!;
		wire::Writer done;
		done.begin(manager, 1);
		done.put_uint(7)!!;
		s.send(&done)!!;
		testing::Message create = expect_request(s, manager, 0);
		wire::Reader c          = s.reader(create);
		uint configuration      = c.get_new_id()!!;
		expect(c.get_uint()!! == 7, "configuration for the wrong serial");
		testing::Message enable = expect_request(s, configuration, 0);
		wire::Reader e          = s.reader(enable);
		uint config_head        = e.get_new_id()!!;
		expect(e.get_object()!! == SERVER_OBJECT_A, "enabled the wrong head");
		testing::Message set_mode = expect_request(s, config_head, 0);
		expect(s.reader(set_mode).get_object()!! == SERVER_OBJECT_B, "set the wrong mode");
		expect_request(s, configuration, 2);
		wire::Writer succeeded;
		succeeded.begin(configuration, 0);
		s.send(&succeeded)!!;
	};
	return 0;
}

fn int data_control_scenario(void* arg)
{
	foreign::@foreign_entry()
	{
		testing::MockServer* s = (testing::MockServer*)arg;
		uint registry          = serve_registry(s);
		uint seat              = expect_bind(s, registry, 4, "wl_seat", 7);
		uint manager           = expect_bind(s, registry, 6, "zwlr_data_control_manager_v1", 2);
		testing::Message get   = expect_request(s, manager, 1);
		wire::Reader g         = s.reader(get);
		uint device            = g.get_new_id()!!;
		expect(g.get_object()!! == seat, "device for the wrong seat");
		wire::Writer offer;
		offer.begin(device, 0);
		offer.put_new_id(SERVER_OBJECT_C)!!;
		s.send(&offer)!!;
		wire::Writer mime;
		mime.begin(SERVER_OBJECT_C, 0);
		mime.put_string("text/plain")!!;
		s.send(&mime)!!;
		wire::Writer selection;
		selection.begin(device, 1);
		selection.put_object(SERVER_OBJECT_C)!!;
		s.send(&selection)!!;
		testing::Message receive = expect_request(s, SERVER_OBJECT_C, 0);
		wire::Reader r           = s.reader(receive);
		expect(r.get_string()!! == "text/plain", "wrong mime type requested");
		rt::Native fd = r.get_fd()!!;
		char[] hello  = "hello";
		expect(sys_write(fd, hello.ptr, hello.len) == 5, "could not write the offer");
		display::native_close(fd);
	};
	return 0;
}

fn int protocol_error_scenario(void* arg)
{
	foreign::@foreign_entry()
	{
		testing::MockServer* s = (testing::MockServer*)arg;
		advertise_registry(s);
		testing::Message sync = expect_request(s, display::DISPLAY_ID, 0);
		uint callback         = s.reader(sync).get_new_id()!!;
		wire::Writer failure;
		failure.begin(display::DISPLAY_ID, 0);
		failure.put_uint(callback)!!;
		failure.put_uint(1)!!;
		failure.put_string("bad request")!!;
		s.send(&failure)!!;
	};
	return 0;
}

// Listeners and what they record.

struct Counts
{
	uint added;
	uint removed;
}

fn void count_added(void* context, Global global)
{
	Counts* counts = (Counts*)context;
	counts.added++;
}

fn void count_removed(void* context, uint name)
{
	Counts* counts = (Counts*)context;
	counts.removed++;
}

struct OutputState
{
	bool done;
	bool geometry_seen;
	bool make_is_acme;
	uint width;
}

fn void on_geometry(
	void* context,
	wayland::WlOutput* target,
	int x,
	int y,
	int physical_width,
	int physical_height,
	wayland::WlOutputSubpixel subpixel,
	String make,
	String model,
	wayland::WlOutputTransform transform
)
{
	OutputState* state = (OutputState*)context;
	state.geometry_seen = true;
	state.make_is_acme = make == "Acme";
}

fn void on_mode(
	void* context,
	wayland::WlOutput* target,
	wayland::WlOutputMode flags,
	int width,
	int height,
	int refresh
)
{
	OutputState* state = (OutputState*)context;
	state.width = (uint)width;
}

fn void on_output_done(void* context, wayland::WlOutput* target)
{
	OutputState* state = (OutputState*)context;
	state.done = true;
}

const wayland::WlOutputListener OUTPUT_LISTENER = {
	.geometry = &on_geometry,
	.mode = &on_mode,
	.done = &on_output_done
};

struct IdleState
{
	bool idled;
	bool resumed;
}

fn void on_idled(void* context, ext_idle_notify::ExtIdleNotificationV1* target)
{
	IdleState* state = (IdleState*)context;
	state.idled = true;
}

fn void on_resumed(void* context, ext_idle_notify::ExtIdleNotificationV1* target)
{
	IdleState* state = (IdleState*)context;
	state.resumed = state.idled;
}

const ext_idle_notify::ExtIdleNotificationV1Listener IDLE_LISTENER = { .idled = &on_idled, .resumed = &on_resumed };

struct GammaState
{
	uint size;
}

fn void on_gamma_size(void* context, wlr_gamma_control::ZwlrGammaControlV1* target, uint size)
{
	GammaState* state = (GammaState*)context;
	state.size = size;
}

const wlr_gamma_control::ZwlrGammaControlV1Listener GAMMA_LISTENER = { .gamma_size = &on_gamma_size };

struct OutputManagerState
{
	bool done;
	uint serial;
	wlr_output_management::ZwlrOutputHeadV1* head;
	wlr_output_management::ZwlrOutputModeV1* mode;
	bool succeeded;
	bool head_named;
}

fn void on_head(
	void* context,
	wlr_output_management::ZwlrOutputManagerV1* target,
	wlr_output_management::ZwlrOutputHeadV1* head
)
{
	OutputManagerState* state = (OutputManagerState*)context;
	state.head = head;
	head.set_listener(&HEAD_LISTENER, state);
}

fn void on_manager_done(void* context, wlr_output_management::ZwlrOutputManagerV1* target, uint serial)
{
	OutputManagerState* state = (OutputManagerState*)context;
	state.serial = serial;
	state.done = true;
}

const wlr_output_management::ZwlrOutputManagerV1Listener MANAGER_LISTENER = {
	.head = &on_head,
	.done = &on_manager_done
};

fn void on_head_name(void* context, wlr_output_management::ZwlrOutputHeadV1* target, String name)
{
	OutputManagerState* state = (OutputManagerState*)context;
	state.head_named = name == "DP-1";
}

fn void on_head_mode(
	void* context,
	wlr_output_management::ZwlrOutputHeadV1* target,
	wlr_output_management::ZwlrOutputModeV1* mode
)
{
	OutputManagerState* state = (OutputManagerState*)context;
	state.mode = mode;
}

const wlr_output_management::ZwlrOutputHeadV1Listener HEAD_LISTENER = { .name = &on_head_name, .mode = &on_head_mode };

fn void on_succeeded(void* context, wlr_output_management::ZwlrOutputConfigurationV1* target)
{
	OutputManagerState* state = (OutputManagerState*)context;
	state.succeeded = true;
}

const wlr_output_management::ZwlrOutputConfigurationV1Listener CONFIG_LISTENER = { .succeeded = &on_succeeded };

struct OfferState
{
	wlr_data_control::ZwlrDataControlOfferV1* selected;
	bool selected_seen;
}

fn void on_data_offer(
	void* context,
	wlr_data_control::ZwlrDataControlDeviceV1* target,
	wlr_data_control::ZwlrDataControlOfferV1* id
)
{
	// The offer's own events are not needed here.
}

fn void on_selection(
	void* context,
	wlr_data_control::ZwlrDataControlDeviceV1* target,
	wlr_data_control::ZwlrDataControlOfferV1* id
)
{
	OfferState* state = (OfferState*)context;
	state.selected = id;
	state.selected_seen = true;
}

const wlr_data_control::ZwlrDataControlDeviceV1Listener DEVICE_LISTENER = {
	.data_offer = &on_data_offer,
	.selection = &on_selection
};

// Shared client-side setup: a connected client and a scenario server on a socket pair.
// The caller owns both and closes them with defer.
fn void start_pair(testing::MockServer* server, Client* client) @private
{
	unix::SocketPair pair = unix::socket_pair(unix::SocketKind.STREAM)!!;
	server.attach(pair.second);
	client.init(mem, pair.first.fd.release())!!;
}

fn void registry_lists_globals_and_removals() @test
{
	testing::MockServer server;
	Client client;
	start_pair(&server, &client);
	defer server.close();
	defer client.close();
	Counts counts;
	ClientListener listener = { .global_added = &count_added, .global_removed = &count_removed };
	client.set_listener(&listener, &counts);
	Thread t;
	t.create(&registry_scenario, &server)!!;
	client.roundtrip()!!;
	test::eq(counts.added, 6u);
	Global[] globals = client.globals_view();
	test::eq(globals.len, (sz)6);
	test::eq(globals[0].interface_name, "wl_output");
	test::eq(globals[0].version, 4u);
	test::eq(globals[2].interface_name, "ext_idle_notifier_v1");
	client.roundtrip()!!;
	test::eq(counts.removed, 1u);
	test::eq(client.globals_view().len, (sz)5);
	t.join()!!;
}

fn void bind_negotiates_the_lower_version() @test
{
	testing::MockServer server;
	Client client;
	start_pair(&server, &client);
	defer server.close();
	defer client.close();
	Thread t;
	t.create(&output_scenario, &server)!!;
	client.roundtrip()!!;
	Global[] globals       = client.globals_view();
	display::Proxy* output = client.bind(globals[0], wayland::WL_OUTPUT)!!;
	display::Proxy* seat   = client.bind(globals[3], wayland::WL_SEAT)!!;
	test::eq(output.version, 4u);
	test::eq(seat.version, 7u);
	OutputState state;
	((wayland::WlOutput*)output).set_listener(&OUTPUT_LISTENER, &state);
	client.flush()!!;
	while (!state.done) client.dispatch()!!;
	test::eq(state.geometry_seen, true);
	test::eq(state.make_is_acme, true);
	test::eq(state.width, 2560u);
	t.join()!!;
}

fn void bind_rejects_the_wrong_interface() @test
{
	testing::MockServer server;
	Client client;
	start_pair(&server, &client);
	defer server.close();
	defer client.close();
	Global seat = { .name = 4, .version = 7, .interface_name = "wl_seat" };
	test::@error(client.bind(seat, wayland::WL_OUTPUT), error::INVALID_ARGUMENT);
}

fn void idle_notification_reports_idled_then_resumed() @test
{
	testing::MockServer server;
	Client client;
	start_pair(&server, &client);
	defer server.close();
	defer client.close();
	Thread t;
	t.create(&idle_scenario, &server)!!;
	client.roundtrip()!!;
	Global[] globals = client.globals_view();
	ext_idle_notify::ExtIdleNotifierV1* notifier = (ext_idle_notify::ExtIdleNotifierV1*)client.bind(
		globals[2],
		ext_idle_notify::EXT_IDLE_NOTIFIER_V1
	)!!;
	wayland::WlSeat* seat = (wayland::WlSeat*)client.bind(globals[3], wayland::WL_SEAT)!!;
	ext_idle_notify::ExtIdleNotificationV1* notification = notifier.get_idle_notification(5000, seat)!!;
	IdleState state;
	notification.set_listener(&IDLE_LISTENER, &state);
	client.flush()!!;
	while (!state.resumed) client.dispatch()!!;
	test::eq(state.idled, true);
	t.join()!!;
}

fn void gamma_ramp_is_passed_as_a_descriptor() @test
{
	testing::MockServer server;
	Client client;
	start_pair(&server, &client);
	defer server.close();
	defer client.close();
	Thread t;
	t.create(&gamma_scenario, &server)!!;
	client.roundtrip()!!;
	Global[] globals = client.globals_view();
	wayland::WlOutput* output = (wayland::WlOutput*)client.bind(globals[0], wayland::WL_OUTPUT)!!;
	wlr_gamma_control::ZwlrGammaControlManagerV1* manager = (wlr_gamma_control::ZwlrGammaControlManagerV1*)client.bind(
		globals[1],
		wlr_gamma_control::ZWLR_GAMMA_CONTROL_MANAGER_V1
	)!!;
	wlr_gamma_control::ZwlrGammaControlV1* control = manager.get_gamma_control(output)!!;
	GammaState state;
	control.set_listener(&GAMMA_LISTENER, &state);
	client.flush()!!;
	while (state.size == 0) client.dispatch()!!;
	test::eq(state.size, 256u);
	CInt[2] pipe_fds;
	test::eq(sys_pipe(&pipe_fds), 0);
	char[6] ramp = { 1, 2, 3, 4, 5, 6 };
	test::eq(sys_write(pipe_fds[1], &ramp, 6), (sz)6);
	display::native_close(pipe_fds[1]);
	control.set_gamma(pipe_fds[0])!!;
	display::native_close(pipe_fds[0]);
	client.flush()!!;
	t.join()!!;
}

fn void output_configuration_round_trips_server_objects() @test
{
	testing::MockServer server;
	Client client;
	start_pair(&server, &client);
	defer server.close();
	defer client.close();
	Thread t;
	t.create(&output_management_scenario, &server)!!;
	client.roundtrip()!!;
	Global[] globals = client.globals_view();
	wlr_output_management::ZwlrOutputManagerV1* manager = (wlr_output_management::ZwlrOutputManagerV1*)client.bind(
		globals[4],
		wlr_output_management::ZWLR_OUTPUT_MANAGER_V1
	)!!;
	OutputManagerState state;
	manager.set_listener(&MANAGER_LISTENER, &state);
	client.flush()!!;
	while (!state.done) client.dispatch()!!;
	test::eq(state.serial, 7u);
	test::eq(state.head_named, true);
	wlr_output_management::ZwlrOutputConfigurationV1* config = manager.create_configuration(state.serial)!!;
	config.set_listener(&CONFIG_LISTENER, &state);
	wlr_output_management::ZwlrOutputConfigurationHeadV1* config_head = config.enable_head(state.head)!!;
	config_head.set_mode(state.mode)!!;
	config.apply()!!;
	client.flush()!!;
	while (!state.succeeded) client.dispatch()!!;
	t.join()!!;
}

fn void selected_offer_is_received_through_a_pipe() @test
{
	testing::MockServer server;
	Client client;
	start_pair(&server, &client);
	defer server.close();
	defer client.close();
	Thread t;
	t.create(&data_control_scenario, &server)!!;
	client.roundtrip()!!;
	Global[] globals      = client.globals_view();
	wayland::WlSeat* seat = (wayland::WlSeat*)client.bind(globals[3], wayland::WL_SEAT)!!;
	wlr_data_control::ZwlrDataControlManagerV1* manager = (wlr_data_control::ZwlrDataControlManagerV1*)client.bind(
		globals[5],
		wlr_data_control::ZWLR_DATA_CONTROL_MANAGER_V1
	)!!;
	wlr_data_control::ZwlrDataControlDeviceV1* device = manager.get_data_device(seat)!!;
	OfferState state;
	device.set_listener(&DEVICE_LISTENER, &state);
	client.flush()!!;
	while (!state.selected_seen) client.dispatch()!!;
	CInt[2] pipe_fds;
	test::eq(sys_pipe(&pipe_fds), 0);
	state.selected.receive("text/plain", pipe_fds[1])!!;
	display::native_close(pipe_fds[1]);
	client.flush()!!;
	char[5] received;
	test::eq(sys_read(pipe_fds[0], &received, 5), (sz)5);
	test::eq(received[0], 'h');
	test::eq(received[4], 'o');
	display::native_close(pipe_fds[0]);
	t.join()!!;
}

fn void compositor_protocol_error_fails_the_roundtrip() @test
{
	testing::MockServer server;
	Client client;
	start_pair(&server, &client);
	defer server.close();
	defer client.close();
	Thread t;
	t.create(&protocol_error_scenario, &server)!!;
	test::@error(client.roundtrip(), error::PROTOCOL);
	test::eq(error::last().domain, error::Domain.WAYLAND);
	test::eq(error::last().code, 1);
	test::eq(error::last().message(), "object 3: bad request (error 1)");
	t.join()!!;
}