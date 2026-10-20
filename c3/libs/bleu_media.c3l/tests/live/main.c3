// Live test: the media service against a real dbus-daemon and the python mock
// (../mock_players.py). Run by ../run.sh, which sets DBUS_SESSION_BUS_ADDRESS.
// Each check prints PASS or FAIL; the exit status is the number of failures.
module bleu::media::live_test;
import std::io, std::time, std::os::env, std::collections::maybe, bleu::observe, bleu::availability, bleu::error, bleu::media, bleu::operation, bleu::stream, bleu::unit, bleu::dbus::connection, bleu::dbus::proxy, bleu::dbus::message, bleu::dbus::marshal;

const String ADDRESS_VAR = "DBUS_SESSION_BUS_ADDRESS";
const String CONTROL_NAME = "org.bleu.MediaTest";
const String CONTROL_PATH = "/org/bleu/MediaTest";
const String ID_A = "org.mpris.MediaPlayer2.fake_a";
const String ID_B = "org.mpris.MediaPlayer2.fake_b";
const String ID_C = "org.mpris.MediaPlayer2.fake_c";
const Duration OP_TIMEOUT = (Duration)2_000_000;
const Duration POSITION_TOLERANCE = (Duration)1_500_000;

int failures = 0;

fn void check(bool ok, String what)
{
	if (ok)
	{
		io::printfn("PASS %s", what);
	}
	else
	{
		io::printfn("FAIL %s", what);
		failures++;
	}
}

// What the test expects of one snapshot. Unset fields are not checked.
struct Want
{
	String id;
	bool absent;
	String title;
	bool has_status;
	Playback status;
	bool has_position;
	Duration position;
	bool has_volume;
	Level volume;
	bool has_shuffle;
	bool shuffle;
	bool active;
}

fn Player* find(State* state, String id)
{
	foreach (&p : state.players)
	{
		if (p.id == id) return p;
	}
	return null;
}

// True when `state` satisfies `want`.
fn bool holds(State* state, Want* want)
{
	Player* p = find(state, want.id);
	if (want.absent) return p == null;
	if (p == null) return false;
	if (want.title.len > 0 && p.track.title != want.title) return false;
	if (want.has_status && p.status != want.status) return false;
	if (want.has_position)
	{
		Maybe{Duration} at = p.position_now(media::monotonic_now());
		if (!at.has_value) return false;
		Duration diff = at.value - want.position;
		if (diff < time::DURATION_ZERO) diff = -diff;
		if (diff > POSITION_TOLERANCE) return false;
	}
	if (want.has_volume && (!p.volume.has_value || (float)p.volume.value != (float)want.volume)) return false;
	if (want.has_shuffle && (!p.shuffle.has_value || p.shuffle.value != want.shuffle)) return false;
	if (want.active && !p.is_active) return false;
	return true;
}

// Wait up to about eight seconds for a snapshot that satisfies `want`.
fn bool wait_for(Media* media, Want* want)
{
	ulong seen = 0;
	for (int round = 0; round < 40; round++)
	{
		if (try snapshot = media.wait_after(seen, time::ms(200)))
		{
			seen = snapshot.generation;
			bool ok = holds(&snapshot.value, want);
			snapshot.release();
			if (ok) return true;
		}
	}
	return false;
}

// Wait for an event of `kind` about player `id`, reading the stream for a few seconds.
fn bool saw_event(stream::Reader{Event}* events, EventKind kind, String id)
{
	for (int round = 0; round < 30; round++)
	{
		if (try packet = events.next(time::ms(100)))
		{
			bool hit = packet.value.kind == kind && packet.value.id == id;
			packet.release();
			if (hit) return true;
		}
	}
	return false;
}

// Wait for an operation and release it: true when it succeeded.
fn bool succeeded(CommandOp* op)
{
	defer op.release();
	if (try ok = op.wait(OP_TIMEOUT)) return ok;
	return false;
}

// Wait for an operation and release it: true when it failed with `expected`.
fn bool failed_with(CommandOp* op, fault expected)
{
	defer op.release();
	if (catch err = op.wait(OP_TIMEOUT)) return err == expected;
	return false;
}

