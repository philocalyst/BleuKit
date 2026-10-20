<*
 The Linux backend: the panel backlight and keyboard LEDs through sysfs, with
 writes through logind when it is reachable, and external monitors through DDC/CI.

 Capabilities describe the backend. Which device has which control is found on
 each pass from `/sys/class/backlight`, `/sys/class/leds` and `/sys/class/drm`.
 Gamma dimming and overlay dimming are not built here, so their capabilities say
 so; see the README.
*>
module bleu::brightness::linux @feat(LINUX);
import std::collections::list, std::collections::maybe, std::time, std::time::clock, bleu::availability, bleu::brightness, bleu::brightness::linux_ddc, bleu::brightness::logind, bleu::brightness::sysfs, bleu::dbus::connection, bleu::error, bleu::rt::worker, bleu::unit;

<* The backend's state. Created on the calling thread; `bus` and the routes are used on the worker only. *>
struct Linux
{
	Allocator allocator;
	Clock started;
	String root;
	String bus_address;
	OpenBusFn open_bus;
	void* open_bus_context;
	Duration poll;
	Duration step;
	Connection bus;
	Route bus_route;
	Route panel_route;
	Route led_route;
	Platform platform;
	List{DdcDisplay*} displays;
}

const Driver DRIVER = {
	.info = { "linux", "sysfs and logind backlights, keyboard LEDs, DDC/CI through /dev/i2c-N", 10 },
	.id = LINUX,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

<* Usable when the kernel exposes any of the classes this backend drives. *>
fn bool probe(Options* options)
{
	return sysfs::has_class(
		options.root,
		sysfs::BACKLIGHT_CLASS
	) || sysfs::has_class(options.root, sysfs::LED_CLASS) || sysfs::has_class(options.root, sysfs::DRM_CLASS);
}

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	capabilities.values[Cap.SET_NATIVE.ordinal] = availability::no(
		UNSUPPORTED_OS,
		"the OS's own panel call is macOS only"
	);
	capabilities.values[Cap.SET_GAMMA.ordinal] = availability::no(
		UNSUPPORTED_BACKEND,
		"gamma dimming is not built for Linux (needs wlr-gamma-control or RandR)"
	);
	capabilities.values[Cap.SET_OVERLAY.ordinal] = availability::no(
		UNSUPPORTED_BACKEND,
		"overlay dimming is not built"
	);
	Linux* self = alloc::new(
		allocator,
		Linux,
		{
			.allocator = allocator,
			.started = clock::now(),
			.root = options.root.copy(allocator),
			.bus_address = options.bus_address.copy(allocator),
			.open_bus = options.open_bus,
			.open_bus_context = options.open_bus_context,
			.poll = options.poll,
			.step = options.transition_step,
		}
	);
	self.platform = { .context = self, .read = &read_state, .write = &write_control };
	return self;
}

fn void destroy(Allocator allocator, void* state)
{
	Linux* self = (Linux*)state;
	foreach (display : self.displays)
	{
		display.detach();
		alloc::free(allocator, display.connector.ptr);
		alloc::free(allocator, display);
	}
	self.displays.free();
	alloc::free(allocator, self.root.ptr);
	alloc::free(allocator, self.bus_address.ptr);
	alloc::free(allocator, self);
}

<* Serve requests on the worker until it is stopped. *>
fn void run(void* state, BrightnessHub* hub, Host{Command}* host)
{
	Linux* self = (Linux*)state;
	self.bus.init(self.allocator);
	defer self.bus.free();
	self.displays.init(self.allocator);
	brightness::serve(hub, host, &self.platform, self.poll, self.step);
}

<*
 Read every device: the panel backlight, the keyboard LEDs, the connected
 external monitors. Runs on the worker.
*>
fn State? read_state(void* context, Allocator allocator)
{
	Linux* self = (Linux*)context;
	self.ensure_bus();
	@pool()
	{
		linux_ddc::sync_displays(&self.displays, self.allocator, self.root, self.open_bus, self.open_bus_context);
		List{Device} devices;
		devices.init(tmem);
		self.read_panel(allocator, &devices);
		self.read_leds(allocator, &devices);
		foreach (display : self.displays)
		{
			List{Control} controls;
			controls.init(tmem);
			controls.push(display.read());
			brightness::add_device(
				allocator,
				&devices,
				display.connector,
				display.connector,
				EXTERNAL,
				controls.array_view()
			);
		}
		return { .devices = alloc::clone_slice(allocator, devices.array_view()) };
	};
}

// The panel: the best backlight, if the kernel has one.
fn void Linux.read_panel(&self, Allocator allocator, List{Device}* devices)
{
	if (try name = sysfs::select_backlight(tmem, self.root))
	{
		List{Control} controls;
		controls.init(tmem);
		controls.push(sysfs::knob_control(
			BACKLIGHT,
			self.root,
			sysfs::BACKLIGHT_CLASS,
			name,
			self.logind_up(&self.panel_route)
		));
		brightness::add_device(allocator, devices, name, "panel backlight", PANEL, controls.array_view());
	}
}

