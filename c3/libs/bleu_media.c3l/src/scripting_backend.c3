<*
 The macOS backend: Music and Spotify, through AppleScript.

 Public API only. There is no public way to observe another application's
 now-playing session on macOS, so the two apps that have a scripting dictionary
 are read and driven through Apple events. Each app needs an Automation grant
 from the user (TCC); a refused grant shows the player as absent, with the
 reason left in `error::last()` on the worker.

 Polling, not events: the worker reads both apps once per refresh interval and
 after each command. The read script checks "is running" first, so an app that
 is not running is not launched. Scripts block; they run only on the worker.

 Not done here: shuffle and repeat are not read (the state says unknown); rate
 is not offered; the private MediaRemote route is not implemented (see the
 library README). Not run anywhere: type-checked for the macOS targets only.
*>
module bleu::media::scripting @feat(DARWIN);
import std::collections::maybe, std::math, std::time, bleu::availability, bleu::error, bleu::media, bleu::media::scripting_convert, bleu::objc::applescript, bleu::observe, bleu::operation, bleu::rt::poller, bleu::rt::worker, bleu::service, bleu::unit;

<* Commands taken from the mailbox per pass of the loop. *>
const usz COMMAND_BATCH = 16;

<* Number of scripted apps. A player's handle is its index plus one. *>
const usz APP_COUNT = 2;

<*
 One scripted application. `length_ms` is an AppleScript expression for the
 current track's length in milliseconds (Music gives seconds, Spotify
 milliseconds). Spotify's `shuffling` and `repeating` are booleans; Music's
 `shuffle enabled` is too, but its `song repeat` takes off, one or all.
*>
struct App
{
	String bundle;
	String name;
	String length_ms;
	String shuffle_property;
	bool boolean_repeat;
}

const App[APP_COUNT] APPS = {
	{
		.bundle = "com.apple.Music",
		.name = "Music",
		.length_ms = "round ((duration of current track) * 1000)",
		.shuffle_property = "shuffle enabled",
		.boolean_repeat = false
	},
	{
		.bundle = "com.spotify.client",
		.name = "Spotify",
		.length_ms = "(duration of current track)",
		.shuffle_property = "shuffling",
		.boolean_repeat = true
	},
};

<*
 What the backend keeps of one app between polls: whether it runs, its status
 and since when, and the last position reading with its anchor.
*>
struct AppState
{
	bool running;
	Playback status;
	Duration status_since;
	long position_ms;
	Maybe{Anchor} position;
}

<* The state between polls: one entry per scripted app. *>
struct Scripting
{
	Allocator allocator;
	AppState[APP_COUNT] apps;
}

struct Backend
{
	Allocator allocator;
	Duration refresh;
}

const Driver DRIVER = {
	.info = { "scripting", "Music and Spotify through AppleScript", 5 },
	.id = media::Backend.SCRIPTING,
	.probe = &probe,
	.create = &create,
	.destroy = &destroy,
	.run = &run,
};

// Cheap: AppleScript is part of macOS; a refused grant appears per read.
fn bool probe(Options* options) => true;

// Nothing is run here: `open` may be called on the main thread, and scripts block.
fn void*? create(Allocator allocator, Options options, Capabilities* capabilities)
{
	fill_capabilities(capabilities);
	return alloc::new(allocator, Backend, { .allocator = allocator, .refresh = options.refresh });
}

fn void fill_capabilities(Capabilities* capabilities) @private
{
	capabilities.init(availability::YES);
	capabilities.values[Cap.OBSERVE.ordinal] = availability::no(
		availability::Reason.DEGRADED,
		"Music and Spotify, polled through AppleScript; each needs an Automation grant; no change events"
	);
	capabilities.values[Cap.RATE.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"AppleScript players have no rate control"
	);
	capabilities.values[Cap.PUBLISH_SESSION.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"macOS has no public API to publish a now-playing session"
	);
	capabilities.values[Cap.NOW_PLAYING_PRIVATE.ordinal] = availability::no(
		availability::Reason.UNSUPPORTED_BACKEND,
		"The MediaRemote private API is not implemented in v1; see the library README"
	);
}