// Send `call` to the mock and return the text of its reply (empty when none).
fn String? invoke(Connection* bus, Message* call) @local
{
	Message* reply = bus.call(call)!;
	defer reply.release();
	if (reply.signature.len == 0) return "";
	return reply.reader()!.read_string()!.copy(mem);
}

fn Message*? control_call(Connection* bus, String member) @local
{
	Proxy control = proxy::for_object(bus, CONTROL_NAME, CONTROL_PATH, CONTROL_NAME)!;
	return control.new_call(mem, member);
}

// The mock's Status(name, status).
fn void? ctl_status(Connection* bus, String name, String status)
{
	Message* call = control_call(bus, "Status")!;
	defer call.release();
	Writer* body = call.body_writer("ss")!;
	body.append_string(name)!;
	body.append_string(status)!;
	invoke(bus, call)!;
}

// The mock's Track(name, trackid, title).
fn void? ctl_track(Connection* bus, String name, String trackid, String title)
{
	Message* call = control_call(bus, "Track")!;
	defer call.release();
	Writer* body = call.body_writer("sos")!;
	body.append_string(name)!;
	body.append_object_path(trackid)!;
	body.append_string(title)!;
	invoke(bus, call)!;
}

// The mock's Jump(name, position), which sends Seeked.
fn void? ctl_jump(Connection* bus, String name, long position)
{
	Message* call = control_call(bus, "Jump")!;
	defer call.release();
	Writer* body = call.body_writer("sx")!;
	body.append_string(name)!;
	body.append_i64(position)!;
	invoke(bus, call)!;
}

// The mock's Vanish(name): its bus connection goes away.
fn void? ctl_vanish(Connection* bus, String name)
{
	Message* call = control_call(bus, "Vanish")!;
	defer call.release();
	call.body_writer("s")!.append_string(name)!;
	invoke(bus, call)!;
}

// The mock's Calls(name): what the player received, joined with ";".
fn String? ctl_calls(Connection* bus, String name)
{
	Message* call = control_call(bus, "Calls")!;
	defer call.release();
	call.body_writer("s")!.append_string(name)!;
	return invoke(bus, call);
}

