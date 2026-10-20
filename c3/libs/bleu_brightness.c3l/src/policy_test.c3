module bleu::brightness::policy_test;
import bleu::brightness, bleu::availability, bleu::error, bleu::unit;
alias Ctl = Control;

// A device with a writable backlight, a read-only DDC and a writable gamma ramp.
fn Device mixed_device(Control[] storage) @local
{
	storage[0] = { .mechanism = Mechanism.BACKLIGHT, .readable = true, .writable = true };
	storage[1] = { .mechanism = Mechanism.DDC, .readable = true, .writable = false };
	storage[2] = { .mechanism = Mechanism.GAMMA, .readable = true, .writable = true };
	return { .id = "panel", .kind = DeviceKind.PANEL, .controls = storage };
}

fn void hardware_first_then_software_only_when_no_hardware() @test
{
	Ctl[3] storage;
	Device device = mixed_device(storage[..]);
	Mechanism[brightness::MAX_CONTROLS] out;
	usz n         = brightness::candidates(&device, brightness::prefer_hardware(), out[..]);
	assert(n == 1 && out[0] == Mechanism.BACKLIGHT, "PREFER_HARDWARE uses the writable backlight only");
	n = brightness::candidates(&device, brightness::allow_software(), out[..]);
	assert(n == 2 && out[0] == Mechanism.BACKLIGHT
		&& out[1] == Mechanism.GAMMA, "ALLOW_SOFTWARE adds the gamma ramp after the hardware");
	storage[0].writable = false;
	n = brightness::candidates(&device, brightness::prefer_hardware(), out[..]);
	assert(n == 1
		&& out[0] == Mechanism.GAMMA, "no writable hardware: PREFER_HARDWARE uses software and says so by mechanism");
}

fn void exact_names_one_mechanism_or_nothing() @test
{
	Ctl[3] storage;
	Device device = mixed_device(storage[..]);
	Mechanism[brightness::MAX_CONTROLS] out;
	assert(brightness::candidates(
		&device,
		brightness::exact(Mechanism.BACKLIGHT),
		out[..]
	) == 1, "EXACT on a writable control");
	assert(brightness::candidates(
		&device,
		brightness::exact(Mechanism.DDC),
		out[..]
	) == 0, "EXACT on a read-only control is refused");
	assert(brightness::candidates(
		&device,
		brightness::exact(Mechanism.OVERLAY),
		out[..]
	) == 0, "EXACT on a missing control is refused");
}

fn void refusal_names_the_reason() @test
{
	Ctl[3] storage;
	Device device = mixed_device(storage[..]);
	assert(brightness::refusal(
		&device,
		brightness::exact(Mechanism.OVERLAY)
	) == NOT_FOUND, "a missing control is NOT_FOUND");
	assert(brightness::refusal(
		&device,
		brightness::exact(Mechanism.DDC)
	) == error::UNAVAILABLE, "a read-only control is UNAVAILABLE");
	storage[1].availability = availability::no(availability::Reason.PERMISSION_NEEDED, "x");
	assert(brightness::refusal(
		&device,
		brightness::exact(Mechanism.DDC)
	) == error::PERMISSION_DENIED, "a permission reason maps to PERMISSION_DENIED");
	assert(brightness::refusal(
		&device,
		brightness::prefer_hardware()
	) == error::UNAVAILABLE, "no writable control at all is UNAVAILABLE");
}

fn void software_and_hardware_classes() @test
{
	assert(Mechanism.BACKLIGHT.is_software() == false && Mechanism.NATIVE.is_software() == false
		&& Mechanism.DDC.is_software() == false);
	assert(Mechanism.GAMMA.is_software() && Mechanism.OVERLAY.is_software());
	assert(Mechanism.KEYBOARD_LED.is_software() == false);
}