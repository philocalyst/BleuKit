<*
 The Settings portal backend: `org.freedesktop.portal.Settings` on the session bus.

 It carries the colour scheme, the accent colour, the contrast and reduced
 motion (namespace `org.freedesktop.appearance`). Changes arrive as the
 `SettingChanged` signal; the value is then read again with `Read`. The
 desktop keys the portal does not carry come from GNOME gsettings when that
 answers (see `gnome.c3`).

 Sources: xdg-desktop-portal `data/org.freedesktop.portal.Settings.xml`
 (flatpak/xdg-desktop-portal, raw.githubusercontent.com), the value types of
 `org.freedesktop.appearance` in the same spec, and ashpd 0.10.2
 `src/desktop/settings.rs` for the variant-in-variant reply of `Read`. The
 probe is a name lookup, not a read, so it works even before the portal
 serves its first request. `Read` is the deprecated spelling in v2 of the spec;
 it is used here only for keys named by a signal, which is what the research
 note's call sequence asked for.
*>
module bleu::appearance::portal @feat(LINUX);
import std::collections::enummap, std::collections::maybe, std::time, bleu::appearance, bleu::appearance::convert, bleu::appearance::desktop, bleu::appearance::gnome, bleu::availability, bleu::dbus::connection, bleu::dbus::marshal, bleu::dbus::match, bleu::dbus::message, bleu::dbus::proxy, bleu::dbus::value, bleu::error, bleu::rt::poller, bleu::rt::worker;

const String PORTAL_BUS_NAME = "org.freedesktop.portal.Desktop";
const String PORTAL_PATH     = "/org/freedesktop/portal/desktop";
const String SETTINGS_IFACE  = "org.freedesktop.portal.Settings";
const String APPEARANCE_NS   = "org.freedesktop.appearance";
const String SETTING_CHANGED = "SettingChanged";
const String READ_ALL_CALL   = "ReadAll";
const String READ_CALL       = "Read";

<* A call to the portal gives up after 5 s (portal start-up can take a moment). *>
const Duration CALL_TIMEOUT = (Duration)5_000_000;

<* Bus tag in the poller; the poller reserves its own tags for the wake-up. *>
const usz BUS_TAG = 0;

<* What `accent_from_channels` treats as "no accent": out of range. *>
const double NO_CHANNEL = -1.0;

<* The four keys of `org.freedesktop.appearance` that Bleu reads. *>
enum PortalKey : char
{
	SCHEME_KEY,
	ACCENT_KEY,
	CONTRAST_KEY,
	MOTION_KEY,
}

<* The portal's values as last read. Defaults are "no preference", as the portal reports for an absent key. *>
struct PortalValues
{
	ColorScheme color_scheme;
	Maybe{Rgb} accent;
	Contrast contrast;
	bool reduced_motion;
}

struct PortalBackend
{
	Allocator allocator;
	Duration poll;
	String bus_address;
	String[] wallpaper_command;
	bool desktop;
	PortalValues values;
	EnumMap{PortalKey, bool} dirty;
}

const Driver DRIVER = {
	.info = { "portal", "org.freedesktop.portal.Settings (plus GNOME gsettings for desktop keys)", 20 },
	.id = PORTAL,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

<* The portal's well-known name has an owner on the session bus. *>
fn bool probe(Options* options)
{
	Connection bus;
	bus.init(mem);
	defer bus.free();
	if (catch open_bus(&bus, options.bus_address)) return false;
	if (try present = bus.name_has_owner(PORTAL_BUS_NAME)) return present;
	return false;
}

fn void? open_bus(Connection* bus, String address)
{
	if (address.len > 0) return bus.open_address(address);
	return bus.open_session();
}

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	PortalBackend* backend = alloc::new(allocator, PortalBackend);
	backend.allocator = allocator;
	backend.poll = options.poll;
	backend.bus_address = options.bus_address.copy(allocator);
	backend.wallpaper_command = appearance::copy_strings(allocator, options.wallpaper_command);
	backend.desktop = gnome::available();
	backend.dirty.init(false);
	describe(capabilities, backend.desktop, options.wallpaper_command.len > 0);
	return backend;
}

fn void destroy(Allocator allocator, void* state)
{
	PortalBackend* backend = (PortalBackend*)state;
	alloc::free(allocator, backend.bus_address.ptr);
	appearance::free_strings(allocator, backend.wallpaper_command);
	alloc::free(allocator, backend);
}

