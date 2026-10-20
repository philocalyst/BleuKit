<*
 The gsettings-only backend: GNOME's settings read and written with the
 `gsettings` command, for sessions where no portal answers.

 It polls (the poll interval, default 30 s) and re-reads on every request. It
 has no change signal, so a change made outside Bleu appears within one poll.
 The accent colour and the contrast flag have no gsettings key that Bleu maps
 in v1; they are reported unsupported rather than guessed.
*>
module bleu::appearance::gsettings @feat(LINUX);
import std::time, bleu::appearance, bleu::appearance::desktop, bleu::appearance::gnome, bleu::availability, bleu::rt::poller, bleu::rt::worker;

struct GsettingsBackend
{
	Allocator allocator;
	Duration poll;
	String[] wallpaper_command;
	ColorScheme scheme; // the last reading that worked: kept when a read fails
	bool reduced_motion; // likewise
}

const Driver DRIVER = {
	.info = { "gsettings", "GNOME settings through the gsettings command (no portal)", 10 },
	.id = GSETTINGS,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

fn bool probe(Options* options) => gnome::available();

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	capabilities.values[Cap.ACCENT.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"GNOME gives an accent name, which is not mapped to a colour in v1"
	);
	capabilities.values[Cap.CONTRAST.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"no gsettings key is read for contrast in this backend"
	);
	capabilities.values[Cap.REDUCED_MOTION.ordinal] = availability::no(
		availability::Reason.DEGRADED,
		"from enable-animations; the portal reports it directly"
	);
	capabilities.values[Cap.REDUCED_TRANSPARENCY.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"no gsettings key for reduced transparency in GNOME"
	);
	capabilities.values[Cap.WALLPAPER_PER_SCREEN.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_OS,
		"Linux desktops keep one picture; per-monitor is not in v1"
	);
	GsettingsBackend* backend = alloc::new(allocator, GsettingsBackend);
	backend.allocator = allocator;
	backend.poll = options.poll;
	backend.wallpaper_command = appearance::copy_strings(allocator, options.wallpaper_command);
	return backend;
}

fn void destroy(Allocator allocator, void* state)
{
	GsettingsBackend* backend = (GsettingsBackend*)state;
	appearance::free_strings(allocator, backend.wallpaper_command);
	alloc::free(allocator, backend);
}

fn void run(void* state, AppearanceHub* hub, Host{Command}* host)
{
	GsettingsBackend* backend = (GsettingsBackend*)state;
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 0)) return;
	defer poller.free();
	publish_state(backend, hub);
	Command[8] commands;
	while (!host.stopping())
	{
		if (catch poller.wait(backend.poll))
		{
			// TIMEOUT is the normal poll tick.
		}
		for (usz count = host.mailbox()
			.take_all(commands[..]); count > 0; count = host.mailbox().take_all(commands[..]))
		{
			for (usz i = 0; i < count; i++) execute(backend, &commands[i]);
		}
		publish_state(backend, hub);
	}
}

// Read the desktop and publish it. A key that cannot be read keeps its last reading; nothing is guessed.
fn void publish_state(GsettingsBackend* backend, AppearanceHub* hub) @private
{
	if (try scheme = gnome::read_color_scheme()) backend.scheme = scheme;
	if (try enabled = gnome::animations_enabled()) backend.reduced_motion = !enabled;
	StateSnapshot* snapshot = hub.begin();
	State state = {
		.color_scheme = backend.scheme,
		.reduced_motion = backend.reduced_motion,
	};
	gnome::read_desktop(snapshot.allocator(), &state);
	snapshot.value = state;
	appearance::publish(hub, snapshot);
}

fn void execute(GsettingsBackend* backend, Command* command) @private
{
	switch (command.kind)
	{
		case REFRESH: return;
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