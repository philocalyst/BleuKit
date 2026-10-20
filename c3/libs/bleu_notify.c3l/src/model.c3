<*
 Desktop notifications, as plain data.

 The notification centre: the state of every notification this service shows
 (`active`, newest first) and remembers (`history`, newest first), whether
 do-not-disturb is on, and whether this process owns the freedesktop
 notification bus name. Everything the shell needs to draw the centre is here;
 the body is already sanitised into `Span` runs, so no markup reaches the UI.
*>
module bleu::notify;
import std::time, std::collections::maybe, std::collections::enummap, bleu::unit, bleu::availability, bleu::operation;

<* Identifier of a notification, unique for the session and never zero. *>
alias NoteId = uint;

<* How important a notification is. The spec's urgency byte: 0, 1, 2. *>
enum Urgency : char
{
	LOW,
	NORMAL,
	CRITICAL, // never expires on its own
}

<*
 Why a notification left the screen. The values are the freedesktop spec's
 NotificationClosed reasons; the spec defines no reason for an action, so an
 invoked, non-resident notification closes with CLOSED_BY_CALL (as Astal does).
*>
constset CloseReason : uint
{
	EXPIRED        = 1, // its timeout passed
	DISMISSED      = 2, // the user dismissed it (a shell calls close_notification with this)
	CLOSED_BY_CALL = 3, // CloseNotification, or an action on a non-resident notification
	UNDEFINED      = 4, // this server evicted it to make room (the spec's reserved reason)
}

<*
 A run of body text with one style. A link is the `href` of the innermost `<a>`
 around it; `link` is empty when there is none.
*>
struct Span
{
	String text;
	bool bold;
	bool italic;
	bool underline;
	String link;
}

<* One button or the default click action of a notification. `key` "default" is the click. *>
struct Action
{
	String key;
	String label;
}

<*
 A decoded `image-data` image: row-major pixels, `channels` bytes per pixel
 (3 for RGB, 4 for RGBA), rows `rowstride` bytes apart. Bytes are `char` because
 C3 has no `ubyte`.
*>
struct Image
{
	int width;
	int height;
	int rowstride;
	bool has_alpha;
	int channels;
	char[] pixels;
}

<*
 One notification as the centre shows it. Strings and arrays live in the
 snapshot that holds this value. `has_image` is true when `image` is set;
 history keeps the flag but not the pixels, which are dropped when the
 notification leaves the screen.
*>
struct Notification
{
	NoteId id;
	Time created;
	Maybe{Time} expires; // no value: it stays until closed
	Urgency urgency;
	String app_name;
	String app_icon;
	String desktop_entry;
	String category;
	String summary;
	Span[] body;
	Action[] actions;
	String image_path;
	bool has_image;
	Image image;
	Maybe{Level} progress; // the `value` hint, 0 to 100 percent
	String stack_tag; // notifications with the same tag replace each other
	bool resident; // stays open after an action
	bool transient; // never enters history
	bool suppress_sound; // the sender plays its own sound
	String sound_name; // themed sound name, to be played by the shell if it wants
	String sound_file; // path of a sound file, likewise
}

<*
 The notification centre: what is on screen, what was, and the switches.
 `count` is the number of notifications accepted since the service started
 (a replacement counts once for each Notify call).
*>
struct State
{
	bool serving; // this process owns org.freedesktop.Notifications
	bool do_not_disturb; // non-critical notifications are recorded, not shown
	uint count;
	Notification[] active;
	Notification[] history;
}

<* Capabilities of the notification centre on this backend. *>
enum Cap : char
{
	SERVE,            // we are the notification server (owns the bus name)
	ACTIONS,          // invoke_action emits ActionInvoked and closes non-resident notifications
	BODY_MARKUP,      // the body is sanitised to the spec's subset
	IMAGE_DATA,       // image-data hints are decoded and kept
	PROGRESS,         // the `value` hint is kept
	STACK_TAG,        // stack tags replace the notification they name
	DO_NOT_DISTURB,   // set_do_not_disturb
	HISTORY,          // closed notifications are kept
	ACTIVATION_TOKEN, // no activation token source: ActivationToken is never emitted
	PERSISTENCE,      // history is in memory only, not on disk
	SOUND,            // sound hints are recorded but nothing plays them
}