fn void destroy(Allocator allocator, void* state)
{
	alloc::free(allocator, state);
}

// What the scripted apps can do. Rate is not among them.
fn Controls scripted_controls() @private
{
	return {
		.play = true,
		.pause = true,
		.play_pause = true,
		.stop = true,
		.next = true,
		.previous = true,
		.seek = true,
		.set_position = true,
		.set_volume = true,
		.set_shuffle = true,
		.set_loop = true,
		.raise = true,
		.quit = true,
	};
}

// The script that reads one app: its line, or an empty line when it is not running.
fn String read_script(App app) @private
{
	return string::tformat(
		"if application id \"%s\" is running then\n"
			"tell application id \"%s\"\n"
			"set st to (player state as text)\n"
			"set ps to (round (player position * 1000)) as text\n"
			"set vo to (sound volume) as text\n"
			"try\n"
			"set ti to name of current track\n"
			"set ar to artist of current track\n"
			"set al to album of current track\n"
			"set dm to (%s) as text\n"
			"on error\n"
			"set ti to \"\"\n"
			"set ar to \"\"\n"
			"set al to \"\"\n"
			"set dm to \"0\"\n"
			"end try\n"
			"return st & tab & ps & tab & vo & tab & dm & tab & ti & tab & ar & tab & al\n"
			"end tell\n"
			"else\n"
			"return \"\"\n"
			"end if",
		app.bundle,
		app.bundle,
		app.length_ms
	);
}

// The script that runs one command on an app: a statement inside its `tell`.
fn String? command_script(App app, Command* c, AppState* state) @private
{
	String statement = "";
	switch (c.kind)
	{
		case CommandKind.PLAY: statement = "play";
		case CommandKind.PAUSE: statement = "pause";
		case CommandKind.PLAY_PAUSE: statement = "playpause";
		case CommandKind.STOP: statement = "stop";
		case CommandKind.NEXT: statement = "next track";
		case CommandKind.PREVIOUS: statement = "previous track";
		case CommandKind.RAISE: statement = "activate";
		case CommandKind.QUIT: statement = "quit";
		case CommandKind.SEEK:

			{
				if (!state.position.has_value) return error::UNAVAILABLE~;
				Maybe{Duration} no_length = { };
				Duration at               = media::position_at(
					state.position.value,
					state.status,
					1.0,
					no_length,
					media::monotonic_now()
				) + c.amount;
				statement = string::tformat("set player position to (%d / 1000)", at / 1000);
			}
		case CommandKind.SET_POSITION:

			{
				statement = string::tformat("set player position to (%d / 1000)", c.amount / 1000);
			}
		case CommandKind.SET_VOLUME:

			{
				int percent = (int)math::round((double)(float)c.volume * 100.0);
				statement = string::tformat("set sound volume to %d", percent);
			}
		case CommandKind.SET_SHUFFLE:

			{
				statement = string::tformat("set %s to %s", app.shuffle_property, c.flag ? "true" : "false");
			}
		case CommandKind.SET_LOOP:

			{
				if (app.boolean_repeat)
				{
					statement = string::tformat("set repeating to %s", c.loop == Loop.NONE ? "false" : "true");
				}
				else
				{
					String mode = c.loop == Loop.TRACK ? "one" : (c.loop == Loop.PLAYLIST ? "all" : "off");
					statement = string::tformat("set song repeat to %s", mode);
				}
			}
		case CommandKind.SET_RATE:
		case CommandKind.REFRESH: return error::UNSUPPORTED~;
	}
	return string::tformat("tell application id \"%s\" to %s", app.bundle, statement);
}

// The player a reading describes, with its strings copied into `allocator`.
fn Player build_player(usz index, Reading* r, AppState* state, Allocator allocator) @private
{
	App app          = APPS[index];
	String[] artists = { };
	if (r.artist.len > 0)
	{
		artists = alloc::new_array(allocator, String, 1);
		artists[0] = r.artist.copy(allocator);
	}
	return {
		.handle = (ulong)index + 1,
		.id = app.bundle.copy(allocator),
		.identity = app.name.copy(allocator),
		.status = r.status,
		.track = {
			.title = media::copy_text(r.title, allocator),
			.artists = artists,
			.album = media::copy_text(r.album, allocator),
			.length = r.length_ms > 0 ? maybe::value((Duration)r.length_ms * 1000) : { },
		},
		.position = state.position,
		.rate = 1.0,
		.volume = maybe::value(unit::from_percent((float)r.volume)),
		.controls = scripted_controls(),
	};
}

