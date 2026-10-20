<*
 The wlr backend against the in-process compositor of bleu_wl (`bleu::wl::testing::MockServer`):
 the real client code runs on the service's worker, and a scenario thread plays the compositor.
 Every request the backend sends is checked, and every event the compositor sends is one the
 protocol defines. The ramps the compositor reads back are checked word by word.
*>
module bleu::color::linux_wlr_test @feat(LINUX);
import bleu::color, bleu::color::linux_wlr, bleu::error, bleu::observe, bleu::rt, bleu::rt::foreign, bleu::rt::unix, bleu::unit, bleu::wl, bleu::wl::display, bleu::wl::testing, bleu::wl::wire, bleu::wl::proto::wayland, bleu::wl::proto::wlr_gamma_control, std::thread, std::time, std::core::mem, std::math;

// Read from a descriptor (the compositor's side of a ramp), without changing this test's state.
extern fn sz sys_read(int fd, void* buffer, usz count) @cname("read");

// The descriptor the seam hands the backend, once.
struct Seam
{
	rt::Native fd;
}

fn rt::Native? seam_connect(void* context)
{
	Seam* seam = (Seam*)context;
	return seam.fd;
}

// A check that fails the scenario thread with a message.
fn void expect(bool ok, String what)
{
	if (!ok) unreachable(what);
}

// Receive the next request and check its object and opcode.
fn testing::Message expect_request(testing::MockServer* s, uint object, ushort opcode)
{
	testing::Message message = s.receive()!!;
	expect(message.object == object && message.opcode == opcode, "unexpected request from the client");
	return message;
}

// The client's sync: its callback id, which the answer must name.
fn uint expect_sync(testing::MockServer* s)
{
	testing::Message message = expect_request(s, display::DISPLAY_ID, 0);
	return s.reader(message).get_new_id()!!;
}

fn uint expect_get_registry(testing::MockServer* s)
{
	testing::Message message = expect_request(s, display::DISPLAY_ID, 1);
	return s.reader(message).get_new_id()!!;
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
	done.begin(callback, 0);
	done.put_uint(1)!!;
	s.send(&done)!!;
	wire::Writer released;
	released.begin(display::DISPLAY_ID, 1);
	released.put_uint(callback)!!;
	s.send(&released)!!;
}

// Receive a bind on the registry and return the new object's id.
fn uint expect_bind(testing::MockServer* s, uint registry, uint name, String interface_name, uint version)
{
	testing::Message bind = expect_request(s, registry, 0);
	wire::Reader r        = s.reader(bind);
	expect(r.get_uint()!! == name, "bind of the wrong global");
	expect(r.get_string()!! == interface_name, "bind of the wrong interface");
	expect(r.get_uint()!! == version, "bind at the wrong version");
	return r.get_new_id()!!;
}

// An output's name event (version 4) and its done.
fn void send_output_name(testing::MockServer* s, uint output, String name)
{
	wire::Writer w;
	w.begin(output, 4);
	w.put_string(name)!!;
	s.send(&w)!!;
}

fn void send_output_done(testing::MockServer* s, uint output)
{
	wire::Writer w;
	w.begin(output, 2);
	s.send(&w)!!;
}

// gamma_size: the number of entries in each ramp.
fn void send_gamma_size(testing::MockServer* s, uint control, uint size)
{
	wire::Writer w;
	w.begin(control, 0);
	w.put_uint(size)!!;
	s.send(&w)!!;
}

// failed: the control is no longer valid; the client must destroy it.
fn void send_failed(testing::MockServer* s, uint control)
{
	wire::Writer w;
	w.begin(control, 1);
	s.send(&w)!!;
}

// The registry, the outputs, and the manager. Returns the output and manager ids.
fn void startup(testing::MockServer* s, uint* output, uint* manager)
{
	uint registry = expect_get_registry(s);
	uint first    = expect_sync(s);
	send_global(s, registry, 1, "wl_output", 4);
	send_global(s, registry, 2, "zwlr_gamma_control_manager_v1", 1);
	answer_sync(s, first);
	*output  = expect_bind(s, registry, 1, "wl_output", 4);
	*manager = expect_bind(s, registry, 2, "zwlr_gamma_control_manager_v1", 1);
	uint names = expect_sync(s);
	send_output_name(s, *output, "DP-1");
	send_output_done(s, *output);
	answer_sync(s, names);
}

// A request for an output's gamma control: returns the control's id.
fn uint expect_get_gamma(testing::MockServer* s, uint manager, uint output)
{
	testing::Message message = expect_request(s, manager, 0);
	wire::Reader r           = s.reader(message);
	uint control             = r.get_new_id()!!;
	expect(r.get_object()!! == output, "gamma control for the wrong output");
	return control;
}

