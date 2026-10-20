// Service-level tests of the Linux backend on a fake root: sysfs backlight and
// LEDs, DRM connectors, the sysfs fallback for writes, and the policy refusals.
module bleu::brightness::linux_test @feat(LINUX);
import std::io::path, std::time, std::time::clock, bleu::availability, bleu::brightness, bleu::observe, bleu::ddc::mock, bleu::ddc::transport, bleu::ddc::vcp, bleu::error, bleu::rt::fs, bleu::unit;

extern fn int symlink(char* target, char* linkpath);

// An address nothing listens on, so logind is unreachable and the sysfs route carries writes.
const String NO_BUS = "unix:path=/nonexistent-bleu-brightness-bus";

// Build a fake root with a firmware backlight, a raw backlight, a keyboard LED and one connected DRM connector with a DDC bus.
fn String fake_root(String stem) @local
{
	String root = string::tformat("/tmp/bleu-brightness-%s-%d", stem, clock::now());
	String bl   = string::tformat("%s/sys/class/backlight", root);
	String leds = string::tformat("%s/sys/class/leds", root);
	String drm  = string::tformat("%s/sys/class/drm", root);
	path::mkdir((Path)string::tformat("%s/intel_backlight", bl), true)!!;
	path::mkdir((Path)string::tformat("%s/acpi_video0", bl), true)!!;
	path::mkdir((Path)string::tformat("%s/input5::kbd_backlight", leds), true)!!;
	path::mkdir((Path)string::tformat("%s/card1-DP-1", drm), true)!!;
	path::mkdir((Path)string::tformat("%s/card1-HDMI-A-1", drm), true)!!;
	fs::write_text(string::tformat("%s/intel_backlight/type", bl), "firmware")!!;
	fs::write_text(string::tformat("%s/intel_backlight/brightness", bl), "48000")!!;
	fs::write_text(string::tformat("%s/intel_backlight/actual_brightness", bl), "48000")!!;
	fs::write_text(string::tformat("%s/intel_backlight/max_brightness", bl), "96000")!!;
	fs::write_text(string::tformat("%s/acpi_video0/type", bl), "raw")!!;
	fs::write_text(string::tformat("%s/acpi_video0/brightness", bl), "7")!!;
	fs::write_text(string::tformat("%s/acpi_video0/max_brightness", bl), "15")!!;
	fs::write_text(string::tformat("%s/input5::kbd_backlight/brightness", leds), "1")!!;
	fs::write_text(string::tformat("%s/input5::kbd_backlight/max_brightness", leds), "3")!!;
	fs::write_text(string::tformat("%s/card1-DP-1/status", drm), "connected")!!;
	fs::write_text(string::tformat("%s/card1-HDMI-A-1/status", drm), "disconnected")!!;
	@pool()
	{
		int linked = symlink("../../devices/i2c-7".zstr_tcopy(), string::tformat("%s/card1-DP-1/ddc", drm)
			.zstr_tcopy());
		assert(linked == 0, "the fake DDC link is created");
	};
	return root;
}

fn Options options_for(String root) @local
{
	return {
		.backend = LINUX,
		.root = root,
		.bus_address = NO_BUS,
		.poll = time::ms(50),
		.transition_step = time::ms(10)
	};
}

fn Control? find_control(State* state, String id, Mechanism mechanism) @local
{
	foreach (&device : state.devices)
	{
		if (device.id != id) continue;
		foreach (&control : device.controls)
		{
			if (control.mechanism == mechanism) return *control;
		}
	}
	return NOT_FOUND~;
}

fn void reads_the_panel_keyboard_and_monitor_controls() @test
{
	String root         = fake_root("read");
	Brightness* service = brightness::open(mem, options_for(root))!!;
	defer service.close();
	assert(service.backend_name() == "linux");
	Snapshot{State}* snapshot = service.wait_after(0, time::ms(3000))!!;
	defer snapshot.release();
	State* state = &snapshot.value;
	assert(state.devices.len == 3, "panel, keyboard and one connected monitor");
	Control panel = find_control(state, "intel_backlight", Mechanism.BACKLIGHT)!!;
	assert(panel.readable && panel.writable && (float)panel.level.value > 0.49f && (float)panel.level.value < 0.51f);
	assert(panel.raw.value == 48_000 && panel.raw_max == 96_000, "the raw value and its range are reported");
	assert(@catch(
		find_control(state, "intel_backlight", Mechanism.GAMMA)
	) == NOT_FOUND, "gamma is not built on Linux, so no gamma control");
	Control led = find_control(state, "input5::kbd_backlight", Mechanism.KEYBOARD_LED)!!;
	assert(led.raw_max == 3 && led.raw.value == 1);
	Control ddc = find_control(state, "card1-DP-1", Mechanism.DDC)!!;
	assert(!ddc.readable
		&& !ddc.writable, "the bus does not exist here, so the monitor is listed but not controllable");
	assert(ddc.availability.reason == availability::Reason.HARDWARE_ABSENT);
}

