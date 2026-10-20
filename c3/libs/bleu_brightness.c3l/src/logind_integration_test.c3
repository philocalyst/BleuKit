// The logind route, against the private bus and logind stand-in that
// tests/run.sh starts. Without BLEU_BRIGHTNESS_BUS the tests do nothing, so the
// plain unit run passes; run.sh sets the variables.
module bleu::brightness::logind_integration_test @feat(LINUX);
import std::io, std::io::path, std::os::env, std::time, bleu::brightness, bleu::observe, bleu::rt::fs, bleu::unit;

fn String? variable(String name)
{
	return env::tget_var(name);
}

fn void logind_carries_the_write_when_it_implements_it() @test
{
	String? bus = variable("BLEU_BRIGHTNESS_BUS");
	if (catch err = bus) return;
	String root = variable("BLEU_BRIGHTNESS_ROOT")!!;
	String mode = variable("BLEU_BRIGHTNESS_MODE")!!;
	Brightness* service = brightness::open(mem, { .backend = LINUX, .root = root, .bus_address = bus, .poll = time::ms(100), .transition_step = time::ms(10) })!!;
	defer service.close();
	Snapshot{State}* first = service.wait_after(0, time::ms(5000))!!;
	first.release();
	SetOperation* op = service.set_level("intel_backlight", (Level)0.25f)!!;
	defer op.release();
	Applied applied = op.wait(time::ms(5000))!!;
	assert(applied.raw == 24_000, "0.25 of 96000");
	long written = fs::read_integer(string::tformat("%s/sys/class/backlight/intel_backlight/brightness", root))!!;
	assert(written == 24_000, "the setpoint is 24000 whichever route carried it");
	String log = fs::read_file(tmem, string::tformat("%s/mock-calls.log", root)) ?? "";
	if (mode == "ok")
	{
		assert(log.contains("backlight intel_backlight 24000"), "logind received SetBrightness(backlight, intel_backlight, 24000)");
	}
	else
	{
		assert(log.len == 0, "logind does not implement SetBrightness, so no call was logged");
	}
	SetOperation* led = service.set_level("input5::kbd_backlight", (Level)0.66f)!!;
	defer led.release();
	Applied led_applied = led.wait(time::ms(5000))!!;
	assert(led_applied.raw == 2);
	if (mode == "ok")
	{
		assert(fs::read_file(tmem, string::tformat("%s/mock-calls.log", root))!!.contains("leds input5::kbd_backlight 2"), "keyboard LEDs go through logind too");
	}
}