// The ramp descriptor of a set_gamma: the compositor reads three tables of 16-bit words.
fn void expect_ramp(testing::MockServer* s, uint control, ushort[6] expected)
{
	testing::Message message = expect_request(s, control, 0);
	rt::Native fd            = s.reader(message).get_fd()!!;
	ushort[768] words;
	sz got = sys_read(fd, &words, 1536);
	display::native_close(fd);
	expect(got == 1536, "the ramp descriptor holds three tables of 256 words");
	// Red, green and blue at full scale (index 255), then at index 128, each within one word.
	usz[6] at = { 255, 256 + 255, 512 + 255, 128, 256 + 128, 512 + 128 };
	for (usz i = 0; i < 6; i++)
	{
		expect(math::abs((long)words[at[i]] - (long)expected[i]) <= 1, "a ramp word is not the expected value");
	}
	expect(words[0] == 0 && words[256] == 0 && words[512] == 0, "a ramp starts at zero");
}

// 2700 K, brightness 1: the words the table gives (see docs/research/color_impl.md, section 3).
const ushort[6] RAMP_2700_FULL = { 65535, 44332, 22798, 32896, 22253, 11443 };

// 2700 K, brightness 0.5: the same ramp, halved.
const ushort[6] RAMP_2700_HALF = { 32768, 22166, 11399, 16448, 11126, 5722 };

// Expire the mock's view of a control that was destroyed: the client's destroy.
fn void expect_destroy(testing::MockServer* s, uint control)
{
	expect_request(s, control, 1);
}

// The full life of a ramp: acquire, write, dim, release, reacquire, and release at close.
fn int full_scenario(void* arg)
{
	foreign::@foreign_entry()
	{
		testing::MockServer* s = (testing::MockServer*)arg;
		uint output;
		uint manager;
		startup(s, &output, &manager);
		// Measuring: the control is taken, sized, and destroyed.
		uint measured = expect_get_gamma(s, manager, output);
		uint sync     = expect_sync(s);
		send_gamma_size(s, measured, 256);
		answer_sync(s, sync);
		expect_destroy(s, measured);
		// set_temperature("DP-1", 2700): acquire, write.
		uint first = expect_get_gamma(s, manager, output);
		uint round = expect_sync(s);
		send_gamma_size(s, first, 256);
		answer_sync(s, round);
		expect_ramp(s, first, RAMP_2700_FULL);
		// set_dim(ALL, 0.5): the control is held, so only the ramp is sent.
		expect_ramp(s, first, RAMP_2700_HALF);
		// reset: neutral, so the control is released.
		expect_destroy(s, first);
		// set_temperature(ALL, 2700) again: acquired anew.
		uint second = expect_get_gamma(s, manager, output);
		uint again  = expect_sync(s);
		send_gamma_size(s, second, 256);
		answer_sync(s, again);
		expect_ramp(s, second, RAMP_2700_FULL);
		// close: the control is destroyed (the compositor restores its table), then the connection ends.
		expect_destroy(s, second);
		// The connection is closed by the client now; the receive fails and the scenario ends.
		if (catch s.receive()) {}
	};
	return 0;
}

// The control is refused at measuring: the output reports refused and BUSY.
fn int refused_scenario(void* arg)
{
	foreign::@foreign_entry()
	{
		testing::MockServer* s = (testing::MockServer*)arg;
		uint output;
		uint manager;
		startup(s, &output, &manager);
		uint measured = expect_get_gamma(s, manager, output);
		uint sync     = expect_sync(s);
		send_failed(s, measured);
		answer_sync(s, sync);
		expect_destroy(s, measured);
		if (catch s.receive()) {}
	};
	return 0;
}

// The control is taken and written, then the compositor takes it back with `failed`.
fn int lost_scenario(void* arg)
{
	foreign::@foreign_entry()
	{
		testing::MockServer* s = (testing::MockServer*)arg;
		uint output;
		uint manager;
		startup(s, &output, &manager);
		uint measured = expect_get_gamma(s, manager, output);
		uint sync     = expect_sync(s);
		send_gamma_size(s, measured, 256);
		answer_sync(s, sync);
		expect_destroy(s, measured);
		uint first = expect_get_gamma(s, manager, output);
		uint round = expect_sync(s);
		send_gamma_size(s, first, 256);
		answer_sync(s, round);
		expect_ramp(s, first, RAMP_2700_FULL);
		// Another client takes the output: the client destroys the control when it hears this.
		send_failed(s, first);
		expect_destroy(s, first);
		if (catch s.receive()) {}
	};
	return 0;
}

