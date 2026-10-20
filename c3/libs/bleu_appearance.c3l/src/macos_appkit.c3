<*
 The macOS backend: NSUserDefaults for the colour scheme, NSWorkspace for the
 accessibility flags and the desktop pictures, NSScreen for the screens.

 Reads happen on the worker inside an autorelease pool, every poll interval and
 on every request. The distributed notification `AppleInterfaceThemeChangedNotification`
 only enqueues a refresh; it never publishes from the posting thread. Whether
 that notification is delivered to a thread without a run loop is UNVERIFIED,
 so the poll is what guarantees a change appears.

 Sources: the key `AppleInterfaceStyle` and "absent means light" from
 dark-light 2.0.0 `src/platforms/macos.rs` (single source, UNVERIFIED against
 Apple); the NSWorkspace selectors from objc2-app-kit 0.3.1
 `src/generated/NSAccessibility.rs` and `NSWorkspace.rs`; the notification name
 from tao `window_delegate.rs` (see bleu_objc). Apple's own pages were not
 readable in research, so every behaviour here is compiled, not run.
*>
module bleu::appearance::appkit @feat(DARWIN);
import std::os::darwin::objc, std::time, bleu::appearance, bleu::availability, bleu::error, bleu::objc, bleu::objc::applescript, bleu::objc::foundation, bleu::objc::notify, bleu::rt::mailbox, bleu::rt::poller, bleu::rt::worker;

const String DARK_STYLE_VALUE  = "Dark";
const String AUTOMATION_SCRIPT = "tell application \"System Events\" to tell appearance preferences to set dark mode to %s";

struct AppkitBackend
{
	Duration poll;
}

const Driver DRIVER = {
	.info = { "appkit", "NSUserDefaults, NSWorkspace and NSScreen (macOS)", 10 },
	.id = APPKIT,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

// AppKit is part of every macOS session.
fn bool probe(Options* options) => true;

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	capabilities.init(availability::YES);
	capabilities.values[Cap.ACCENT.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"AppleAccentColor is undocumented; not read in v1"
	);
	capabilities.values[Cap.COLOR_SCHEME_SET.ordinal] = availability::no(
		availability::Reason.DEGRADED,
		"through System Events AppleScript; macOS may ask for Automation permission"
	);
	capabilities.values[Cap.FONT.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"not read in v1"
	);
	capabilities.values[Cap.TEXT_SCALE.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"macOS has no single text-scale factor"
	);
	capabilities.values[Cap.THEME_NAMES.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_OS,
		"macOS has no icon, GTK or cursor theme names"
	);
	capabilities.values[Cap.CLOCK_FORMAT.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"not read in v1 (AppleICUForce24HourTime is undocumented)"
	);
	AppkitBackend* backend = alloc::new(allocator, AppkitBackend, { .poll = options.poll });
	return backend;
}

fn void destroy(Allocator allocator, void* state)
{
	alloc::free(allocator, (AppkitBackend*)state);
}

fn void run(void* state, AppearanceHub* hub, Host{Command}* host)
{
	AppkitBackend* backend = (AppkitBackend*)state;
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 0)) return;
	defer poller.free();

	// The observer only enqueues a refresh: it may run on any thread.
	Obj name = notify::name_of(notify::DISTRIBUTED_APPEARANCE_CHANGED);
	defer name.close();
	notify::BlockSubscription subscription;
	bool observing = false;
	if (try observed = notify::observe(
		notify::CenterKind.DISTRIBUTED,
		name.ptr,
		&on_theme_changed,
		&hub.worker.mailbox
	))
	{
		subscription = observed;
		observing = true;
	}
	defer
	{
		if (observing) subscription.close();
	}

	refresh(hub);
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
			for (usz i = 0; i < count; i++) execute(&commands[i]);
		}
		refresh(hub);
	}
	appearance::cancel_pending(host);
}

// Runs on whatever thread posts the notification: only the mailbox is touched.
fn void on_theme_changed(void* user, ObjId notification) @private
{
	objc::@objc_entry()
	{
		Mailbox{Command}* mailbox = (Mailbox{Command}*)user;
		(void)mailbox.post({ .kind = REFRESH });
	};
}

fn void refresh(AppearanceHub* hub) @private
{
	objc::@autorelease_pool()
	{
		StateSnapshot* snapshot = hub.begin();
		snapshot.value = read_state(snapshot.allocator());
		appearance::publish(hub, snapshot);
	};
}

