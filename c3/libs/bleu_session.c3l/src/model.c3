<*
 Session and login state, as plain data.

 What a shell needs about the user's session: whether the screen is locked, whether the
 user has been idle for the thresholds it asked for, whether the machine is going to sleep,
 and which sessions and seats exist. A value the platform cannot tell is a `Maybe` empty,
 never `false`: "not locked" is a fact, "lock state unknown" is a different fact.
*>
module bleu::session;
import std::collections::maybe, std::time, bleu::operation;

<* The session type a platform reports (logind `Type`); UNKNOWN when it is not reported. *>
enum SessionType : char
{
	UNKNOWN,
	UNSPECIFIED,
	TTY,
	X11,
	WAYLAND,
	MIR,
}

<*
 One login session. An empty string or an empty `Maybe` means the platform did not
 report that field.
*>
struct SessionInfo
{
	String id;
	String user;
	Maybe{uint} uid;
	String seat;
	SessionType type;
	Maybe{bool} active;
	Maybe{bool} remote;
}

<* Whether the user has been idle for at least `threshold`. `threshold` is one of `Options.idle_thresholds`. *>
struct IdleStatus
{
	Duration threshold;
	bool idle;
}

<*
 The whole picture. `locked` and `idle_hint` describe the session this process runs in and
 are empty when there is none or the platform cannot tell. `sleeping` is true from the moment
 the system announces that it is going to sleep until it reports that it has woken.
*>
struct State
{
	Maybe{bool} locked;
	Maybe{bool} idle_hint;
	bool sleeping;
	SessionInfo current;
	String[] seats;
	SessionInfo[] sessions;
	IdleStatus[] idle;
}

<* A capability of this service. Each has an `Availability` on the open service. *>
enum Cap : char
{
	LOCK_STATE,        // `State.locked` and LOCKED / UNLOCKED events
	LOCK,              // `Session.lock`: lock the session this process runs in
	UNLOCK,            // `Session.unlock`: ask the session's locker to unlock
	LOCK_SESSION,      // `Session.lock_session`: lock any session by id
	TERMINATE_SESSION, // `Session.terminate_session`
	IDLE_WATCH,        // `Session.watch_idle`: IDLE and RESUMED edges
	IDLE_HINT,         // `State.idle_hint`
	SLEEP_EVENTS,      // `State.sleeping` and WILL_SLEEP / DID_WAKE events
	SESSION_LIST,      // `State.sessions` and `State.seats`
}

<*
 A transient. For IDLE and RESUMED, `watch` names the `IdleWatch` it belongs to (0 for a
 threshold of `Options.idle_thresholds`) and `threshold` is the idle time it refers to.
 Other kinds leave both at their zero values.
*>
struct Event
{
	EventKind kind;
	ulong watch;
	Duration threshold;
}

enum EventKind : char
{
	LOCKED,
	UNLOCKED,
	IDLE,
	RESUMED,
	WILL_SLEEP,
	DID_WAKE,
}

<* The requests that complete an operation, in the order `Session` offers them. *>
enum Request : char
{
	LOCK,
	UNLOCK,
	LOCK_SESSION,
	TERMINATE_SESSION,
}

<* A request that finishes later. Its value is the request that was carried out. *>
alias SessionOperation = Operation{Request};

<* Which concrete mechanism provides the data. *>
enum Backend : char
{
	AUTO,   // try every backend of the platform in priority order
	LOGIND, // Linux: systemd-logind on the system bus
	MACOS,  // macOS: CoreGraphics session and HID idle time, IOKit power
	WIN32,  // Windows: WTS session notifications, GetLastInputInfo, power broadcasts
}

<* The kinds of command the service posts to its worker. *>
enum CommandKind : char
{
	REQUEST,      // carry out `request` for `session`, completing `operation`
	WATCH_IDLE,   // start reporting edges for `watch` at `threshold`
	UNWATCH_IDLE, // stop reporting edges for `watch`
}

<* One command for the worker. Fields a kind does not use stay at their zero values. *>
struct Command
{
	CommandKind kind;
	Request request;
	String session;
	SessionOperation* operation;
	ulong watch;
	Duration threshold;
}