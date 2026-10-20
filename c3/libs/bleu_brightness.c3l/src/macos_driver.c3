<*
 The macOS backend: the built-in panel through DisplayServices (private, resolved at
 run time; see `macos_displayservices_private.c3`), with the display list from
 CoreGraphics.

 Only built-in panels are reported. DDC/CI on external displays (IOAVService and
 IOFramebuffer I2C) is deferred to a later version, as docs/research/display.md
 section 6 cuts it. Brightness-key changes are seen by the poll, not by
 DisplayServices' change notification, whose callback semantics the research
 could not verify.

 COMPILED ONLY. Type-checked for macOS; never run.
*>
module bleu::brightness::macos @feat(DARWIN) @link("CoreGraphics.framework");
import std::collections::list, std::collections::maybe, std::time, bleu::availability, bleu::brightness, bleu::brightness::displayservices, bleu::error, bleu::rt::worker, bleu::unit;

<* Room for the displays of one machine; more are ignored. *>
const usz MAX_DISPLAYS = 32;

<* Native brightness is a float in 0..1; its raw value is that float in thousandths. *>
const long NATIVE_STEPS = 1000;

extern fn int getActiveDisplayList(uint max, uint* displays, uint* count) @cname("CGGetActiveDisplayList");
extern fn uint displayIsBuiltin(uint display) @cname("CGDisplayIsBuiltin");

<* The backend's state. *>
struct MacOS
{
	Allocator allocator;
	Duration poll;
	Duration step;
	bool native_ready;
	displayservices::Native native;
	Platform platform;
}

const Driver DRIVER = {
	.info = { "macos", "DisplayServices (private) for built-in panels", 10 },
	.id = MACOS,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

fn bool probe(Options* options) => true;

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	capabilities.values[Cap.SET_BACKLIGHT.ordinal] = availability::no(
		UNSUPPORTED_OS,
		"the backlight is Linux and Windows only"
	);
	capabilities.values[Cap.SET_DDC.ordinal] = availability::no(
		UNSUPPORTED_BACKEND,
		"DDC/CI on macOS is deferred to a later version"
	);
	capabilities.values[Cap.SET_GAMMA.ordinal] = availability::no(
		UNSUPPORTED_BACKEND,
		"gamma dimming is not built for macOS yet"
	);
	capabilities.values[Cap.SET_OVERLAY.ordinal] = availability::no(
		UNSUPPORTED_BACKEND,
		"overlay dimming is not built"
	);
	capabilities.values[Cap.SET_KEYBOARD_LED.ordinal] = availability::no(
		UNSUPPORTED_BACKEND,
		"the keyboard backlight is not built for macOS"
	);
	MacOS* self = alloc::new(
		allocator,
		MacOS,
		{
			.allocator = allocator,
			.poll = options.poll,
			.step = options.transition_step,
			.platform = { .read = &read_state, .write = &write_control },
		}
	);
	self.platform.context = self;
	if (catch displayservices::open_native(&self.native))
	{
		capabilities.values[Cap.SET_NATIVE.ordinal] = availability::no(
			BACKEND_MISSING,
			"DisplayServices is not present (private framework)"
		);
	}
	else
	{
		self.native_ready = true;
	}
	return self;
}

fn void destroy(Allocator allocator, void* state)
{
	alloc::free(allocator, state);
}

fn void run(void* state, BrightnessHub* hub, Host{Command}* host)
{
	MacOS* self = (MacOS*)state;
	brightness::serve(hub, host, &self.platform, self.poll, self.step);
}

// The displays CoreGraphics lists, in temporary memory.
fn uint[]? active_displays()
{
	uint[MAX_DISPLAYS] buffer;
	uint count = 0;
	if (getActiveDisplayList((uint)MAX_DISPLAYS, buffer[..].ptr, &count) != 0)
	{
		return error::raise(error::BACKEND_FAILURE, error::Domain.MACH, 0, "CGGetActiveDisplayList failed")~;
	}
	return alloc::clone_slice(tmem, buffer[0:(usz)count]);
}

