<*
 The Windows backend: the internal panel through the display driver's IOCTLs,
 and external monitors through dxva2's high-level monitor API.

 COMPILED ONLY: type-checked for the Windows targets, never run. See the module
 comments in `windows_panel.c3` and `windows_monitors.c3` for what is unverified.
 Gamma, overlay and keyboard backlights are not built here; their capabilities say so.
*>
module bleu::brightness::windows @feat(WIN32);
import std::collections::list, std::collections::maybe, std::time, bleu::availability, bleu::brightness, bleu::brightness::windows_monitors, bleu::brightness::windows_panel, bleu::error, bleu::rt::worker, bleu::unit;

const String PANEL_ID = "lcd";

<* The backend's state. *>
struct Windows
{
	Allocator allocator;
	Duration poll;
	Duration step;
	Platform platform;
}

const Driver DRIVER = {
	.info = { "win32", "display driver IOCTLs (\\\\.\\LCD) and dxva2 for external monitors", 10 },
	.id = WIN32,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

// Windows always has the display API; whether a device answers is found per pass.
fn bool probe(Options* options) => true;

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	capabilities.values[Cap.SET_NATIVE.ordinal] = availability::no(UNSUPPORTED_OS, "the OS's own panel call is macOS only");
	capabilities.values[Cap.SET_GAMMA.ordinal] = availability::no(UNSUPPORTED_BACKEND, "gamma ramps are not built for Windows yet");
	capabilities.values[Cap.SET_OVERLAY.ordinal] = availability::no(UNSUPPORTED_BACKEND, "overlay dimming is not built");
	capabilities.values[Cap.SET_KEYBOARD_LED.ordinal] = availability::no(UNSUPPORTED_BACKEND, "keyboard backlights are not built for Windows");
	Windows* self = alloc::new(allocator, Windows, {
		.allocator = allocator,
		.poll = options.poll,
		.step = options.transition_step,
		.platform = { .read = &read_state, .write = &write_control },
	});
	self.platform.context = self;
	return self;
}

fn void destroy(Allocator allocator, void* state)
{
	alloc::free(allocator, state);
}

<* Serve requests on the worker until it is stopped. *>
fn void run(void* state, BrightnessHub* hub, Host{Command}* host)
{
	Windows* self = (Windows*)state;
	brightness::serve(hub, host, &self.platform, self.poll, self.step);
}

<* Read the panel (if it has one) and every physical monitor. *>
fn State? read_state(void* context, Allocator allocator)
{
	List{Device} devices;
	@pool()
	{
		devices.init(tmem);
		if (try panel = windows_panel::open_panel())
		{
			defer panel.close();
			if (try level = panel.level())
			{
				List{Control} controls;
				controls.init(tmem);
				controls.push({
					.mechanism = Mechanism.BACKLIGHT,
					.readable = true,
					.writable = true,
					.availability = availability::YES,
					.level = maybe::value(level),
					.raw_min = 0,
					.raw_max = windows_panel::PANEL_STEPS,
				});
				brightness::add_device(allocator, &devices, PANEL_ID, "internal panel", DeviceKind.PANEL, controls.array_view());
			}
		}
		List{windows_monitors::Chunk} chunks;
		chunks.init(tmem);
		if (catch windows_monitors::enumerate(&chunks))
		{
			// Without the display API there are no external monitors; the panel still stands.
		}
		defer windows_monitors::release_chunks(&chunks);
		usz index = 0;
		foreach (chunk : chunks)
		{
			foreach (&monitor : chunk)
			{
				List{Control} controls;
				controls.init(tmem);
				controls.push(windows_monitors::monitor_control(monitor));
				brightness::add_device(allocator, &devices, string::tformat("monitor-%d", index++), "external monitor", DeviceKind.EXTERNAL, controls.array_view());
			}
		}
		return { .devices = alloc::clone_slice(allocator, devices.array_view()) };
	};
}

<* Carry out one write. *>
fn Applied? write_control(void* context, String device_id, Mechanism mechanism, Level level)
{
	switch (mechanism)
	{
		case Mechanism.BACKLIGHT: return write_panel(device_id, level);
		case Mechanism.DDC: return write_external(device_id, level);
		case Mechanism.NATIVE:
		case Mechanism.GAMMA:
		case Mechanism.OVERLAY:
		case Mechanism.KEYBOARD_LED: return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "%s is not built for Windows", mechanism)~;
	}
}

fn Applied? write_panel(String device_id, Level level) @local
{
	if (device_id != PANEL_ID) return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "'%s' is not the internal panel", device_id)~;
	windows_panel::Panel panel = windows_panel::open_panel()!;
	defer panel.close();
	long raw = panel.write(level)!;
	Maybe{Level} read_back = { };
	if (try confirmed = panel.level()) read_back = maybe::value(confirmed);
	return brightness::applied_at(Mechanism.BACKLIGHT, level, raw, 0, windows_panel::PANEL_STEPS, read_back);
}

fn Applied? write_external(String device_id, Level level) @local
{
	List{windows_monitors::Chunk} chunks;
	@pool()
	{
		chunks.init(tmem);
		windows_monitors::enumerate(&chunks)!;
		defer windows_monitors::release_chunks(&chunks);
		usz index = 0;
		foreach (chunk : chunks)
		{
			foreach (&monitor : chunk)
			{
				if (string::tformat("monitor-%d", index++) == device_id) return windows_monitors::write_monitor(monitor, level);
			}
		}
		return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "no external monitor '%s'", device_id)~;
	};
}