// The test's service: the seam's descriptor, the forced wlr backend, a short tick.
fn Color*? open_on(Seam* seam)
{
	return color::open(mem, {
		.backend = Backend.WLR_GAMMA,
		.tick = time::ms(50),
		.connect = &seam_connect,
		.connect_context = seam,
	});
}

fn void full_exchange_writes_and_releases_the_ramp() @test
{
	unix::SocketPair pair = unix::socket_pair(unix::SocketKind.STREAM)!!;
	testing::MockServer server;
	server.attach(pair.second);
	defer server.close();
	Seam seam = { .fd = pair.first.fd.release() };
	Thread t;
	t.create(&full_scenario, &server)!!;
	Color* color = open_on(&seam)!!;
	assert(color.backend_name() == "wlr-gamma");
	Snapshot{State}* first = color.wait_after(0, time::sec(5))!!;
	assert(first.value.outputs.len == 1 && first.value.outputs[0].id == "DP-1" && first.value.outputs[0].name == "DP-1");
	assert(first.value.outputs[0].control.gamma_supported && first.value.outputs[0].control.size == 256);
	assert(!first.value.outputs[0].control.active && !first.value.outputs[0].control.refused);
	first.release();
	ApplyOperation* missing = color.set_temperature("HDMI-9", (Kelvin)2700)!!;
	assert(@catch(missing.wait(time::sec(5))) == NOT_FOUND, "an output that does not exist is NOT_FOUND");
	missing.release();
	ApplyOperation* warm = color.set_temperature("DP-1", (Kelvin)2700)!!;
	Applied applied = warm.wait(time::sec(5))!!;
	assert(applied.outputs == 1 && applied.temperature.value == (Kelvin)2700, "one display written at 2700 K");
	warm.release();
	ApplyOperation* dim = color.set_dim(color::ALL_OUTPUTS, (Level)0.5f)!!;
	assert(dim.wait(time::sec(5))!!.outputs == 1, "the ramp is dimmed");
	dim.release();
	ApplyOperation* reset = color.reset()!!;
	assert(reset.wait(time::sec(5))!!.outputs == 1, "reset releases the display");
	reset.release();
	ApplyOperation* again = color.set_temperature(color::ALL_OUTPUTS, (Kelvin)2700)!!;
	assert(again.wait(time::sec(5))!!.outputs == 1, "the control is taken again");
	again.release();
	color.close();
	t.join()!!;
}

fn void a_refused_output_is_busy_and_holds_nothing() @test
{
	unix::SocketPair pair = unix::socket_pair(unix::SocketKind.STREAM)!!;
	testing::MockServer server;
	server.attach(pair.second);
	defer server.close();
	Seam seam = { .fd = pair.first.fd.release() };
	Thread t;
	t.create(&refused_scenario, &server)!!;
	Color* color = open_on(&seam)!!;
	Snapshot{State}* state = color.wait_after(0, time::sec(5))!!;
	assert(state.value.outputs[0].control.refused, "the compositor refused the control");
	assert(!state.value.outputs[0].control.gamma_supported, "a refused output without a table is not supported");
	state.release();
	ApplyOperation* operation = color.set_temperature(color::ALL_OUTPUTS, (Kelvin)2700)!!;
	assert(@catch(operation.wait(time::sec(5))) == error::BUSY, "a refused control is BUSY");
	operation.release();
	color.close();
	t.join()!!;
}

fn void losing_the_control_later_is_reported() @test
{
	unix::SocketPair pair = unix::socket_pair(unix::SocketKind.STREAM)!!;
	testing::MockServer server;
	server.attach(pair.second);
	defer server.close();
	Seam seam = { .fd = pair.first.fd.release() };
	Thread t;
	t.create(&lost_scenario, &server)!!;
	Color* color = open_on(&seam)!!;
	Snapshot{State}* before = color.wait_after(0, time::sec(5))!!;
	ulong generation = before.generation;
	before.release();
	ApplyOperation* operation = color.set_temperature(color::ALL_OUTPUTS, (Kelvin)2700)!!;
	assert(operation.wait(time::sec(5))!!.outputs == 1, "written before the control is lost");
	operation.release();
	// The compositor's `failed` arrives on the connection; the state then says the control is refused.
	Snapshot{State}* after = color.wait_after(generation, time::sec(5))!!;
	while (!after.value.outputs[0].control.refused)
	{
		generation = after.generation;
		after.release();
		after = color.wait_after(generation, time::sec(5))!!;
	}
	assert(!after.value.outputs[0].control.active, "a lost control is not held");
	after.release();
	color.close();
	t.join()!!;
}