fn void capabilities_say_what_is_not_built() @test
{
	String root         = fake_root("caps");
	Brightness* service = brightness::open(mem, options_for(root))!!;
	defer service.close();
	assert(service.capability(Cap.SET_BACKLIGHT).ok() && service.capability(Cap.TRANSITION).ok());
	assert(service.capability(Cap.SET_NATIVE).reason == availability::Reason.UNSUPPORTED_OS);
	assert(service.capability(Cap.SET_GAMMA).reason == availability::Reason.UNSUPPORTED_BACKEND);
	assert(service.capability(Cap.SET_OVERLAY).reason == availability::Reason.UNSUPPORTED_BACKEND);
}

fn void a_write_lands_in_the_setpoint_when_logind_is_absent() @test
{
	String root         = fake_root("write");
	Brightness* service = brightness::open(mem, options_for(root))!!;
	defer service.close();
	Snapshot{State}* first = service.wait_after(0, time::ms(3000))!!;
	first.release();
	SetOperation* op = service.set_level("intel_backlight", (Level)0.25f)!!;
	defer op.release();
	Applied applied = op.wait(time::ms(3000))!!;
	assert(applied.mechanism == Mechanism.BACKLIGHT && applied.raw == 24_000, "0.25 of 96000 is 24000");
	long written = fs::read_integer(string::tformat("%s/sys/class/backlight/intel_backlight/brightness", root))!!;
	assert(written == 24_000, "the sysfs setpoint holds the value");
	assert(applied.read_back.has_value, "the device is read back after the write");
}

fn void a_transition_ends_at_its_target() @test
{
	String root         = fake_root("ramp");
	Brightness* service = brightness::open(mem, options_for(root))!!;
	defer service.close();
	Snapshot{State}* first = service.wait_after(0, time::ms(3000))!!;
	first.release();
	SetOperation* op = service.set_level(
		"intel_backlight",
		(Level)0.75f,
		brightness::allow_software(),
		(Duration)100_000
	)!!;
	defer op.release();
	Applied applied = op.wait(time::ms(3000))!!;
	assert(applied.raw == 72_000, "the ramp finishes on 0.75");
	long written = fs::read_integer(string::tformat("%s/sys/class/backlight/intel_backlight/brightness", root))!!;
	assert(written == 72_000);
}

fn void keyboard_led_is_set_by_its_own_name() @test
{
	String root         = fake_root("led");
	Brightness* service = brightness::open(mem, options_for(root))!!;
	defer service.close();
	Snapshot{State}* first = service.wait_after(0, time::ms(3000))!!;
	first.release();
	SetOperation* op = service.set_level("input5::kbd_backlight", (Level)0.66f)!!;
	defer op.release();
	Applied applied = op.wait(time::ms(3000))!!;
	assert(applied.mechanism == Mechanism.KEYBOARD_LED && applied.raw == 2, "0.66 of 3 rounds to 2");
}

fn void refusals_are_explicit() @test
{
	String root         = fake_root("refuse");
	Brightness* service = brightness::open(mem, options_for(root))!!;
	defer service.close();
	Snapshot{State}* first = service.wait_after(0, time::ms(3000))!!;
	first.release();
	SetOperation* gamma = service.set_level("intel_backlight", (Level)0.5f, brightness::exact(Mechanism.GAMMA))!!;
	defer gamma.release();
	if (catch err = gamma.wait(time::ms(3000)))
	{
		assert(err == NOT_FOUND, "EXACT(GAMMA) on a device with no gamma control is NOT_FOUND");
	}
	else
	{
		assert(false, "a gamma request must not succeed on Linux");
	}
	SetOperation* missing = service.set_level("no-such-device", (Level)0.5f)!!;
	defer missing.release();
	if (catch err = missing.wait(time::ms(3000)))
	{
		assert(err == NOT_FOUND);
	}
	else
	{
		assert(false, "an unknown device is NOT_FOUND");
	}
	SetOperation* monitor = service.set_level("card1-DP-1", (Level)0.5f, brightness::exact(Mechanism.DDC))!!;
	defer monitor.release();
	if (catch err = monitor.wait(time::ms(3000)))
	{
		assert(err == error::PERMISSION_DENIED
			|| err == error::UNAVAILABLE, "an unreachable monitor is refused, not dimmed");
	}
	else
	{
		assert(false, "a monitor without a bus must not succeed");
	}
	assert(@catch(service.set_level("", (Level)0.5f)) == error::INVALID_ARGUMENT, "an empty id is rejected at once");
}