// Capabilities for the portal plus, when GNOME answers, its desktop keys.
fn void describe(Capabilities* capabilities, bool desktop, bool command) @private
{
	capabilities.init(availability::YES);
	capabilities.values[Cap.COLOR_SCHEME_SET.ordinal] = desktop ? availability::no(
		availability::Reason.DEGRADED,
		"GNOME only: writes org.gnome.desktop.interface color-scheme"
	)
		: availability::no(availability::Reason.UNSUPPORTED_BACKEND, "setting the scheme needs GNOME gsettings here");
	capabilities.values[Cap.ACCENT.ordinal] = availability::YES;
	capabilities.values[Cap.REDUCED_TRANSPARENCY.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"the Settings portal has no reduced-transparency key"
	);
	Availability desktop_key = desktop ? availability::YES
		: availability::no(availability::Reason.UNSUPPORTED_BACKEND, "needs GNOME gsettings");
	capabilities.values[Cap.FONT.ordinal] = desktop_key;
	capabilities.values[Cap.TEXT_SCALE.ordinal] = desktop_key;
	capabilities.values[Cap.THEME_NAMES.ordinal] = desktop_key;
	capabilities.values[Cap.CLOCK_FORMAT.ordinal] = desktop_key;
	capabilities.values[Cap.WALLPAPER.ordinal] = desktop_key;
	capabilities.values[Cap.WALLPAPER_SET.ordinal] = desktop || command ? availability::YES
		: availability::no(availability::Reason.UNSUPPORTED_BACKEND, "set wallpaper_command, or run GNOME");
	capabilities.values[Cap.WALLPAPER_PER_SCREEN.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_OS,
		"Linux desktops keep one picture; per-monitor is not in v1"
	);
}

fn void run(void* state, AppearanceHub* hub, Host{Command}* host)
{
	PortalBackend* backend = (PortalBackend*)state;
	Connection bus;
	bus.init(backend.allocator);
	defer bus.free();
	if (catch open_bus(&bus, backend.bus_address)) return;
	if (catch subscribe_changes(&bus, backend)) return;
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 1)) return;
	defer poller.free();
	int fd = bus.fd()!!;
	poller.add({ .handle = fd, .interest = { .readable = true }, .tag = BUS_TAG })!!;
	read_all(backend, &bus);
	publish_state(backend, hub);
	Command[8] commands;
	while (!host.stopping())
	{
		// Wakes on bus traffic, on a request, or after the poll interval (which re-reads the desktop keys).
		if (catch poller.wait(backend.poll))
		{
			// TIMEOUT is the normal poll tick.
		}
		// The peer going away ends the backend: nothing more can be read.
		if (catch bus.process()) break;
		apply_dirty(backend, &bus);
		for (usz count = host.mailbox()
			.take_all(commands[..]); count > 0; count = host.mailbox().take_all(commands[..]))
		{
			for (usz i = 0; i < count; i++) execute(backend, &bus, &commands[i]);
		}
		publish_state(backend, hub);
	}
	appearance::cancel_pending(host);
}

fn void? subscribe_changes(Connection* bus, PortalBackend* backend)
{
	match::Match rule;
	rule.init(backend.allocator);
	rule.with_type(MessageType.SIGNAL)!;
	rule.with_sender(PORTAL_BUS_NAME)!;
	rule.with_interface(SETTINGS_IFACE)!;
	rule.with_member(SETTING_CHANGED)!;
	rule.with_path(PORTAL_PATH)!;
	// The subscription lives as long as the connection; nothing else needs its id.
	(void)bus.subscribe(rule, &on_setting_changed, backend)!;
}

// Signal handler: marks the key it names. Reads happen later, outside dispatch.
fn void on_setting_changed(void* context, Message* signal) @private
{
	PortalBackend* backend = (PortalBackend*)context;
	if (try r = signal.reader())
	{
		if (try ns = r.read_string())
		{
			if (try key = r.read_string())
			{
				if (ns == APPEARANCE_NS)
				{
					if (try which = key_named(key)) backend.dirty.values[which.ordinal] = true;
				}
			}
		}
	}
}

fn void apply_dirty(PortalBackend* backend, Connection* bus) @private
{
	for (usz i = 0; i < backend.dirty.values.len; i++)
	{
		if (!backend.dirty.values[i]) continue;
		backend.dirty.values[i] = false;
		read_key(backend, bus, (PortalKey)(char)i);
	}
}

fn PortalKey? key_named(String name) @private
{
	switch (name)
	{
		case "color-scheme": return PortalKey.SCHEME_KEY;
		case "accent-color": return PortalKey.ACCENT_KEY;
		case "contrast": return PortalKey.CONTRAST_KEY;
		case "reduced-motion": return PortalKey.MOTION_KEY;
		default: return NOT_FOUND~;
	}
}

fn String key_name(PortalKey key) @private
{
	switch (key)
	{
		case SCHEME_KEY: return "color-scheme";
		case ACCENT_KEY: return "accent-color";
		case CONTRAST_KEY: return "contrast";
		case MOTION_KEY: return "reduced-motion";
	}
}

