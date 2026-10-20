<*
 The Windows backend: the registry's Personalize and DWM keys for the colour
 scheme and accent, and SystemParametersInfo for the wallpaper.

 Changes arrive two ways: a watch on each registry key (an event that the poller
 waits on) and WM_SETTINGCHANGE on a hidden window of the worker thread. Either
 wakes the loop, which re-reads the state. The poll interval is the backstop.

 Sources: the Personalize key and `AppsUseLightTheme` (REG_DWORD, 0 dark), from
 dark-light 2.0.0 `src/platforms/windows.rs` (single source). The DWM `AccentColor`
 DWORD in 0xAABBGGRR order is UNVERIFIED here: neither Learn nor a second source
 was available, so the accent is reported DEGRADED. SystemParametersInfoW
 constants (SPI_GETDESKWALLPAPER 0x0073, SPI_SETDESKWALLPAPER 0x0014,
 SPIF_UPDATEINIFILE 0x0001, SPIF_SENDCHANGE 0x0002) and the MAX_PATH buffer rule
 are from Microsoft Learn, "SystemParametersInfoW". Nothing here ran on Windows.
*>
module bleu::appearance::windows @feat(WIN32) @link("user32");
import std::collections::maybe, std::time, bleu::appearance, bleu::appearance::convert, bleu::availability, bleu::error, bleu::rt::poller, bleu::rt::worker, bleu::win::message_loop, bleu::win::registry, bleu::win::text;

const String PERSONALIZE_PATH   = "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
const String DWM_PATH           = "Software\\Microsoft\\Windows\\DWM";
const String APPS_LIGHT_VALUE   = "AppsUseLightTheme";
const String ACCENT_VALUE       = "AccentColor";
const uint SPI_GETDESKWALLPAPER = 0x0073;
const uint SPI_SETDESKWALLPAPER = 0x0014;
const uint SPIF_UPDATEINIFILE   = 0x0001;
const uint SPIF_SENDCHANGE      = 0x0002;
const usz MAX_PATH              = 260;
const usz PERSONALIZE_TAG       = 0;
const usz DWM_TAG               = 1;

extern fn int system_parameters_info_w(uint action, uint param, void* data, uint flags) @cname("SystemParametersInfoW");

struct WindowsBackend
{
	Duration poll;
}

const Driver DRIVER = {
	.info = { "win32", "registry Personalize and DWM, SystemParametersInfo (Windows)", 10 },
	.id = WIN32,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

// The Personalize key exists on every Windows since 10.
fn bool probe(Options* options)
{
	if (try key = registry::open(
		registry::Hive.CURRENT_USER,
		PERSONALIZE_PATH,
		registry::View.NATIVE,
		registry::KEY_READ
	))
	{
		key.close();
		return true;
	}
	return false;
}

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	capabilities.values[Cap.COLOR_SCHEME_SET.ordinal] = availability::no(
		availability::Reason.DEGRADED,
		"writes AppsUseLightTheme; apps may not repaint until a broadcast, which v1 does not send"
	);
	capabilities.values[Cap.ACCENT.ordinal] = availability::no(
		availability::Reason.DEGRADED,
		"DWM AccentColor, layout UNVERIFIED on Windows"
	);
	capabilities.values[Cap.CONTRAST.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"not read in v1"
	);
	capabilities.values[Cap.REDUCED_MOTION.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"not read in v1"
	);
	capabilities.values[Cap.REDUCED_TRANSPARENCY.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"not read in v1"
	);
	capabilities.values[Cap.FONT.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"UISettings is deferred in v1"
	);
	capabilities.values[Cap.TEXT_SCALE.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"UISettings is deferred in v1"
	);
	capabilities.values[Cap.THEME_NAMES.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_OS,
		"Windows has no icon, GTK or cursor theme names"
	);
	capabilities.values[Cap.CLOCK_FORMAT.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"not read in v1"
	);
	capabilities.values[Cap.WALLPAPER_PER_SCREEN.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"IDesktopWallpaper is deferred; SystemParametersInfo sets every screen"
	);
	WindowsBackend* backend = alloc::new(allocator, WindowsBackend, { .poll = options.poll });
	return backend;
}

fn void destroy(Allocator allocator, void* state)
{
	alloc::free(allocator, (WindowsBackend*)state);
}