// Keyboard backlights: every LED named `*kbd_backlight`.
fn void Linux.read_leds(&self, Allocator allocator, List{Device}* devices)
{
	if (try names = sysfs::entries(tmem, self.root, sysfs::LED_CLASS))
	{
		foreach (name : names)
		{
			if (!sysfs::is_keyboard_backlight(name)) continue;
			List{Control} controls;
			controls.init(tmem);
			controls.push(sysfs::knob_control(
				KEYBOARD_LED,
				self.root,
				sysfs::LED_CLASS,
				name,
				self.logind_up(&self.led_route)
			));
			brightness::add_device(allocator, devices, name, "keyboard backlight", KEYBOARD, controls.array_view());
		}
	}
}

<* Carry out one write. Only the mechanisms this backend has reach here. *>
fn Applied? write_control(void* context, String device_id, Mechanism mechanism, Level level)
{
	Linux* self = (Linux*)context;
	switch (mechanism)
	{
		case BACKLIGHT: return self.write_knob(BACKLIGHT, device_id, level);
		case KEYBOARD_LED: return self.write_knob(KEYBOARD_LED, device_id, level);
		case DDC: return self.write_ddc(device_id, level);
		case NATIVE:
		case GAMMA:
		case OVERLAY: return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "%s is not built for Linux", mechanism)~;
	}
}

// Whether logind can carry writes for `route` now: the bus is open and the route is not switched off.
fn bool Linux.logind_up(&self, Route* route) => self.bus.is_open && route.usable(self.uptime());

// Time since the backend started, for the routes' retry intervals.
fn Duration Linux.uptime(&self) => (Duration)((long)clock::now().nano_diff(self.started) / 1000);

<*
 Write a sysfs knob. logind carries the write when its route is up; otherwise, or when logind
 refuses it, the file is written directly and the route backs off. A write that fails on both
 says why logind refused. The device's own report is then read back and must agree with the
 raw value written.
*>
fn Applied? Linux.write_knob(&self, Mechanism mechanism, String device_id, Level level)
{
	@pool()
	{
		bool panel       = mechanism == BACKLIGHT;
		String directory = panel ? sysfs::BACKLIGHT_CLASS : sysfs::LED_CLASS;
		String subsystem = panel ? logind::SUBSYSTEM_BACKLIGHT : logind::SUBSYSTEM_LEDS;
		if (panel)
		{
			String selected = sysfs::select_backlight(tmem, self.root) ?? "";
			if (device_id != selected) return error::raise(
				NOT_FOUND,
				error::Domain.INTERNAL,
				0,
				"'%s' is not the panel backlight",
				device_id
			)~;
		}
		else if (!sysfs::is_keyboard_backlight(device_id) || device_id.contains("/"))
		{
			return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "'%s' is not a keyboard backlight", device_id)~;
		}
		String dir = string::tformat("%s%s/%s", self.root, directory, device_id);
		long max   = sysfs::read_number(dir, "max_brightness") ?? 0;
		if (max <= 0) return error::raise(
			error::UNAVAILABLE,
			error::Domain.INTERNAL,
			0,
			"'%s' has no maximum brightness",
			device_id
		)~;
		long raw       = level.to_raw(0, max);
		Route* route   = panel ? &self.panel_route : &self.led_route;
		Duration now   = self.uptime();
		bool asked     = false;
		bool carried   = false;
		fault refusal  = error::UNAVAILABLE;
		if (self.bus.is_open && route.usable(now))
		{
			asked = true;
			if (catch err = logind::set_brightness(&self.bus, subsystem, device_id, (uint)raw))
			{
				refusal = err;
				route.refuse(now);
				if (err == error::DISCONNECTED) self.bus.close();
			}
			else
			{
				route.accept();
				carried = true;
			}
		}
		if (!carried)
		{
			if (catch err = sysfs::write_knob(self.root, directory, device_id, raw))
			{
				if (!asked) return err~;
				return error::raise(
					err,
					error::Domain.INTERNAL,
					0,
					"'%s' was not written: logind %s, and the brightness file failed",
					device_id,
					logind::refusal_text(refusal)
				)~;
			}
		}
		Maybe{Level} read_back = { };
		if (try actual = sysfs::read_number(dir, "actual_brightness"))
		{
			read_back = maybe::value(unit::from_raw(actual, 0, max));
		}
		brightness::confirm_read_back(device_id, raw, 0, max, read_back)!;
		return brightness::applied_at(mechanism, level, raw, 0, max, read_back);
	};
}

// Write an external monitor's luminance.
fn Applied? Linux.write_ddc(&self, String device_id, Level level)
{
	foreach (display : self.displays)
	{
		if (display.connector == device_id) return display.write(level);
	}
	return error::raise(NOT_FOUND, error::Domain.INTERNAL, 0, "no external monitor '%s'", device_id)~;
}

// Open the logind connection if it is not open. A failure backs off for `RETRY_INTERVAL`; the sysfs route still works meanwhile.
fn void Linux.ensure_bus(&self)
{
	if (self.bus.is_open) return;
	Duration now = self.uptime();
	if (!self.bus_route.usable(now)) return;
	if (self.bus_address.len > 0)
	{
		if (catch self.bus.open_address(self.bus_address))
		{
			self.bus_route.refuse(now);
		}
		else
		{
			self.bus_route.accept();
		}
		return;
	}
	if (catch self.bus.open_system())
	{
		self.bus_route.refuse(now);
	}
	else
	{
		self.bus_route.accept();
	}
}