// Settings.ReadAll(as) -> a{sa{sv}}: every key of the appearance namespace at once.
fn Value? call_read_all(Connection* bus, Allocator allocator) @private
{
	Proxy settings = proxy::for_object(bus, PORTAL_BUS_NAME, PORTAL_PATH, SETTINGS_IFACE)!;
	Message* call  = settings.new_call(allocator, READ_ALL_CALL)!;
	defer call.release();
	Writer* w = call.body_writer("as")!;
	w.begin_array("as")!;
	w.append_string(APPEARANCE_NS)!;
	w.end_array()!;
	Message* reply = bus.call(call, CALL_TIMEOUT)!;
	defer reply.release();
	Reader r = reply.reader()!;
	return r.read_value(allocator);
}

// Settings.Read(s namespace, s key) -> v. The reply is a variant whose contents may be another variant: `unwrap` removes every layer.
fn Value? call_read(Connection* bus, Allocator allocator, PortalKey key) @private
{
	Proxy settings = proxy::for_object(bus, PORTAL_BUS_NAME, PORTAL_PATH, SETTINGS_IFACE)!;
	Message* call  = settings.new_call(allocator, READ_CALL)!;
	defer call.release();
	Writer* w = call.body_writer("ss")!;
	w.append_string(APPEARANCE_NS)!;
	w.append_string(key_name(key))!;
	Message* reply = bus.call(call, CALL_TIMEOUT)!;
	defer reply.release();
	Reader r = reply.reader()!;
	return r.read_value(allocator).unwrap();
}

fn void read_all(PortalBackend* backend, Connection* bus) @private
{
	@pool()
	{
		if (try all = call_read_all(bus, tmem))
		{
			backend.values = { };
			if (try ns = all.dict_get(APPEARANCE_NS))
			{
				if (try v = ns.dict_get(key_name(SCHEME_KEY))) apply(&backend.values, SCHEME_KEY, v);
				if (try v = ns.dict_get(key_name(ACCENT_KEY))) apply(&backend.values, ACCENT_KEY, v);
				if (try v = ns.dict_get(key_name(CONTRAST_KEY))) apply(&backend.values, CONTRAST_KEY, v);
				if (try v = ns.dict_get(key_name(MOTION_KEY))) apply(&backend.values, MOTION_KEY, v);
			}
		}
	};
}

fn void read_key(PortalBackend* backend, Connection* bus, PortalKey key) @private
{
	@pool()
	{
		if (try value = call_read(bus, tmem, key)) apply(&backend.values, key, value);
	};
}

fn void apply(PortalValues* values, PortalKey key, Value value) @private
{
	switch (key)
	{
		case SCHEME_KEY: values.color_scheme = convert::scheme_from_portal(value.as_u32() ?? 0);
		case ACCENT_KEY: values.accent = accent_from_value(value);
		case CONTRAST_KEY: values.contrast = convert::contrast_from_portal(value.as_u32() ?? 0);
		case MOTION_KEY: values.reduced_motion = convert::reduced_from_portal(value.as_u32() ?? 0);
	}
}

// An accent is a struct (ddd) of three channels; anything else is no accent.
fn Maybe{Rgb} accent_from_value(Value value) @private
{
	if (value.unwrap().kind != STRUCT || value.count() != 3) return { };
	double red   = channel_at(value, 0) ?? NO_CHANNEL;
	double green = channel_at(value, 1) ?? NO_CHANNEL;
	double blue  = channel_at(value, 2) ?? NO_CHANNEL;
	return convert::accent_from_channels(red, green, blue);
}

fn double? channel_at(Value colour, usz index) @private
{
	Value channel = colour.at(index)!;
	return channel.as_f64();
}

fn void publish_state(PortalBackend* backend, AppearanceHub* hub) @private
{
	StateSnapshot* snapshot = hub.begin();
	State state = {
		.color_scheme = backend.values.color_scheme,
		.accent = backend.values.accent,
		.contrast = backend.values.contrast,
		.reduced_motion = backend.values.reduced_motion,
	};
	if (backend.desktop) gnome::read_desktop(snapshot.allocator(), &state);
	snapshot.value = state;
	appearance::publish(hub, snapshot);
}

fn void execute(PortalBackend* backend, Connection* bus, Command* command) @private
{
	switch (command.kind)
	{
		case REFRESH: read_all(backend, bus);
		case SET_COLOR_SCHEME:
			if (catch err = gnome::set_color_scheme(command.scheme))
			{
				appearance::settle_fault(command, err);
			}
			else
			{
				appearance::settle_ok(command);
			}
		case SET_WALLPAPER:
			if (catch err = desktop::set_wallpaper(backend.wallpaper_command, command.path))
			{
				appearance::settle_fault(command, err);
			}
			else
			{
				appearance::settle_ok(command);
			}
	}
}