fn void? run_scenario(Media* media, Connection* bus)
{
	Want first = { .id = ID_A, .title = "Alpha", .has_status = true, .status = Playback.PLAYING, .active = true };
	bool first_ok = wait_for(media, &first);
	Snapshot{State}* snap = media.latest()!;
	defer snap.release();
	State* state = &snap.value;
	check(first_ok, "alpha plays and is the active player");
	Maybe{Duration} first_at = find(state, ID_A).position_now(media::monotonic_now());
	check(first_at.has_value && first_at.value >= (Duration)10_000_000, "alpha's position is at least its starting ten seconds");
	check(state.players.len == 3, "three players: a, b, c");
	Player* a = find(state, ID_A);
	Player* b = find(state, ID_B);
	Player* c = find(state, ID_C);
	check(a.identity == "Fake Alpha" && a.desktop_entry == "fake-a", "identity and desktop entry");
	check(a.track.id == "/org/fake/track/1" && a.track.artists.len == 2 && a.track.artists[1] == "Bo", "track id and artists");
	check(a.track.length.has_value && a.track.length.value == (Duration)180_000_000, "track length");
	check(a.track.art_url == "file:///tmp/fake-alpha.png", "art url");
	check(a.controls.next && a.controls.set_position && !b.controls.next, "controls follow CanGoNext and CanSeek");
	check(c.track.id == "", "a player with no track id reports none");
	ulong handle_a = a.handle;
	ulong handle_b = b.handle;
	ulong handle_c = c.handle;
	check(media.capability(Cap.PUBLISH_SESSION).reason == availability::Reason.UNSUPPORTED_BACKEND, "publishing our session is refused");

	stream::Reader{Event}* events = media.subscribe()!;
	defer events.release();

	ctl_track(bus, ID_A, "/org/fake/track/2", "Beta")!;
	Want beta = { .id = ID_A, .title = "Beta", .has_position = true, .position = (Duration)0 };
	check(wait_for(media, &beta), "a new track title arrives");
	check(saw_event(events, EventKind.TRACK_CHANGED, ID_A), "TRACK_CHANGED for a");

	ctl_jump(bus, ID_A, 60_000_000)!;
	Want jumped = { .id = ID_A, .has_position = true, .position = (Duration)60_000_000 };
	check(wait_for(media, &jumped), "Seeked re-anchors the position at sixty seconds");
	check(saw_event(events, EventKind.SEEKED, ID_A), "SEEKED for a");

	ctl_status(bus, ID_A, "Paused")!;
	Want paused = { .id = ID_A, .has_status = true, .status = Playback.PAUSED, .active = true };
	check(wait_for(media, &paused), "a paused, and as the most recent change it is the active player");
	Want held = { .id = ID_A, .has_status = true, .status = Playback.PAUSED, .has_position = true, .position = (Duration)60_000_000 };
	check(wait_for(media, &held), "the paused position stays where it was");

	check(succeeded(media.play(handle_a)!!), "play completes");
	Want playing = { .id = ID_A, .has_status = true, .status = Playback.PLAYING };
	check(wait_for(media, &playing), "a plays again after the command");
	check(saw_event(events, EventKind.STATUS_CHANGED, ID_A), "STATUS_CHANGED for a");

	check(failed_with(media.next(handle_b)!!, error::UNSUPPORTED), "next on b is refused: its CanGoNext is false");

	check(succeeded(media.set_position(handle_a, "/org/fake/track/2", (Duration)90_000_000)!!), "absolute seek completes");
	Want sought = { .id = ID_A, .has_position = true, .position = (Duration)90_000_000 };
	check(wait_for(media, &sought), "the player is at ninety seconds");

	check(failed_with(media.set_position(handle_a, "/org/fake/track/1", (Duration)30_000_000)!!, error::INVALID_STATE), "a stale track id is refused before it is sent");
	String calls = ctl_calls(bus, ID_A)!;
	check(calls.contains("SetPosition /org/fake/track/2 90000000"), "the mock got the SetPosition for the current track");
	check(!calls.contains("SetPosition /org/fake/track/1"), "the stale SetPosition was not sent");
	check(!calls.contains("IGNORED"), "the player never saw a SetPosition it would have ignored");

	check(succeeded(media.set_volume(handle_a, (Level)0.5f)!!), "set volume completes");
	Want quiet = { .id = ID_A, .has_volume = true, .volume = (Level)0.5f };
	check(wait_for(media, &quiet), "volume reads back as one half");

	check(succeeded(media.set_shuffle(handle_b, true)!!), "shuffle completes");
	Want shuffled = { .id = ID_B, .has_shuffle = true, .shuffle = true };
	check(wait_for(media, &shuffled), "shuffle reads back as on");

	// c has no track id, so an absolute target becomes a relative seek from its anchor (20 s, paused).
	check(succeeded(media.set_position(handle_c, "", (Duration)10_000_000)!!), "position on a trackless player completes");
	Want relative = { .id = ID_C, .has_position = true, .position = (Duration)10_000_000 };
	check(wait_for(media, &relative), "the trackless player moved to ten seconds");
	String c_calls = ctl_calls(bus, ID_C)!;
	check(c_calls.contains("Seek -10000000"), "it was done as a relative seek of minus ten seconds");

	ctl_vanish(bus, ID_C)!;
	Want gone = { .id = ID_C, .absent = true };
	check(wait_for(media, &gone), "a player that vanished leaves the state");
	check(saw_event(events, EventKind.PLAYER_REMOVED, ID_C), "PLAYER_REMOVED for c");
}

fn int main()
{
	String address = env::get_var(mem, ADDRESS_VAR) ?? "";
	if (address.len == 0)
	{
		io::printn("FAIL no DBUS_SESSION_BUS_ADDRESS");
		return 1;
	}
	Connection bus;
	bus.init(mem);
	defer bus.free();
	bus.open_address(address)!!;

	Media* media = media::open(mem, { .backend = media::Backend.AUTO })!!;
	defer media.close();
	check(media.backend_name() == "mpris", "the MPRIS backend was chosen");
	if (catch err = run_scenario(media, &bus))
	{
		io::printfn("FAIL scenario stopped: %s (%s)", err, error::last().message());
		failures++;
	}
	if (failures == 0)
	{
		io::printn("LIVE OK");
	}
	else
	{
		io::printfn("LIVE FAILED: %d", failures);
	}
	return failures;
}
