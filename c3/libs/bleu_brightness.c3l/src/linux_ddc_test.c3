// DDC/CI on Linux through the simulated monitor of `bleu::ddc::mock`. The
// opener hands the mock to the real DDC path; no /dev/i2c-N is opened.
module bleu::brightness::linux_ddc_test @feat(LINUX);
import std::io::path, std::time, std::time::clock, bleu::brightness, bleu::brightness::linux_ddc, bleu::error, bleu::observe, bleu::unit, bleu::ddc::mock, bleu::ddc::transport, bleu::ddc::vcp, bleu::rt::fs;

extern fn int symlink(char* target, char* linkpath);
extern fn int fcntl(int fd, int command, ...);

// `F_GETFD` from fcntl.h: asks whether a descriptor is open.
const int F_GETFD = 1;

const String NO_BUS = "unix:path=/nonexistent-bleu-brightness-bus";

// The simulated monitor the opener returns.
fn Transport? open_mock(void* context, String device_path)
{
	MockMonitor* monitor = (MockMonitor*)context;
	return monitor;
}

fn void monitor_luminance_is_read_and_written() @test
{
	String root = string::tformat("/tmp/bleu-brightness-ddc-%d", clock::now());
	String drm  = string::tformat("%s/sys/class/drm", root);
	path::mkdir((Path)string::tformat("%s/card1-DP-1", drm), true)!!;
	fs::write_text(string::tformat("%s/card1-DP-1/status", drm), "connected")!!;
	@pool()
	{
		assert(symlink("../../devices/i2c-7".zstr_tcopy(), string::tformat("%s/card1-DP-1/ddc", drm)
			.zstr_tcopy()) == 0);
	};
	MockMonitor monitor = mock::new_monitor("(vcp(10))");
	monitor.add_feature(vcp::VcpCode.LUMINANCE, 30, 100);
	Options options = {
		.backend = LINUX,
		.root = root,
		.bus_address = NO_BUS,
		.poll = time::ms(500),
		.transition_step = time::ms(10),
		.open_bus = &open_mock,
		.open_bus_context = &monitor,
	};
	Brightness* service = brightness::open(mem, options)!!;
	defer service.close();
	Snapshot{State}* first = service.wait_after(0, time::ms(5000))!!;
	defer first.release();
	bool found = false;
	foreach (&device : first.value.devices)
	{
		if (device.id != "card1-DP-1") continue;
		found = true;
		Control* control = device.control(Mechanism.DDC);
		assert(control != null && control.readable && control.writable, "the monitor's luminance is readable");
		assert((float)control.level.value > 0.29f && (float)control.level.value < 0.31f, "30 of 100");
		assert(control.raw_max == 100);
	}
	assert(found, "the connected connector is a device");
	assert(service.capability(Cap.SET_DDC).ok());
	SetOperation* op = service.set_level("card1-DP-1", (Level)0.5f, brightness::exact(Mechanism.DDC))!!;
	defer op.release();
	Applied applied = op.wait(time::ms(5000))!!;
	assert(applied.mechanism == Mechanism.DDC && applied.raw == 50);
	assert(monitor.value(vcp::VcpCode.LUMINANCE) == 50, "the monitor's own store holds the new value");
	assert(applied.read_back.has_value && (float)applied.read_back.value > 0.49f, "the monitor reports it back");
}

// A display on a simulated monitor, attached through the opener and read once.
fn DdcDisplay attached_display(MockMonitor* monitor) @local
{
	DdcDisplay display = { .connector = "card1-DP-1", .bus = 7 };
	display.attach("/nonexistent-bleu-brightness-root", &open_mock, monitor);
	assert(display.opened, "the injected monitor opens the display");
	return display;
}

// The display was never opened on /dev/i2c-N, so it owns no descriptor: detach must not close fd 0.
fn void detach_leaves_an_injected_bus_alone() @test
{
	MockMonitor monitor = mock::new_monitor("(vcp(10))");
	monitor.add_feature(vcp::VcpCode.LUMINANCE, 30, 100);
	DdcDisplay display = attached_display(&monitor);
	int before         = fcntl(0, F_GETFD);
	assert(before >= 0, "the test process has its standard input open");
	display.detach();
	assert(!display.opened, "the display is unopened after detach");
	assert(fcntl(0, F_GETFD) == before, "detach does not close a descriptor it did not open");
}

// The monitor takes a write only after 1000 more reads, so the read-back still shows the old value.
fn void a_monitor_that_ignores_the_write_is_an_error() @test
{
	MockMonitor monitor = mock::new_monitor("(vcp(10))");
	monitor.add_feature(vcp::VcpCode.LUMINANCE, 30, 100);
	monitor.lag_reads = 1000;
	DdcDisplay display = attached_display(&monitor);
	Control first      = display.read();
	assert(first.readable, "the luminance is read before the write");
	if (catch err = display.write((Level)0.5f))
	{
		assert(err == error::BACKEND_FAILURE, "the device did not take the value");
	}
	else
	{
		assert(false, "a write the monitor did not take must not succeed");
	}
}

// A transfer that fails keeps the range learnt earlier: the control is unreadable, but still writable.
fn void a_failed_read_keeps_the_range() @test
{
	MockMonitor monitor = mock::new_monitor("(vcp(10))");
	monitor.add_feature(vcp::VcpCode.LUMINANCE, 30, 100);
	DdcDisplay display = attached_display(&monitor);
	assert(display.read().readable, "the first read succeeds");
	monitor.drop_replies = 1000;
	Control control = display.read();
	assert(!control.readable, "a failed read is not a reading");
	assert(control.writable && control.availability.ok(), "the range is still known");
	assert(control.raw_max == 100, "the last known range is kept");
}