fn void run(void* state, AppearanceHub* hub, Host{Command}* host)
{
	WindowsBackend* backend = (WindowsBackend*)state;
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 2, true)) return;
	defer poller.free();

	// The hidden window must be opened on this thread, which dispatches its messages.
	message_loop::Loop* window = message_loop::open(mem, &on_message, null)!!;
	defer window.close();

	registry::Watch personalize;
	bool watching_personalize = false;
	if (try watch = watch_key_at(PERSONALIZE_PATH))
	{
		personalize = watch;
		watching_personalize = true;
		poller.add({ .handle = personalize.handle(), .interest = { .readable = true }, .tag = PERSONALIZE_TAG })!!;
	}
	defer
	{
		if (watching_personalize) personalize.close();
	}
	registry::Watch accent;
	bool watching_accent = false;
	if (try watch = watch_key_at(DWM_PATH))
	{
		accent = watch;
		watching_accent = true;
		poller.add({ .handle = accent.handle(), .interest = { .readable = true }, .tag = DWM_TAG })!!;
	}
	defer
	{
		if (watching_accent) accent.close();
	}

	refresh(hub);
	Command[8] commands;
	while (!host.stopping())
	{
		if (try ready = poller.wait(backend.poll))
		{
			foreach (event : ready)
			{
				if (event.tag == poller::WINDOW_MESSAGES_TAG) message_loop::dispatch_pending();
				if (event.tag == PERSONALIZE_TAG && watching_personalize) personalize.arm()!!;
				if (event.tag == DWM_TAG && watching_accent) accent.arm()!!;
			}
		}
		for (usz count = host.mailbox()
			.take_all(commands[..]); count > 0; count = host.mailbox().take_all(commands[..]))
		{
			for (usz i = 0; i < count; i++) execute(&commands[i]);
		}
		refresh(hub);
	}
	appearance::cancel_pending(host);
}

// The wake-up itself is the signal: the loop re-reads the whole state after it.
fn void on_message(void* context, message_loop::Event* event) @private
{
}

fn registry::Watch? watch_key_at(String path) @private
{
	registry::Key key = registry::open(registry::Hive.CURRENT_USER, path, registry::View.NATIVE, registry::KEY_READ)!;
	return registry::watch_key(key)!;
}

fn void refresh(AppearanceHub* hub) @private
{
	StateSnapshot* snapshot = hub.begin();
	snapshot.value = read_state(snapshot.allocator());
	appearance::publish(hub, snapshot);
}

fn State read_state(Allocator allocator) @private
{
	return {
		.color_scheme = read_scheme(),
		.accent = read_accent(),
		.wallpapers = read_wallpaper(allocator),
	};
}

// AppsUseLightTheme is missing on a machine that never chose a theme; Windows then uses light.
fn ColorScheme read_scheme() @private
{
	if (try key = registry::open(
		registry::Hive.CURRENT_USER,
		PERSONALIZE_PATH,
		registry::View.NATIVE,
		registry::KEY_READ
	))
	{
		defer key.close();
		if (try value = key.dword(APPS_LIGHT_VALUE)) return convert::scheme_from_apps_use_light_theme(value);
	}
	return LIGHT;
}

fn Maybe{Rgb} read_accent() @private
{
	if (try key = registry::open(registry::Hive.CURRENT_USER, DWM_PATH, registry::View.NATIVE, registry::KEY_READ))
	{
		defer key.close();
		if (try value = key.dword(ACCENT_VALUE)) return convert::accent_from_abgr(value);
	}
	return { };
}

// SystemParametersInfoW(SPI_GETDESKWALLPAPER) writes the path into a MAX_PATH buffer; empty means none.
fn Wallpaper[] read_wallpaper(Allocator allocator) @private
{
	Char16[MAX_PATH] buffer;
	if (system_parameters_info_w(SPI_GETDESKWALLPAPER, MAX_PATH, buffer[..].ptr, 0) == 0) return { };
	usz length = 0;
	while (length < MAX_PATH && buffer[length] != 0) length++;
	if (length == 0) return { };
	String path = text::from_wide_units(allocator, buffer[0:length]) ?? "";
	if (path.len == 0) return { };
	Wallpaper[] wallpapers = alloc::new_array(allocator, Wallpaper, 1);
	wallpapers[0] = { .screen = "", .path = path };
	return wallpapers;
}

fn void execute(Command* command) @private
{
	switch (command.kind)
	{
		case REFRESH: return;
		case SET_COLOR_SCHEME:
			if (catch err = set_color_scheme(command.scheme))
			{
				appearance::settle_fault(command, err);
			}
			else
			{
				appearance::settle_ok(command);
			}
		case SET_WALLPAPER:
			if (catch err = set_wallpaper(command.path))
			{
				appearance::settle_fault(command, err);
			}
			else
			{
				appearance::settle_ok(command);
			}
	}
}

fn void? set_color_scheme(ColorScheme scheme) @private
{
	if (scheme == NO_PREFERENCE) return error::raise(
		error::INVALID_ARGUMENT,
		error::Domain.INTERNAL,
		0,
		"Windows has no 'no preference' appearance"
	)~;
	registry::Key key = registry::open(
		registry::Hive.CURRENT_USER,
		PERSONALIZE_PATH,
		registry::View.NATIVE,
		registry::KEY_READ | registry::KEY_WRITE
	)!;
	defer key.close();
	key.set_dword(APPS_LIGHT_VALUE, convert::apps_use_light_theme(scheme))!;
}

fn void? set_wallpaper(String path) @private
{
	@pool()
	{
		WideZ wide = text::to_wide(tmem, path)!;
		if (system_parameters_info_w(
			SPI_SETDESKWALLPAPER,
			0,
			(void*)wide.as_wstring(),
			SPIF_UPDATEINIFILE | SPIF_SENDCHANGE
		) == 0)
		{
			return error::raise(
				error::BACKEND_FAILURE,
				error::Domain.WIN32,
				0,
				"SystemParametersInfoW refused '%s'",
				path
			)~;
		}
	};
}