<* One pass: read both apps, anchor their positions, and publish the state if it changed. *>
fn void Scripting.poll(&self, MediaHub* hub)
{
	@pool()
	{
		Reading[APP_COUNT] readings;
		bool[APP_COUNT] present;
		usz count = 0;
		for (usz i = 0; i < APP_COUNT; i++)
		{
			present[i] = false;
			if (try line = applescript::run_script(read_script(APPS[i]), tmem))
			{
				if (try reading = scripting_convert::parse_reading(line))
				{
					readings[i] = reading;
					present[i] = true;
					count++;
				}
			}
		}
		Duration now              = media::monotonic_now();
		Snapshot{State}* snapshot = hub.begin();
		Player[] players          = alloc::new_array(snapshot.allocator(), Player, APP_COUNT);
		Playback[] statuses       = alloc::new_array(tmem, Playback, APP_COUNT);
		Duration[] since          = alloc::new_array(tmem, Duration, APP_COUNT);
		sz k                      = 0;
		for (usz i = 0; i < APP_COUNT; i++)
		{
			AppState* state = &self.apps[i];
			if (!present[i])
			{
				state.running = false;
				continue;
			}
			Reading* r = &readings[i];
			bool same  = state.running && state.status == r.status && state.position_ms == r.position_ms;
			if (!state.running || state.status != r.status) state.status_since = now;
			if (!same)
			{
				Anchor anchor = { .position = (Duration)r.position_ms * 1000, .taken_at = now };
				state.position = maybe::value(anchor);
			}
			state.running = true;
			state.status = r.status;
			state.position_ms = r.position_ms;
			players[k] = build_player(i, r, state, snapshot.allocator());
			statuses[k] = r.status;
			since[k] = state.status_since;
			k++;
		}
		Player[] published = players[0:k];
		if (k > 0)
		{
			sz active = media::select_active(statuses[0:k], since[0:k]);
			published[active].is_active = true;
		}
		snapshot.value = { .players = published };
		ulong[] none = { };
		media::publish_built(hub, snapshot, none);
	};
}

<* Carry out `c` and complete its operation, if it has one. *>
fn void Scripting.execute(&self, Command* c)
{
	CommandOp* op = c.op;
	if (catch err = self.perform(c))
	{
		if (op != null)
		{
			op.fail(err);
			op.release();
		}
		return;
	}
	if (op != null)
	{
		op.succeed(true);
		op.release();
	}
}

// Run the command's script on its app, if the app is running and the control is offered.
fn void? Scripting.perform(&self, Command* c)
{
	if (c.kind == CommandKind.REFRESH) return;
	if (c.player == 0 || c.player > APP_COUNT) return NOT_FOUND~;
	usz index       = (usz)c.player - 1;
	AppState* state = &self.apps[index];
	if (!state.running) return NOT_FOUND~;
	if (!scripted_controls().allows(c.kind)) return error::UNSUPPORTED~;
	@pool()
	{
		String script = command_script(APPS[index], c, state)!;
		applescript::run_script(script, tmem)!;
	};
}

<* The worker's loop: wait for a command or the refresh interval; run the commands; poll. *>
fn void run(void* state, MediaHub* hub, Host{Command}* host)
{
	Backend* backend    = (Backend*)state;
	Scripting scripting = { .allocator = backend.allocator };
	Poller poller;
	if (catch err = poller.init(mem, host.wakeup(), 1)) return;
	defer poller.free();
	Command[COMMAND_BATCH] commands;
	scripting.poll(hub);
	while (!host.stopping())
	{
		if (catch err = poller.wait(backend.refresh))
		{
			if (err != TIMEOUT) break;
		}
		usz count = host.mailbox().take_all(commands[..]);
		for (usz i = 0; i < count; i++) scripting.execute(&commands[i]);
		scripting.poll(hub);
	}
}