fn State read_state(Allocator allocator) @private
{
	Obj workspace = objc::borrow(objc::class_named("NSWorkspace").send(ObjId, "sharedWorkspace"));
	defer workspace.close();
	return {
		.color_scheme = read_scheme(),
		.contrast = workspace.send_bool("accessibilityDisplayShouldIncreaseContrast") ? HIGH : NORMAL,
		.reduced_motion = workspace.send_bool("accessibilityDisplayShouldReduceMotion"),
		.reduced_transparency = workspace.send_bool("accessibilityDisplayShouldReduceTransparency"),
		.wallpapers = read_wallpapers(allocator, workspace),
	};
}

// `AppleInterfaceStyle` is "Dark" in dark mode and absent in light mode.
fn ColorScheme read_scheme() @private
{
	Obj defaults = objc::borrow(objc::class_named("NSUserDefaults").send(ObjId, "standardUserDefaults"));
	defer defaults.close();
	Obj key = foundation::from_string("AppleInterfaceStyle");
	defer key.close();
	ObjId style = defaults.send_id("stringForKey:", key.ptr);
	if (!style) return LIGHT;
	@pool()
	{
		if (try text = foundation::to_string(style, tmem))
		{
			return text == DARK_STYLE_VALUE ? DARK : LIGHT;
		}
		return LIGHT;
	};
}

// One picture per screen, read with `desktopImageURLForScreen:`; screens with no picture are skipped.
fn Wallpaper[] read_wallpapers(Allocator allocator, Obj workspace) @private
{
	ObjId screens     = objc::class_named("NSScreen").send(ObjId, "screens");
	usz count         = foundation::array_count(screens);
	Wallpaper[] found = alloc::new_array(allocator, Wallpaper, (sz)count);
	usz n             = 0;
	for (usz i = 0; i < count; i++)
	{
		ObjId screen = foundation::array_at(screens, i);
		ObjId url    = workspace.send_id("desktopImageURLForScreen:", screen);
		if (!url) continue;
		String path = "";
		@pool()
		{
			ObjId text = url.send(ObjId, "path");
			path = foundation::to_string(text, allocator) ?? "";
		};
		if (path.len == 0) continue;
		found[n++] = { .screen = screen_id(allocator, screen), .path = path };
	}
	return found[0:n];
}

// The NSScreenNumber of a screen, which identifies it across snapshots.
fn String screen_id(Allocator allocator, ObjId screen) @private
{
	ObjId description = screen.send(ObjId, "deviceDescription");
	Obj key           = foundation::from_string("NSScreenNumber");
	defer key.close();
	ObjId number = description.send(ObjId, "objectForKey:", key.ptr);
	if (!number) return "";
	long value = number.send(long, "longValue");
	@pool()
	{
		return string::tformat("%d", value).copy(allocator);
	};
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

// Dark mode through System Events. There is no "no preference" on macOS.
fn void? set_color_scheme(ColorScheme scheme) @private
{
	if (scheme == NO_PREFERENCE) return error::raise(
		error::INVALID_ARGUMENT,
		error::Domain.INTERNAL,
		0,
		"macOS has no 'no preference' appearance"
	)~;
	@pool()
	{
		String script = string::tformat(AUTOMATION_SCRIPT, scheme == DARK ? "true" : "false");
		String reply  = applescript::run_script(script, tmem)!;
		(void)reply;
		return;
	};
}

// Every screen gets the picture: NSWorkspace sets a picture per screen.
fn void? set_wallpaper(String path) @private
{
	@pool()
	{
		Obj workspace = objc::borrow(objc::class_named("NSWorkspace").send(ObjId, "sharedWorkspace"));
		defer workspace.close();
		Obj path_object = foundation::from_string(path);
		defer path_object.close();
		ObjId url     = objc::class_named("NSURL").send(ObjId, "fileURLWithPath:", path_object.ptr);
		ObjId screens = objc::class_named("NSScreen").send(ObjId, "screens");
		usz count     = foundation::array_count(screens);
		for (usz i = 0; i < count; i++)
		{
			ObjId screen = foundation::array_at(screens, i);
			bool done = workspace.send_bool(
				"setDesktopImageURL:forScreen:options:error:",
				url,
				screen,
				(ObjId)null,
				(ObjId)null
			);
			if (!done) return error::raise(
				error::BACKEND_FAILURE,
				error::Domain.NS_ERROR,
				(int)i,
				"setDesktopImageURL failed on screen %d",
				i
			)~;
		}
		return;
	};
}