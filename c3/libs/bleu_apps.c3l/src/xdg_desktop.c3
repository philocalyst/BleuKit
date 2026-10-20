<*
 The Linux backend: Desktop Entry files in the XDG data directories.

 The catalogue is every `*.desktop` file that `bleu::xdg` finds in
 `$XDG_DATA_HOME/applications` and `$XDG_DATA_DIRS/*/applications`, with the
 precedence the Base Directory and Desktop Entry specifications give (the first
 file with an ID wins, so a user's entry hides the system's one). Entries that
 are `Hidden`, not shown in `$XDG_CURRENT_DESKTOP`, or whose `TryExec` is not
 found are left out. A launch expands `Exec` (`bleu::xdg::exec`) and runs it
 with `posix_spawnp` through `std::os::process`; `Terminal=true` runs it inside
 the first terminal emulator that starts.

 Changes are noticed with inotify (`xdg_watch.c3`): any event in a watched
 directory starts a quiet period (`Options.settle`), and the whole catalogue is
 rescanned once the directories have been quiet for that long.

 Source for the search path and the entry rules: the Desktop Entry specification
 and the Base Directory specification, as cited in `docs/research/apps_sysinfo_secrets_appearance.md`.
*>
module bleu::apps::xdg_desktop @feat(LINUX);
import std::io, std::io::path, std::os::env, std::time, std::time::clock, std::collections::list, bleu::dbus::connection, bleu::apps, bleu::availability, bleu::error, bleu::rt::fs, bleu::rt::poller, bleu::rt::worker, bleu::service, bleu::xdg::desktop_entry, bleu::xdg::dirs, bleu::xdg::icon, bleu::xdg::exec;

const Driver DRIVER = {
	.info = { "xdg-desktop", "Desktop Entry files in the XDG data directories", 10 },
	.id = Backend.XDG_DESKTOP,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
	.icon = &icon_file,
};

const String FAKE_HOME_DIR         = "/home";
const String DEFAULT_ICON_THEME    = "hicolor";
const String TERMINAL_OPTION       = "-e";       // the flag every terminal in the default list takes before its command
const String ACCESS_PATH_SEPARATOR = ":";
const int ACCESS_EXECUTE           = 1;          // X_OK, from unistd.h
const usz ARENA_PAGE               = 1024;
const Duration CHILD_POLL          = (Duration)1_000_000; // reap finished children once a second while any are running
const int WATCH_TAG                = 1;

// The terminal emulators tried for `Terminal=true` when the caller names none.
const String[4] DEFAULT_TERMINALS = { "x-terminal-emulator", "xterm", "konsole", "gnome-terminal" };

extern fn int access(ZString path, int mode);

<*
 Everything a Linux catalogue backend keeps between calls. Copies of
 configuration live in `arena`; the children list holds the pids of processes
 this service started that have not been reaped yet.
*>
struct XdgBackend
{
	DynamicArenaAllocator arena;
	String[] data_dirs;
	String[] icon_dirs;
	String[] desktops;
	String locale;
	String[] terminals;
	String icon_theme;
	Duration settle;
	Watcher watcher;
	List{int} children;
	connection::Connection bus;
	bool bus_available;
	String root;
}

<* Whether the desktop file probe finds any applications directory under `root`. *>
fn bool probe(Options* options)
{
	@pool()
	{
		return path::is_dir(
			(Path)string::tformat("%s/usr/share/applications", options.root)
		) || path::is_dir((Path)string::tformat("%s/usr/local/share/applications", options.root));
	};
}

<*
 Build the backend. With `options.root` set, the XDG variables point into that
 tree and nothing of the host is read; otherwise they come from the process.
*>
fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	XdgBackend* backend = alloc::new(allocator, XdgBackend);
	backend.arena.init(allocator, ARENA_PAGE);
	backend.children.init(allocator);
	Allocator arena         = &backend.arena;
	ProcessEnvironment process_env;
	Variables fake          = fake_environment(options.root, arena);
	Environment environment = options.root.len > 0 ? (Environment)&fake : (Environment)&process_env;
	backend.data_dirs = search_directories(environment, arena);
	backend.icon_dirs = icon::default_base_dirs(environment, arena);
	backend.desktops = desktop_entry::current_desktops(environment, arena);
	backend.locale = locale_for(options.locale, environment, arena);
	backend.terminals = options.terminals.len > 0 ? apps::copy_strings(arena, options.terminals)
		: apps::copy_strings(arena, DEFAULT_TERMINALS[..]);
	backend.icon_theme = (options.icon_theme.len > 0 ? options.icon_theme : DEFAULT_ICON_THEME).copy(arena);
	backend.settle = options.settle;
	backend.root = options.root.copy(arena);
	backend.watcher = { .fd = -1 };
	capabilities.init(availability::YES);
	// A missing inotify only costs live updates: REFRESH and the next launch still see changes.
	if (catch err = backend.watcher.open())
	{
		capabilities.values[Cap.WATCH.ordinal] = availability::no(
			availability::Reason.UNSUPPORTED_BACKEND,
			"inotify is unavailable; the catalogue is refreshed on request only"
		);
	}
	// D-Bus activation is always offered: an app the bus cannot activate is launched with its Exec line.
	return backend;
}

