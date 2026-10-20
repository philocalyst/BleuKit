// DDC/CI on Linux through the simulated monitor of `bleu::ddc::mock`. The
// opener hands the mock to the real DDC path; no /dev/i2c-N is opened.
module bleu::brightness::linux_ddc_test @feat(LINUX);
import std::io::path, std::time, std::time::clock, bleu::brightness, bleu::observe, bleu::unit, bleu::ddc::mock, bleu::ddc::transport, bleu::ddc::vcp, bleu::rt::fs;

extern fn int symlink(char* target, char* linkpath);

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
	String drm = string::tformat("%s/sys/class/drm", root);
	path::mkdir((Path)string::tformat("%s/card1-DP-1", drm), true)!!;
	fs::write_text(string::tformat("%s/card1-DP-1/status", drm), "connected")!!;
	@pool()
	{
		assert(symlink("../../devices/i2c-7".zstr_tcopy(), string::tformat("%s/card1-DP-1/ddc", drm).zstr_tcopy()) == 0);
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
