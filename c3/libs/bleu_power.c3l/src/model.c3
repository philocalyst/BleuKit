<*
 Power management state, requests and events, as plain data.

 What a shell needs to show and control the machine's power: the active
 power profile and whether it is being held back, Low Power Mode or battery
 saver, the lid, external power, the idle hint, and the actions the machine can
 take (suspend, power off, lock ...). Requests that take time are operations;
 the state they cause is published as `State`, and what happened is an `Event`.
*>
module bleu::power;
import std::collections::maybe, bleu::availability, bleu::operation;

<*
 A power profile. The names are the ones power-profiles-daemon uses; other
 platforms map their own modes onto them or report no profile at all.
*>
enum Profile : char
{
	UNKNOWN,
	POWER_SAVER,
	BALANCED,
	PERFORMANCE,
}

<*
 Why the active profile is held back. `OTHER` keeps a reason this library does
 not name yet; the daemon's text is not lost to `NONE`. `UNKNOWN` is the zero value:
 no daemon, or it could not be read, so `NONE` (not degraded) is never a guess.
*>
enum Degraded : char
{
	UNKNOWN,
	NONE,
	LAP_DETECTED,
	HIGH_TEMPERATURE,
	OTHER,
}

<*
 The whole picture. Every field the platform cannot tell is an empty `Maybe`,
 never a guessed value: "unknown" is a different fact from `false`.
*>
struct State
{
	Maybe{Profile} active_profile; // empty when the platform has no profile service
	Profile[] profiles; // selectable profiles, in the daemon's order
	Degraded degraded; // NONE unless the active profile is held back
	Maybe{bool} low_power_mode; // macOS Low Power Mode
	Maybe{bool} battery_saver; // Windows battery saver
	Maybe{bool} lid_closed; // Linux logind LidClosed
	Maybe{bool} on_external_power; // Linux logind OnExternalPower, macOS and Windows adapter state
	Maybe{bool} idle_hint; // Linux logind IdleHint: the session is idle
}

<*
 A capability of the service. The service answers each one with an `Availability` through
 `Power.capability`, so a shell can grey out what cannot work here, and say why.
*>
enum Cap : char
{
	PROFILE_READ,
	PROFILE_SET,
	PROFILE_HOLD,
	LOW_POWER_READ,
	BATTERY_SAVER_READ,
	KEEP_AWAKE_IDLE,
	KEEP_AWAKE_DISPLAY,
	KEEP_AWAKE_SYSTEM,
	DELAY_SLEEP_HOOK,
	BLOCK_SHUTDOWN,
	SUSPEND,
	HIBERNATE,
	HYBRID_SLEEP,
	POWER_OFF,
	REBOOT,
	LOCK,
	LOGOUT,
	IDLE_HINT,
	LID_EVENTS,
	AC_EVENTS,
}

<* Actions that end or change the session or the machine's power state. *>
enum Action : char
{
	SUSPEND,
	HIBERNATE,
	HYBRID_SLEEP,
	POWER_OFF,
	REBOOT,
	LOCK,
	LOGOUT,
}

<*
 Something that keeps the machine from doing what `InhibitKind` names until it
 is released. Each kind is one `Cap`.
*>
enum InhibitKind : char
{
	KEEP_AWAKE_IDLE,    // no automatic suspend or idle action while the user is idle
	KEEP_AWAKE_DISPLAY, // the display does not dim or turn off
	KEEP_AWAKE_SYSTEM,  // no sleep at all, even when the user asks for it
	SLEEP_DELAY,        // the machine waits for the holder before sleeping (see `Event.PREPARE_SLEEP`)
	SHUTDOWN_BLOCK,     // the machine waits for the holder before shutting down
}

<*
 A transient: something happened. Re-read `State` for the values.

 `PREPARE_SLEEP` may be a barrier. When `ticket` is not zero the machine waits
 for `Power.ack(ticket)` (or a timeout chosen by the OS) before it sleeps.
*>
enum EventKind : char
{
	PREPARE_SLEEP,
	RESUMED,
	LID_CLOSED,
	LID_OPENED,
	EXTERNAL_POWER_CONNECTED,
	EXTERNAL_POWER_DISCONNECTED,
}

<* A transient event. `ticket` is non-zero only for a `PREPARE_SLEEP` barrier. *>
struct Event
{
	EventKind kind;
	uint ticket;
}

<*
 Which concrete mechanism provides the service. `AUTO` tries the platform's
 mechanisms in priority order.
*>
enum Backend : char
{
	AUTO,
	LOGIND, // Linux: org.freedesktop.login1, plus power-profiles-daemon when it is on the bus
	MACOS,  // macOS: IOPowerSources, IOPMAssertion, IORegisterForSystemPower, NSProcessInfo
	WIN32,  // Windows: GetSystemPowerStatus, PowerCreateRequest, SetSuspendState, ...
}

alias ProfileOperation = Operation{Profile};
alias HoldOperation = Operation{ProfileHold};
alias InhibitOperation = Operation{Inhibitor};
alias AvailabilityOperation = Operation{Availability};
alias ActionOperation = Operation{Action};

<*
 A profile hold: while it lives, the daemon keeps the profile. Release it with
 `release`. Holds also end when the process ends.
*>
struct ProfileHold
{
	uint cookie;
	Link* link; // the reference this handle owns; see link.c3
}

<*
 An inhibitor: while it lives, the machine does what its kind forbids. Release
 it with `release`. Closing the service releases every inhibitor.
*>
struct Inhibitor
{
	uint id;
	Link* link; // the reference this handle owns; see link.c3
}

<*
 A request for the worker. Plain data: the typed operation pointer is the one
 the request completes, and the worker holds a reference to it until it does.
 `who` and `why` live in that operation's arena.
*>
enum CommandKind : char
{
	SET_PROFILE,
	HOLD_PROFILE,
	RELEASE_PROFILE,
	INHIBIT,
	RELEASE_INHIBITOR,
	CAN,
	PERFORM,
	ACK_SLEEP,
}

struct Command
{
	CommandKind kind;
	Profile profile;
	InhibitKind inhibit;
	Action action;
	uint number; // RELEASE_PROFILE: the cookie; RELEASE_INHIBITOR: the id; ACK_SLEEP: the ticket
	String who;
	String why;
	Link* link; // the handle's link: the worker takes the handle's reference on it
	ProfileOperation* profile_op;
	HoldOperation* hold_op;
	InhibitOperation* inhibit_op;
	AvailabilityOperation* can_op;
	ActionOperation* action_op;
}