<* Read the built-in panels. External displays are not reported (DDC/CI is deferred). *>
fn State? read_state(void* context, Allocator allocator)
{
	MacOS* self = (MacOS*)context;
	@pool()
	{
		List{Device} devices;
		devices.init(tmem);
		uint[] displays = active_displays() ?? { };
		foreach (display : displays)
		{
			if (!displayIsBuiltin(display)) continue;
			List{Control} controls;
			controls.init(tmem);
			controls.push(self.native_control(display));
			brightness::add_device(
				allocator,
				&devices,
				string::tformat("cg-%d", display),
				"built-in panel",
				DeviceKind.PANEL,
				controls.array_view()
			);
		}
		return { .devices = alloc::clone_slice(allocator, devices.array_view()) };
	};
}

// The NATIVE control of one display: readable when DisplayServices can read it, writable when it can change it.
fn Control MacOS.native_control(&self, uint display)
{
	if (!self.native_ready)
	{
		return {
			.mechanism = Mechanism.NATIVE,
			.availability = availability::no(BACKEND_MISSING, "DisplayServices is not present")
		};
	}
	if (!self.native.api.can_change(display))
	{
		return {
			.mechanism = Mechanism.NATIVE,
			.availability = availability::no(HARDWARE_ABSENT, "the display does not accept a brightness change")
		};
	}
	float value = 0;
	if (self.native.api.get_brightness(display, &value) != 0)
	{
		return { .mechanism = Mechanism.NATIVE, .writable = true, .availability = availability::YES };
	}
	long raw = (long)(value * (float)NATIVE_STEPS);
	return {
		.mechanism = Mechanism.NATIVE,
		.readable = true,
		.writable = true,
		.availability = availability::YES,
		.level = maybe::value(unit::from_raw(raw, 0, NATIVE_STEPS)),
		.raw = maybe::value(raw),
		.raw_min = 0,
		.raw_max = NATIVE_STEPS,
	};
}

<* Carry out one write: only NATIVE exists on macOS for now. *>
fn Applied? write_control(void* context, String device_id, Mechanism mechanism, Level level)
{
	MacOS* self = (MacOS*)context;
	switch (mechanism)
	{
		case Mechanism.NATIVE: return self.write_native(device_id, level);
		case Mechanism.BACKLIGHT:
		case Mechanism.DDC:
		case Mechanism.GAMMA:
		case Mechanism.OVERLAY:
		case Mechanism.KEYBOARD_LED: return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "%s is not built for macOS", mechanism)~;
	}
}

fn Applied? MacOS.write_native(&self, String device_id, Level level)
{
	if (!self.native_ready) return error::raise(
		error::UNSUPPORTED,
		error::Domain.INTERNAL,
		0,
		"DisplayServices is not present"
	)~;
	if (!device_id.starts_with(
		"cg-"
	)) return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "'%s' is not a display", device_id)~;
	// The display number is every character after "cg-", and each must be a digit.
	uint display = 0;
	if (device_id.len == 3) return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "'%s' names no display", device_id)~;
	for (usz i = 3; i < device_id.len; i++)
	{
		char c = device_id[i];
		if (c < '0' || c > '9') return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "'%s' is not a display", device_id)~;
		display = display * 10 + (uint)(c - '0');
	}
	if (self.native.api.set_brightness(display, (float)level) != 0)
	{
		return error::raise(
			error::BACKEND_FAILURE,
			error::Domain.MACH,
			0,
			"DisplayServicesSetBrightness refused '%s'",
			device_id
		)~;
	}
	float value            = 0;
	Maybe{Level} read_back = { };
	if (self.native.api.get_brightness(display, &value) == 0)
	{
		read_back = maybe::value((Level)value);
	}
	long raw = (long)(level.to_raw(0, NATIVE_STEPS));
	brightness::confirm_read_back(device_id, raw, 0, NATIVE_STEPS, read_back)!;
	return brightness::applied_at(Mechanism.NATIVE, level, raw, 0, NATIVE_STEPS, read_back);
}