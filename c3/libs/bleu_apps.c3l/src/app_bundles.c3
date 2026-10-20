<*
 The macOS backend: `.app` bundles in the Applications folders.

 Each bundle's `Contents/Info.plist` is read with `bleu::plist` (XML or binary).
 The bundle identifier is the app's ID. Bundles that are agents (`LSUIElement`)
 or background-only are left out, as a launcher should. Launch goes through
 `NSWorkspace` (`darwin_launch.c3`). Changes are found by polling the Applications
 folders (`poll.c3`); FSEvents is not used in this version.

 Compiled for macOS only; it has not been run (see the library README).
*>
module bleu::apps::app_bundles @feat(DARWIN);
import std::os::env, std::time, std::collections::list, bleu::apps, bleu::availability, bleu::error, bleu::plist::app_bundle, bleu::rt::worker, bleu::service;

const Driver DRIVER = {
	.info = { "app-bundles", "Application bundles (Info.plist) in the Applications folders", 10 },
	.id = Backend.APP_BUNDLES,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
	.icon = &apps::icon_unsupported,
};

<* Everything the bundle backend keeps: the folders to scan and how often to look. *>
struct BundleBackend
{
	DynamicArenaAllocator arena;
	String home;
	String[] directories;
	Duration poll;
}

// The Applications folder is always present on macOS.
fn bool probe(Options* options) => true;

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	BundleBackend* backend = alloc::new(allocator, BundleBackend);
	backend.arena.init(allocator, BUNDLE_ARENA_PAGE);
	Allocator arena = &backend.arena;
	backend.home = (env::get_home_dir(arena) ?? "").copy(arena);
	backend.directories = app_bundle::applications_directories(backend.home, arena);
	backend.poll = options.poll;
	capabilities.init(availability::YES);
	capabilities.values[Cap.WATCH.ordinal] = availability::no(
		availability::Reason.DEGRADED,
		"application folders are polled every few seconds; there is no FSEvents watch"
	);
	capabilities.values[Cap.LAUNCH_ACTION.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_OS,
		"macOS applications have no desktop actions"
	);
	capabilities.values[Cap.DBUS_ACTIVATE.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_OS,
		"D-Bus activation exists only on Linux"
	);
	capabilities.values[Cap.TERMINAL_WRAP.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_OS,
		"Terminal= is a desktop entry key"
	);
	capabilities.values[Cap.ICON.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"icon files are not decoded; the bundle's icon name is reported"
	);
	return backend;
}

const usz BUNDLE_ARENA_PAGE = 1024;

fn void destroy(Allocator allocator, void* state)
{
	BundleBackend* backend = (BundleBackend*)state;
	backend.arena.free();
	alloc::free(allocator, backend);
}

fn void run(void* state, AppsHub* hub, AppsHost* host)
{
	BundleBackend* backend = (BundleBackend*)state;
	apps::run_polled(backend, hub, host, backend.poll, backend.directories, &refresh, &launch);
}

<* Read every bundle under the Applications folders and publish the catalogue. *>
fn void refresh(void* state, AppsHub* hub)
{
	BundleBackend* backend      = (BundleBackend*)state;
	CatalogueSnapshot* snapshot = hub.begin();
	Allocator allocator         = snapshot.allocator();
	List{App} apps;
	apps.tinit();
	foreach (path : app_bundle::bundle_paths(backend.home, tmem))
	{
		// A bundle that cannot be read is left out; the others still list.
		String[] no_languages = { };
		AppBundle? bundle     = app_bundle::read(tmem, path, no_languages);
		if (catch err = bundle) continue;
		App? app = bundle_app(&bundle, allocator);
		if (catch err = app) continue;
		State current = { .apps = apps.array_view() };
		if (apps::find_by_id(&current, app.id)) continue;
		apps.push(app);
	}
	snapshot.value.apps = apps.to_aligned_array(allocator);
	apps::sort_catalogue(snapshot.value.apps);
	apps::publish_catalogue(hub, snapshot);
}

<*
 The app for a readable bundle. Agents and background-only bundles are not apps
 for a launcher, and neither is a bundle without a bundle identifier or a name.

 @return? NOT_FOUND : "The bundle is not a launchable app"
*>
fn App? bundle_app(AppBundle* bundle, Allocator allocator) @local
{
	String name = bundle.display_name.len > 0 ? bundle.display_name : bundle.name;
	if (bundle.bundle_id.len == 0 || name.len == 0 || bundle.ui_element || bundle.background_only) return NOT_FOUND~;
	String icon         = bundle.icon_name.len > 0 ? bundle.icon_name : bundle.icon_file;
	String[1] category  = { bundle.category };
	String[] categories = apps::copy_strings(allocator, category[0:bundle.category.len > 0 ? 1 : 0]);
	return {
		.id = bundle.bundle_id.copy(allocator),
		.name = name.copy(allocator),
		.categories = categories,
		.icon = icon.copy(allocator),
		.launch = APP_BUNDLE,
		.target = bundle.path.copy(allocator),
		.location = bundle.path.copy(allocator),
		.bundle_id = bundle.bundle_id.copy(allocator),
	};
}

<* Start the bundle in `request` through NSWorkspace; implemented in `darwin_launch.c3`. *>
fn Launched? launch(void* state, App* app, AppAction* action, LaunchRequest* request)
{
	return launch_bundle(app, action, request);
}