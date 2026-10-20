<*
 Global keyboard shortcuts, as plain data.

 A shell registers a shortcut by id with a description and a chord ("Ctrl+Alt+T"). The state
 says which registrations the platform accepted (`BindingState`), and transient events say
 when a shortcut was pressed or released. Nothing here names an operating system.
*>
module bleu::hotkey;
import std::collections::maybe, std::time, bleu::availability, bleu::observe, bleu::operation, bleu::service, bleu::stream, bleu::hotkey::keys;

<* A key with the modifiers held down with it, e.g. Ctrl+Alt+T. *>
struct Chord
{
	Modifiers mods;
	keys::Key key;
}

<*
 Where one registration stands.

 PENDING: accepted, the platform has not answered yet. BOUND: the platform will deliver presses.
 CONFLICT: another program already owns the chord (Windows reports this; see `Cap.CONFLICT_REPORT`).
 REFUSED: the platform or the user did not allow it (a portal dialog was dismissed or declined).
*>
enum BindingState : char
{
	PENDING,
	BOUND,
	CONFLICT,
	REFUSED,
}

<*
 One registration. `trigger` is the text the platform shows for the chord when it has one (the
 portal's `trigger_description`); empty otherwise.
*>
struct Binding
{
	String id;
	String description;
	Chord chord;
	BindingState state;
	String trigger;
}

<*
 Everything the service knows right now.

 `portal_version` is the version of org.freedesktop.portal.GlobalShortcuts the desktop offers, 0
 when it does not offer the interface. `registration` says whether new shortcuts can be bound at
 all right now, and why not when they cannot.
*>
struct State
{
	Binding[] bindings;
	uint portal_version;
	Availability registration;
}

<* One capability of the service. Each has an `Availability` in `Hotkey.capability`. *>
enum Cap : char
{
	REGISTER,           // binding a new shortcut
	UNREGISTER,         // removing one
	PRESS_RELEASE,      // `EventKind.RELEASED` events
	CONFLICT_REPORT,    // `BindingState.CONFLICT` when another program owns the chord
	ACTIVATION_TOKEN,   // an activation token in the events, for focusing a window
	PLATFORM_TIMESTAMP, // `Event.platform_time` from the platform's own clock
}

<* What happened to a shortcut. *>
enum EventKind : char
{
	PRESSED,
	RELEASED,
}

<*
 A transient: a shortcut was pressed or released. `at` is the monotonic time of receipt, so it is
 always set; `platform_time` is the platform's own timestamp when it gives one, and
 `activation_token` is the token a focus-stealing window needs, when the platform gives one.
*>
struct Event
{
	EventKind kind;
	String id;
	Clock at;
	Maybe{ulong} platform_time;
	String activation_token;
}

<* The request kinds a backend's worker receives. *>
enum CommandKind : char
{
	REGISTER,
	UNREGISTER,
}

<*
 A queued request. `id`, `description` and `chord` are copied into the operation's arena, which
 lives until the worker completes `operation`.
*>
struct Command
{
	CommandKind kind;
	String id;
	String description;
	Chord chord;
	Operation{Binding}* operation;
}

<* Which concrete mechanism provides the shortcuts. *>
enum Backend : char
{
	AUTO,
	PORTAL, // Linux: org.freedesktop.portal.GlobalShortcuts (xdg-desktop-portal)
	CARBON, // macOS: RegisterEventHotKey
	WIN32,  // Windows: RegisterHotKey
}

<* How `open` finds and tunes a backend. *>
struct Options
{
	Backend backend; // AUTO tries every backend of the platform in priority order
}

<* The result of an accepted request: the registration as it stands once the request finished. *>
alias Task = Operation{Binding};
alias HotkeyHub = Hub{State, Command, Event};