<*
 The directories to scan, in precedence order: `$XDG_DATA_HOME` (the user's own
 entries shadow the system's), then `$XDG_DATA_DIRS`.
*>
fn String[] search_directories(Environment environment, Allocator allocator) @local
{
	List{String} ordered;
	ordered.tinit();
	String home = dirs::data_home(environment, allocator) ?? "";
	if (home.len > 0) ordered.push(home);
	ordered.push_all(dirs::data_dirs(environment, allocator));
	return ordered.to_aligned_array(allocator);
}

<* The environment of a fake tree: every XDG directory lives under `root`. *>
fn Variables fake_environment(String root, Allocator allocator) @local
{
	if (root.len == 0) return { };
	String[3] names = { "HOME", "XDG_DATA_HOME", "XDG_DATA_DIRS" };
	String[3] values = {
		string::tformat("%s%s", root, FAKE_HOME_DIR)
		.copy(allocator), string::tformat("%s%s/.local/share", root, FAKE_HOME_DIR)
			.copy(allocator), string::tformat("%s/usr/share", root).copy(allocator), };
	return { .names = apps::copy_strings(allocator, names[..]), .values = apps::copy_strings(allocator, values[..]) };
}

// The language for localized names: the first of LC_ALL, LC_MESSAGES, LANG that is set, without encoding or modifier.
fn String locale_for(String requested, Environment env, Allocator allocator) @local
{
	if (requested.len > 0) return requested.copy(allocator);
	foreach (name : LOCALE_VARIABLES)
	{
		String value = env.get(tmem, name) ?? "";
		if (value.len == 0) continue;
		usz cut = value.len;
		for (usz i = 0; i < value.len; i++)
		{
			if (value[i] != '.' && value[i] != '@') continue;
			cut = i;
			break;
		}
		return value[:cut].copy(allocator);
	}
	return "".copy(allocator);
}

const String[3] LOCALE_VARIABLES = { "LC_ALL", "LC_MESSAGES", "LANG" };

fn void destroy(Allocator allocator, void* state)
{
	XdgBackend* backend = (XdgBackend*)state;
	backend.watcher.close();
	backend.children.free();
	backend.arena.free();
	alloc::free(allocator, backend);
}

<* The catalogue scan's context: the backend, and the list the visitor appends to. *>
struct ScanContext
{
	XdgBackend* backend;
	Allocator allocator;
	List{App}* apps;
}

<*
 Read every desktop file, keep the listed applications, and publish the result
 if it changed. Watches are set first, so changes made while scanning are seen.
*>
fn void refresh(XdgBackend* backend, AppsHub* hub)
{
	watch_applications(backend);
	CatalogueSnapshot* snapshot = hub.begin();
	List{App} apps;
	apps.tinit();
	ScanContext context = { .backend = backend, .allocator = snapshot.allocator(), .apps = &apps };
	// An unreadable data directory is skipped by the scan itself; nothing here can fail.
	if (catch desktop_entry::scan(backend.data_dirs, &context, &visit))
	{
	}
	snapshot.value.apps = apps.to_aligned_array(snapshot.allocator());
	apps::sort_catalogue(snapshot.value.apps);
	apps::publish_catalogue(hub, snapshot);
}

// The scan visitor: parse one file and keep it if it is a listed application.
fn void? visit(void* context, DesktopFile file) @private
{
	ScanContext* scan     = (ScanContext*)context;
	// A broken desktop file is skipped, as a launcher must; the rest of the catalogue stands.
	DesktopEntry*? loaded = desktop_entry::load(mem, file.path, scan.backend.locale);
	if (catch err = loaded) return;
	DesktopEntry* entry = loaded;
	defer entry.release();
	if (!apps::lists_entry(entry, scan.backend.desktops)) return;
	if (!try_exec_found(entry.try_exec, scan.backend.root)) return;
	scan.apps.push(apps::desktop_app(entry, file.id, file.path, scan.allocator));
}

<*
 Whether `TryExec` names a program that can run: an absolute path that is executable, or a name
 found in `$PATH`. An empty `TryExec` always passes. With a fake `root`, an absolute path is looked
 up under it; a bare name is still searched in the host's `$PATH`.
*>
fn bool try_exec_found(String program, String root) @local
{
	if (program.len == 0) return true;
	if (dirs::is_absolute(program))
	{
		String path = root.len > 0 ? string::tformat("%s%s", root, program) : program;
		return access(path.zstr_tcopy(), ACCESS_EXECUTE) == 0;
	}
	String search_path = env::tget_var("PATH") ?? "";
	foreach (directory : search_path.tsplit(ACCESS_PATH_SEPARATOR, 0, true))
	{
		if (access(string::tformat("%s/%s", directory, program).zstr_tcopy(), ACCESS_EXECUTE) == 0) return true;
	}
	return false;
}

// Watch every applications directory and its subdirectories, and the data directories
// themselves, so that the creation of a missing `applications/` directory is seen.
fn void watch_applications(XdgBackend* backend) @local
{
	foreach (data : backend.data_dirs)
	{
		// A directory that cannot be watched is picked up by the next scan; the watch is an optimisation.
		if (catch backend.watcher.watch(data))
		{
		}
		String applications = string::tformat("%s/%s", data.trim_right("/"), desktop_entry::APPLICATIONS_DIRECTORY);
		if (io::file::is_dir(applications)) watch_below(&backend.watcher, applications, 0);
	}
}

fn void watch_below(Watcher* watcher, String directory, int depth) @local
{
	if (depth > desktop_entry::MAX_SCAN_DEPTH) return;
	if (catch watcher.watch(directory))
	{
	}
	PathList? names = fs::list_dir(tmem, directory);
	if (catch err = names) return;
	foreach (name : names)
	{
		String child = string::tformat("%s/%s", directory, name);
		if (io::file::is_dir(child)) watch_below(watcher, child, depth + 1);
	}
}

<*
 The worker loop. Waits on the mailbox and on inotify; rescans after a quiet
 period and on REFRESH; serves launches; reaps children.
*>
fn void run(void* state, AppsHub* hub, AppsHost* host)
{
	XdgBackend* backend = (XdgBackend*)state;
	serve_until_stopped(backend, hub, host);
	// Every way out of the loop, a stop or a broken poller, fails the launches still queued and frees the bus.
	apps::refuse_pending(host);
	if (backend.bus_available) backend.bus.free();
	backend.bus_available = false;
}

<*
 The worker's event loop, until the host stops or poll(2) itself fails. A changed catalogue is rescanned
 once it has been quiet for `Options.settle`, or `MAX_CHANGE_DELAY` after its first change at the latest.
*>
fn void serve_until_stopped(XdgBackend* backend, AppsHub* hub, AppsHost* host) @local
{
	Poller poller;
	if (catch poller.init(mem, host.wakeup(), 1)) return;
	defer poller.free();
	if (backend.watcher.is_open())
	{
		if (catch poller.add({ .handle = backend.watcher.fd, .interest = { .readable = true }, .tag = WATCH_TAG })) return;
	}
	backend.bus_available = open_bus(backend);
	refresh(backend, hub);
	bool dirty      = false;
	Clock first     = clock::now();
	Clock last      = first;
	while (!host.stopping())
	{
		Duration timeout = time::FOREVER;
		if (dirty)
		{
			timeout = apps::rescan_wait(first, last, clock::now(), backend.settle, apps::MAX_CHANGE_DELAY);
		}
		else if (backend.children.size > 0)
		{
			timeout = CHILD_POLL;
		}
		if (catch err = poller.wait(timeout))
		{
			// TIMEOUT is the normal case: a quiet period ended, or a child needs reaping.
			// Anything else means poll(2) itself failed, and the worker has no way to go on.
			if (err != TIMEOUT) return;
		}
		Clock now = clock::now();
		if (backend.watcher.drain())
		{
			if (!dirty) first = now;
			dirty = true;
			last  = now;
		}
		bool refresh_now = false;
		apps::serve(backend, hub, host, &launch, &refresh_now);
		reap(backend);
		bool due = dirty && apps::rescan_wait(first, last, clock::now(), backend.settle, apps::MAX_CHANGE_DELAY) == time::DURATION_ZERO;
		if (refresh_now || due)
		{
			refresh(backend, hub);
			dirty = false;
		}
	}
}

<*
 The icon `icon` at `size` and `scale`: an absolute path that exists, or the file
 the theme chooses for the name.

 @return? NOT_FOUND : "No file of that name exists in the icon themes"
*>
fn String? icon_file(void* state, String icon, int size, int scale, Allocator allocator)
{
	XdgBackend* backend = (XdgBackend*)state;
	if (icon.len == 0) return NOT_FOUND~;
	if (dirs::is_absolute(icon))
	{
		if (io::file::is_file(icon)) return icon.copy(allocator);
		return NOT_FOUND~;
	}
	Finder* finder = icon::open(mem, backend.icon_dirs, backend.icon_theme);
	defer finder.release();
	return finder.find(allocator, icon, size, scale);
}