<*
 Media players of other applications, as plain data.

 A player is any application that shows its now-playing state through the
 operating system: an MPRIS player on Linux, a System Media Transport Controls
 session on Windows, a scripted music app on macOS. Each player carries what a
 now-playing card and a transport bar need: identity, status, track, a position
 that can be extrapolated (see `Player.position_now`), volume and the
 controls the player says it has.

 Plain data only: no pointers, no OS names. Optional measurements are `Maybe`,
 because "unknown" is not "zero".
*>
module bleu::media;
import std::collections::maybe, std::time, bleu::unit, bleu::operation;

<* What the player is doing. Anything the platform calls "changing" or "closed" is `STOPPED`. *>
enum Playback : char
{
	STOPPED,
	PLAYING,
	PAUSED,
}

<* Repeat behaviour, as MPRIS `LoopStatus` and SMTC `AutoRepeatMode` both express it. *>
enum Loop : char
{
	NONE,
	TRACK,
	PLAYLIST,
}

<* Playback speed as a multiplier: 1.0 is normal speed, negative values rewind. *>
alias PlaybackRate = double;

<*
 A position read from the player and the monotonic time it was read at.
 `position` is in microseconds, `taken_at` on the clock of `monotonic_now()`.
*>
struct Anchor
{
	Duration position;
	Duration taken_at;
}

<*
 The track a player is playing. `id` is the player's own identifier for the
 track when it has one (the MPRIS `mpris:trackid`); it is "" otherwise. Only
 the id tells two tracks apart reliably, so a command that refers to a track
 carries it.
*>
struct Track
{
	String id;
	String title;
	String[] artists;
	String album;
	String art_url; // "" when the player offers no art URL
	Maybe{Duration} length;
}

<*
 What the player says it can do right now. A control that is false is refused
 by the service with `error::UNSUPPORTED` before the player is asked. Stop
 has no flag of its own on some platforms; the backend fills it honestly.
*>
struct Controls
{
	bool play;
	bool pause;
	bool play_pause;
	bool stop;
	bool next;
	bool previous;
	bool seek;          // relative seek
	bool set_position;  // absolute seek
	bool set_rate;
	bool set_volume;
	bool set_shuffle;
	bool set_loop;
	bool raise;
	bool quit;
}

<*
 One player. `handle` is assigned by the service while the player exists and
 is what commands name; `id` is the platform's stable identifier (the D-Bus
 bus name, the SMTC source app user model id, the bundle id) and may be reused
 by a later player after this one exits.
*>
struct Player
{
	ulong handle;         // never 0
	String id;
	String identity;      // human name: "Spotify", "VLC media player"
	String desktop_entry; // Linux desktop file name without ".desktop"; "" elsewhere
	Playback status;
	Track track;
	Maybe{Anchor} position;
	PlaybackRate rate;    // 1.0 when the player reports none
	Maybe{Level} volume;
	Maybe{bool} shuffle;
	Maybe{Loop} loop;
	Controls controls;
	bool is_active;       // the player the shell should show (see `policy.c3`)
}

<* The whole picture: every player, sorted by `id`. *>
struct State
{
	Player[] players;
}

<*
 Service-level capabilities. Per-player abilities are in `Controls`; these say
 whether a kind of operation exists on this platform at all.
*>
enum Cap : char
{
	OBSERVE,           // players and their state can be read
	TRANSPORT,         // play, pause, next, previous, stop
	SEEK,              // relative and absolute seeking
	RATE,              // playback speed
	VOLUME,            // player volume
	SHUFFLE,
	LOOP,
	RAISE,             // bring the player's window forward
	QUIT,              // ask the player to exit
	PUBLISH_SESSION,   // make our own session appear to the OS (cut in v1)
	NOW_PLAYING_PRIVATE, // players without a public API (macOS MediaRemote; see README)
}

<* Kinds of command a caller can post. *>
enum CommandKind : char
{
	PLAY,
	PAUSE,
	PLAY_PAUSE,
	STOP,
	NEXT,
	PREVIOUS,
	SEEK,          // relative: `amount` is the offset in microseconds, negative backwards
	SET_POSITION,  // absolute: `amount` is the target in microseconds, `track` the track it refers to
	SET_RATE,      // `rate`
	SET_VOLUME,    // `volume`
	SET_SHUFFLE,   // `flag`
	SET_LOOP,      // `loop`
	RAISE,
	QUIT,
	REFRESH,       // read the players now; not an operation, no `op`
}

<* Longest track id a command can carry, in bytes. Longer ids are refused. *>
const usz TRACK_ID_CAPACITY = 256;

<*
 A request for the worker. Plain data: the track id is copied into the command
 so the caller's string may go away. `op` is the operation the worker completes
 (null for `REFRESH`); the worker holds one reference to it.
*>
struct Command
{
	CommandKind kind;
	ulong player;
	Duration amount;
	PlaybackRate rate;
	Level volume;
	bool flag;
	Loop loop;
	char[TRACK_ID_CAPACITY] track;
	sz track_len;
	Operation{bool}* op;
}

<* The track id a command carries, as text. *>
fn String Command.track_id(&self) => (String)self.track[0:self.track_len];

<*
 What changed between two states. Transients: re-read the state for values.
 `id` is the player's platform id, valid while the event is.
*>
enum EventKind : char
{
	PLAYER_ADDED,
	PLAYER_REMOVED,
	STATUS_CHANGED,
	TRACK_CHANGED,
	SEEKED,         // the player reported a seek; its anchor was refreshed
	ACTIVE_CHANGED, // another player became the active one (or none is)
}

<*
 One change. `player` is the `Player.handle` concerned; for `ACTIVE_CHANGED` it
 is the new active player's handle, or 0 when no player is active.
*>
struct Event
{
	EventKind kind;
	ulong player;
	String id;
}

<* Which mechanism provides the data. *>
enum Backend : char
{
	AUTO,
	MPRIS,     // Linux: org.mpris.MediaPlayer2.* on the D-Bus session bus
	SMTC,      // Windows: GlobalSystemMediaTransportControls sessions
	SCRIPTING, // macOS: AppleScript to Music and Spotify
}

<*
 How `open` finds and tunes a backend.

 `bus_address` is the D-Bus address to use on Linux, "" for the session bus
 named by `DBUS_SESSION_BUS_ADDRESS`. Tests use it to talk to a private bus.
*>
struct Options
{
	Backend backend;
	Duration refresh;   // while a player plays, re-read its position this often; 0 means one second
	String bus_address;
}
