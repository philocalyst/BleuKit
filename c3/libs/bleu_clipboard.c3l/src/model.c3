<*
 Clipboard and primary selection, as plain data.

 `current` and `primary` describe the two selections as they are now, with the
 MIME types their owner offered. `history` is the text the service kept from earlier
 copies, newest first, so it survives the application that copied it.

 Payload bytes are never published: a snapshot carries types, a bounded preview and
 sizes only. Bytes are fetched on demand with `Clipboard.fetch`.
*>
module bleu::clipboard;
import std::time;

<* Which selection a request refers to. *>
enum Slot : char
{
	CLIPBOARD, // the regular copy and paste selection (Ctrl+C / Ctrl+V)
	PRIMARY,   // the select-to-copy selection (middle click on X11 and Wayland)
}

<*
 What a source said about its content through a marker type. Anything but OPEN keeps
 the content out of the history and out of the preview; the state says only that the
 marker was present.
*>
enum Privacy : char
{
	OPEN,
	TRANSIENT, // meant to vanish within seconds; not recorded (org.nspasteboard.TransientType)
	CONCEALED, // a secret: password managers, not recorded (x-kde-passwordManagerHint, ...)
}

<* One selection as it is now. `seq` changes every time the selection changes. *>
struct Selection
{
	bool present;        // false when nothing is selected
	bool owned;          // true when this service is the source (set by `Clipboard.set`)
	ulong seq;           // the selection's sequence number; the id of its history entry
	String[] mime_types; // the types offered, in the order the owner offered them
	Privacy privacy;     // marker state; when not OPEN no bytes were read
	String preview;      // bounded, sanitised text of the captured text type; "" when none was read
	usz size;            // bytes of the captured text type; 0 when none was read
}

<*
 A text copy kept in the history. `id` is the selection's `seq` at the time of the
 copy, and it is what `Clipboard.fetch` and `Clipboard.delete` take.
*>
struct Entry
{
	ulong id;
	Time time;           // wall-clock time when the copy was captured
	String[] mime_types; // every type the owner offered with it
	String preview;      // bounded, sanitised text
	usz size;            // bytes of the stored text
}

<* The whole picture: both selections and the history, newest entry first. *>
struct State
{
	Selection current;
	Selection primary;
	Entry[] history;
}

<* Optional behaviours. Every one has an `Availability` in `Clipboard.capability`. *>
enum Cap : char
{
	READ_TEXT,         // read the text of either selection
	WRITE_TEXT,        // own the selection with text
	WRITE_TYPES,       // own the selection with arbitrary MIME types and bytes
	FETCH_TYPE,        // read any offered MIME type of the current selection, with a size cap
	WATCH,             // selection changes arrive as events and in the state
	PRIMARY_SELECTION, // observe and own the primary selection
	HISTORY,           // text copies outlive the application that made them
	PRIVACY_MARKERS,   // concealed and transient markers keep content out of the history
}

<* A transient: what happened. Read the state for the content. *>
enum EventKind : char
{
	SELECTION_CHANGED, // the selection named by `slot` changed owner or content
	OWNERSHIP_LOST,    // another application replaced the selection this service owned
}

<* A transient event. *>
struct Event
{
	EventKind kind;
	Slot slot;
}

<* One MIME type and its bytes, for `Clipboard.set`. *>
struct Representation
{
	String mime;
	char[] bytes;
}

<* The kinds of request the worker runs. *>
enum CommandKind : char
{
	SET,    // own a selection with `representations`
	CLEAR,  // release a selection this service owns
	FETCH,  // read one MIME type of an entry
	DELETE, // remove a history entry
}

<*
 A request queued for the worker. `operation` is a retained `Operation{T}*` whose `T`
 is fixed by `kind`. Strings and bytes in the command live in that operation's arena.
*>
struct Command
{
	CommandKind kind;
	void* operation;
	Slot slot;
	ulong id;
	String mime;
	Representation[] representations;
}

<* Which concrete mechanism provides the selections. *>
enum Backend : char
{
	AUTO,
	WAYLAND,    // Linux: ext-data-control-v1, then wlr-data-control-unstable-v1
	PASTEBOARD, // macOS: NSPasteboard
	WIN32,      // Windows: the clipboard API
}

<* Bytes of one MIME type that `Clipboard.fetch` returns. The slice lives in the operation. *>
alias Bytes = char[];
