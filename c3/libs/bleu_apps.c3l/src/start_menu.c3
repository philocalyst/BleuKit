<*
 The Windows backend: `.lnk` shortcuts in the two Start Menu `Programs` folders
 (per machine and per user).

 Each shortcut is an app. Its name is the file name without `.lnk`, its ID and
 `target` are the shortcut's path, and launching it hands that path to
 `ShellExecuteW`, which follows the shortcut. The shortcut's own target, icon
 and arguments are not read: resolving them needs `IShellLinkW`, which is not
 bound in this version. Changes are found by polling (`poll.c3`).

 Compiled for Windows only; it has not been run (see the library README).
 Sources: `ShellExecuteW` and its return convention (values above 32 mean
 success) from the Microsoft Learn page for ShellExecuteW.
*>
module bleu::apps::start_menu @feat(WIN32) @link("shell32");
import std::io, std::io::path, std::time, std::os::env, std::collections::list, bleu::apps, bleu::availability, bleu::error, bleu::rt::fs, bleu::rt::worker, bleu::service, bleu::win::text;

const Driver DRIVER = {
	.info = { "start-menu", "Start Menu shortcuts (.lnk) in the Programs folders", 10 },
	.id = Backend.START_MENU,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
	.icon = &apps::icon_unsupported,
};

const String PROGRAMS_SUFFIX   = "\\Microsoft\\Windows\\Start Menu\\Programs";
const String SHORTCUT_SUFFIX   = ".lnk";
const String VERB_OPEN         = "open";
const int SHOW_NORMAL          = 1;  // SW_SHOWNORMAL
const usz MENU_ARENA_PAGE      = 1024;
const int MAX_MENU_DEPTH       = 8;  // how deep the Programs folders are searched
const long SHELL_SUCCESS_ABOVE = 32; // ShellExecuteW returns a value greater than 32 on success

extern fn void* shell_execute_w(
	void* hwnd,
	Char16* operation,
	Char16* file,
	Char16* parameters,
	Char16* directory,
	int show
) @cname("ShellExecuteW");

<* Everything the Start Menu backend keeps. *>
struct MenuBackend
{
	DynamicArenaAllocator arena;
	String[] directories;
	Duration poll;
}

// The Start Menu exists on every Windows installation.
fn bool probe(Options* options) => true;

fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	MenuBackend* backend = alloc::new(allocator, MenuBackend);
	backend.arena.init(allocator, MENU_ARENA_PAGE);
	Allocator arena = &backend.arena;
	List{String} directories;
	directories.tinit();
	String machine = env::get_var(tmem, "ProgramData") ?? "";
	String user    = env::get_var(tmem, "APPDATA") ?? "";
	if (machine.len > 0) directories.push(string::tformat("%s%s", machine, PROGRAMS_SUFFIX).copy(arena));
	if (user.len > 0) directories.push(string::tformat("%s%s", user, PROGRAMS_SUFFIX).copy(arena));
	backend.directories = directories.to_aligned_array(arena);
	backend.poll = options.poll;
	capabilities.init(availability::YES);
	capabilities.values[Cap.WATCH.ordinal] = availability::no(
		availability::Reason.DEGRADED,
		"the Start Menu folders are polled every few seconds; ReadDirectoryChangesW is not used"
	);
	capabilities.values[Cap.ICON.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"shortcut icons are not read in this version"
	);
	capabilities.values[Cap.LAUNCH_ACTION.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_OS,
		"shortcuts have no desktop actions"
	);
	capabilities.values[Cap.DBUS_ACTIVATE.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_OS,
		"D-Bus activation exists only on Linux"
	);
	capabilities.values[Cap.TERMINAL_WRAP.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_OS,
		"Terminal= is a desktop entry key"
	);
	return backend;
}

fn void destroy(Allocator allocator, void* state)
{
	MenuBackend* backend = (MenuBackend*)state;
	backend.arena.free();
	alloc::free(allocator, backend);
}

fn void run(void* state, AppsHub* hub, AppsHost* host)
{
	MenuBackend* backend = (MenuBackend*)state;
	apps::run_polled(backend, hub, host, backend.poll, backend.directories, &refresh, &launch);
}

<* List every shortcut under the Programs folders and publish the catalogue. *>
fn void refresh(void* state, AppsHub* hub)
{
	MenuBackend* backend        = (MenuBackend*)state;
	CatalogueSnapshot* snapshot = hub.begin();
	List{App} apps;
	apps.tinit();
	foreach (directory : backend.directories) collect(directory, 0, snapshot.allocator(), &apps);
	snapshot.value.apps = apps.to_aligned_array(snapshot.allocator());
	apps::sort_catalogue(snapshot.value.apps);
	apps::publish_catalogue(hub, snapshot);
}

// Add the shortcuts in `directory` and below it. An unlisted folder is skipped.
fn void collect(String directory, int depth, Allocator allocator, List{App}* apps) @local
{
	if (depth > MAX_MENU_DEPTH) return;
	PathList? names = fs::list_dir(tmem, directory);
	if (catch err = names) return;
	foreach (name : names)
	{
		String child = string::tformat("%s\\%s", directory, name);
		if (io::file::is_dir(child))
		{
			collect(child, depth + 1, allocator, apps);
			continue;
		}
		if (!name.ends_with(SHORTCUT_SUFFIX)) continue;
		String title = name[0:name.len - SHORTCUT_SUFFIX.len];
		apps.push(
			{
				.id = child.copy(allocator),
				.name = title.copy(allocator),
				.launch = SHELL_LINK,
				.target = child.copy(allocator),
				.location = child.copy(allocator),
			}
		);
	}
}

<*
 Start the shortcut in `request` with ShellExecuteW.

 @return? error::UNSUPPORTED : "A secondary action is requested; shortcuts have none"
 @return? error::BACKEND_FAILURE : "The shell refused or could not start the shortcut"
*>
fn Launched? launch(void* state, App* app, AppAction* action, LaunchRequest* request) @local
{
	if (action != null) return error::raise(
		error::UNSUPPORTED,
		error::Domain.INTERNAL,
		0,
		"%s has no actions",
		app.id
	)~;
	WideZ target     = text::to_wide(tmem, app.target)!;
	WideZ verb       = text::to_wide(tmem, VERB_OPEN)!;
	WideZ parameters = text::to_wide(tmem, join(request.args))!;
	long result      = (long)shell_execute_w(
		null,
		verb.as_wstring(),
		target.as_wstring(),
		parameters.as_wstring(),
		null,
		SHOW_NORMAL
	);
	if (result <= SHELL_SUCCESS_ABOVE)
	{
		return error::raise(
			error::BACKEND_FAILURE,
			error::Domain.WIN32,
			(int)result,
			"ShellExecuteW could not open %s",
			app.target
		)~;
	}
	return { .route = SHELL_EXECUTE, .pid = 0 };
}

// The arguments as one command-line string, separated by spaces. Temporary.
fn String join(String[] args) @local
{
	DString line;
	line.init(tmem);
	foreach (i, argument : args)
	{
		if (i > 0) line.append_string(" ");
		line.append_string(argument);
	}
	return line.str_view();
}