<*
 Keyboard layouts, as plain data.

 What a shell shows and changes: the layouts the user has configured, which one is active, and
 whether this process can change it. A layout's `id` is its stable handle: an xkb name such as `us`
 or `de(nodeadkeys)` (Linux), the input source id (macOS), or the input locale identifier written as
 a KLID (Windows, see `hkl.c3`). Positions in `State.layouts` follow the configuration and change;
 ids do not.
*>
module bleu::input;
import std::collections::maybe, std::time, bleu::availability, bleu::operation;

<*
 One keyboard layout. Every text is owned by the snapshot that holds it; "" means unknown.
*>
struct Layout
{
	String id;         // stable handle: xkb name, TIS input source id, or KLID text
	String name;       // display name for people: "English (US)", "German"
	String short_code; // two or three capital letters for a small indicator: "US", "DE"
	String language;   // BCP-47 tag of the layout's language: "en-US", "de-DE"
	String variant;    // xkb variant ("nodeadkeys"); "" for the default variant and off Linux
}

<*
 The whole picture. `layouts` is empty when the backend reports none. `current` is the index of the
 active layout in `layouts`, absent when the backend cannot say which one is active. `can_switch` is
 true when `switch_to` and `next` would be accepted now: a switch route is connected and there are
 two or more layouts.
*>
struct State
{
	Layout[] layouts;
	Maybe{uint} current;
	bool can_switch;
}

<* What the service can do here, and why not. *>
enum Cap : char
{
	LIST,    // `layouts` is the list of layouts the user can choose from
	CURRENT, // `current` says which layout is active
	SWITCH,  // `switch_to` and `next` change the active layout
	EVENTS,  // changes arrive as `Event`s and in the next snapshot
}

<* What changed. Read `latest()` for the values. *>
enum EventKind : char
{
	LAYOUTS_CHANGED, // the list of layouts changed: configuration or installed input sources
	CURRENT_CHANGED, // another layout became active; `layout_id` names it ("" when unknown)
}

<* A transient: what changed and, for `CURRENT_CHANGED`, to which layout. *>
struct Event
{
	EventKind kind;
	String layout_id;
}

<* The request kinds a shell can queue for the worker. *>
enum CommandKind : char
{
	REFRESH,   // read the platform again now
	SWITCH_TO, // make the layout named by `Command.id` active
}

<* The longest layout id a command carries. Ids are xkb names, input source ids or KLIDs. *>
const usz ID_CAPACITY = 128;

<*
 A queued request. Plain data: the id lives in `id`; `operation` is completed and released by the
 worker.
*>
struct Command
{
	CommandKind kind;
	char[ID_CAPACITY] id;
	usz id_len;
	SwitchOperation* operation;
}

<*
 How a switch was handed over. `ACKNOWLEDGED`: the compositor or the OS confirmed the change before it
 replied. `QUEUED`: the request was posted to the focused window, which applies it when it processes
 the message; the change then appears in the state.
*>
enum SwitchOutcome : char
{
	ACKNOWLEDGED,
	QUEUED,
}

<* A request that finishes later: `wait` returns how the switch was handed over. *>
alias SwitchOperation = Operation{SwitchOutcome};

<* Which concrete mechanism provides the data. *>
enum Backend : char
{
	AUTO,
	COMPOSITOR, // Linux: the running compositor's IPC (Hyprland, sway, niri), via bleu_compositor
	LOCALE1,    // Linux: systemd-localed's configured layouts, read-only, on the system bus
	TIS,        // macOS: Text Input Sources (HIToolbox)
	WIN32,      // Windows: keyboard layout list and the foreground window's layout
}

<*
 How `open` finds and tunes a backend. `poll` is how often a backend that is not woken by a change
 re-reads the platform; 0 means the default.
*>
struct Options
{
	Backend backend;
	Duration poll;
}
