<*
 The application catalogue, as plain data.

 One `App` is one thing a launcher or dock can start: a Linux desktop entry, a
 macOS application bundle, a Windows Start Menu shortcut. Strings that a
 platform does not have are empty; lists that it does not have are empty
 slices. Nothing here names an operating system.
*>
module bleu::apps;
import bleu::availability, bleu::observe, bleu::operation, bleu::service, bleu::stream;

<*
 How an app is started when no other route applies.

 `EXEC` runs the `Exec` line of a desktop entry, `APP_BUNDLE` opens a macOS
 `.app` directory, `SHELL_LINK` hands a Windows `.lnk` to the shell.
*>
enum AppLaunchKind : char
{
	EXEC,
	APP_BUNDLE,
	SHELL_LINK,
}

<*
 A named secondary action of an app (a desktop entry's `[Desktop Action X]`
 group). `id` is what `launch_action` takes.
*>
struct AppAction
{
	String id;
	String name;
	String icon;
	String exec;
}

<*
 One launchable app.

 `id` is stable across snapshots and is how commands and events refer to the
 app: the desktop file ID on Linux (`org.example.App.desktop`), the bundle
 identifier on macOS, the shortcut's path on Windows.

 `icon` is an icon name or an absolute path, as the app wrote it; turn it into a
 file with `Apps.icon_file` at the size you need.

 `target` is the thing `launch` runs: the `Exec` line on Linux, the bundle
 path on macOS, the `.lnk` path on Windows.

 `no_display` apps are launchable but a menu should not list them. Entries that
 are hidden, or not shown in the current desktop, are not in the catalogue.
*>
struct App
{
	String id;
	String name;
	String generic_name;
	String comment;
	String[] keywords;
	String[] categories;
	String icon;
	AppLaunchKind launch;
	String target;
	String location; // the file the app was read from, for diagnostics and `%k`
	bool terminal;
	bool no_display;
	bool dbus_activatable;
	bool startup_notify;
	String startup_wm_class;
	String bundle_id; // macOS bundle identifier; Windows AUMID when known; empty on Linux
	AppAction[] actions;
	String[] mime_types;
}

<*
 The whole catalogue. `apps` is sorted by `name` (ASCII case-insensitive), then
 by `id`, so two snapshots of the same installation compare equal.
*>
struct State
{
	App[] apps;
}

<*
 A capability of this service. Each is reported through `Apps.capability` as an
 `Availability`, never assumed.
*>
enum Cap : char
{
	CATALOGUE,     // list the apps
	LAUNCH,        // start an app
	LAUNCH_ACTION, // start one of an app's secondary actions
	DBUS_ACTIVATE, // hand D-Bus-activatable apps to their bus name
	TERMINAL_WRAP, // run `Terminal=true` apps inside a terminal emulator
	ICON,          // resolve icon names to files
	WATCH,         // notice catalogue changes as they happen (otherwise polled)
}

<* What changed in the catalogue. Re-read the state for the details. *>
enum EventKind : char
{
	APP_ADDED,
	APP_REMOVED,
	APP_CHANGED,
}

<* A transient: an app was added, removed or changed. *>
struct Event
{
	EventKind kind;
	String app_id;
}

<* The kind of work a command asks the worker to do. *>
enum CommandKind : char
{
	REFRESH, // rescan the catalogue now
	LAUNCH,  // start an app or one of its actions; see `LaunchRequest`
}

<* How a launch was carried out. *>
enum LaunchRoute : char
{
	SPAWN,         // a child process was started directly
	TERMINAL,      // a child process was started inside a terminal emulator
	DBUS_ACTIVATE, // the app's bus name was asked to activate it
	BUNDLE_OPEN,   // macOS: NSWorkspace opened the bundle
	SHELL_EXECUTE, // Windows: the shell opened the shortcut
}

<*
 The value of a successful launch.

 `pid` is the child process when there is one, `0` otherwise (a D-Bus
 activation or a shell launch does not tell us the process).
*>
struct Launched
{
	LaunchRoute route;
	long pid;
}

<*
 Which backend provides the catalogue. `AUTO` tries the platform's backends in
 priority order.
*>
enum Backend : char
{
	AUTO,
	XDG_DESKTOP, // Linux: Desktop Entry files in the XDG data directories
	APP_BUNDLES, // macOS: .app bundles in the Applications folders
	START_MENU,  // Windows: .lnk files in the Start Menu folders
}

<* Operation that a launch completes with. *>
alias LaunchOperation = Operation{Launched};

<* Snapshot of the catalogue. *>
alias CatalogueSnapshot = Snapshot{State};

<* The hub every backend publishes into. *>
alias AppsHub = Hub{State, Command, Event};