<* Availability of every `Cap`. *>
alias Capabilities = EnumMap{Cap, Availability};

<* What happened. Re-read the state for the details. *>
enum EventKind : char
{
	POSTED,         // a notification was shown (new or replaced); `replaced` tells which
	CLOSED,         // a notification left the screen, with `reason`
	ACTION_INVOKED, // an action or the default click was invoked, with `action_key`
}

<* A transient: something that happened. Strings are owned by the packet. *>
struct Event
{
	EventKind kind;
	NoteId id;
	bool replaced;
	CloseReason reason;
	String action_key;
}

<* Longest action key a command may carry; longer keys are refused, not truncated. *>
const usz MAX_ACTION_KEY = 64;

enum CommandKind : char
{
	CLOSE,
	INVOKE_ACTION,
	SET_DO_NOT_DISTURB,
	CLEAR_HISTORY,
}

<*
 A request for the worker. The key is copied into the command because the caller
 may release its string at once. `operation` is set for commands that report back.
*>
struct Command
{
	CommandKind kind;
	NoteId id;
	CloseReason reason;
	bool flag;
	char[MAX_ACTION_KEY] key;
	usz key_len;
	Operation{bool}* operation;
}

<* Which concrete mechanism provides the notification centre. *>
enum Backend : char
{
	AUTO,
	FDO, // Linux: we own org.freedesktop.Notifications on the session bus
}

<* Lengths the server accepts from applications. Longer text is truncated on a character boundary. *>
const usz MAX_APP_NAME        = 256;
const usz MAX_ICON            = 1024;
const usz MAX_SUMMARY         = 1024;
const usz MAX_BODY            = 8192;
const usz MAX_ACTIONS         = 16;   // pairs; further pairs are dropped
const usz MAX_ACTION_LABEL    = 256;
const usz MAX_CATEGORY        = 64;
const usz MAX_DESKTOP_ENTRY   = 256;
const usz MAX_IMAGE_PATH      = 1024;
const usz MAX_STACK_TAG       = 128;
const usz MAX_SOUND           = 1024;
const usz MAX_SPANS           = 256;
const usz MAX_LINK            = 2048;
const usz MAX_IMAGE_BYTES     = 512 * 1024;
const int MAX_IMAGE_DIMENSION = 4096;
const int MAX_EXPIRE_MS       = 86_400_000; // one day

const usz DEFAULT_MAX_OPEN            = 20;
const usz DEFAULT_MAX_PER_SENDER      = 10;
const usz DEFAULT_HISTORY_LIMIT       = 50;
const Duration DEFAULT_LOW_TIMEOUT    = (Duration)5_000_000;  // 5 s, microseconds
const Duration DEFAULT_NORMAL_TIMEOUT = (Duration)10_000_000; // 10 s

<*
 How the centre behaves when an application does not say. `max_open` caps the
 notifications held open at once, `history_limit` the closed ones kept. The
 default timeouts apply when a notification sends expire_timeout -1; critical
 notifications never expire. A zero `max_open` selects the whole default policy.
*>
struct Policy
{
	usz max_open;
	usz max_per_sender; // open notifications one sender may hold; 0 means no per-sender cap
	usz history_limit;
	Duration low_timeout;
	Duration normal_timeout;
}

const Policy DEFAULT_POLICY = {
	.max_open = DEFAULT_MAX_OPEN,
	.max_per_sender = DEFAULT_MAX_PER_SENDER,
	.history_limit = DEFAULT_HISTORY_LIMIT,
	.low_timeout = DEFAULT_LOW_TIMEOUT,
	.normal_timeout = DEFAULT_NORMAL_TIMEOUT,
};

<*
 How `open` finds and tunes the centre. `replace` takes the bus name from the daemon
 that holds it, but only when that daemon allows replacement. A centre from this
 library never allows it: any process could otherwise take every notification.
*>
struct Options
{
	Backend backend;
	bool replace;
	Policy policy;
}