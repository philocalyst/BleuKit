module bleu::media;
import std::collections::list, std::collections::maybe, std::time, bleu::dbus::value, bleu::media::mpris_convert, bleu::unit;

<* Seconds as a Duration, for test arithmetic. *>
fn Duration secs(long n) => (Duration)(n * 1_000_000);

fn void extrapolates_while_playing() @test
{
	Anchor a = { .position = secs(10), .taken_at = secs(100) };
	Maybe{Duration} none = {};
	assert(position_at(a, PLAYING, 1.0, none, secs(102)) == secs(12), "two seconds at rate 1");
	assert(position_at(a, PLAYING, 2.0, none, secs(102)) == secs(14), "rate 2 doubles the elapsed time");
	assert(position_at(a, PLAYING, -1.0, none, secs(102)) == secs(8), "negative rate rewinds");
}

fn void holds_while_paused_and_stopped() @test
{
	Anchor a = { .position = secs(10), .taken_at = secs(100) };
	Maybe{Duration} none = {};
	assert(position_at(a, PAUSED, 1.0, none, secs(500)) == secs(10), "paused stays at the anchor");
	assert(position_at(a, PLAYING, 0.0, none, secs(500)) == secs(10), "rate 0 is paused");
	assert(position_at(a, STOPPED, 1.0, none, secs(500)) == time::DURATION_ZERO, "stopped is at zero");
}

fn void clamps_to_track_bounds() @test
{
	Anchor a = { .position = secs(58), .taken_at = secs(100) };
	Maybe{Duration} length = maybe::value(secs(60));
	assert(position_at(a, PLAYING, 1.0, length, secs(110)) == secs(60), "never past the end");
	Anchor before = { .position = secs(1), .taken_at = secs(100) };
	assert(position_at(before, PLAYING, -1.0, none_length(), secs(110)) == time::DURATION_ZERO, "never before zero");
}

fn void a_clock_that_went_backwards_counts_no_time() @test
{
	Anchor a = { .position = secs(10), .taken_at = secs(100) };
	assert(position_at(a, PLAYING, 1.0, none_length(), secs(90)) == secs(10), "now before the anchor adds nothing");
}

fn Maybe{Duration} none_length() @local => {};

fn void player_without_position_reports_none() @test
{
	Player p = { .handle = 1, .status = PLAYING, .rate = 1.0 };
	assert(!p.position_now(secs(5)).has_value, "no anchor, no position");
	Anchor known = { .position = secs(3), .taken_at = secs(4) };
	p.position = maybe::value(known);
	assert(p.position_now(secs(6)).value == secs(5), "player extrapolates from its anchor");
}

fn void active_prefers_playing_then_paused_then_stopped() @test
{
	Playback[3] s = { STOPPED, PAUSED, PLAYING };
	Duration[3] t = { secs(9), secs(5), secs(1) };
	assert(select_active(s[..], t[..]) == 2, "a playing player beats a more recent paused one");
	Playback[2] s2 = { STOPPED, PAUSED };
	Duration[2] t2 = { secs(9), secs(1) };
	assert(select_active(s2[..], t2[..]) == 1, "paused beats stopped");
}

fn void active_prefers_the_most_recent_among_equals() @test
{
	Playback[3] s = { PLAYING, PLAYING, PAUSED };
	Duration[3] t = { secs(4), secs(8), secs(9) };
	assert(select_active(s[..], t[..]) == 1, "the playing one that changed last");
	Playback[] none_s = {};
	Duration[] none_t = {};
	assert(select_active(none_s, none_t) == -1, "no players, no active player");
}

fn void controls_refuse_what_the_player_does_not_allow() @test
{
	Controls c = { .play = true, .next = false };
	assert(c.allows(PLAY), "play is allowed");
	assert(!c.allows(NEXT), "next is refused");
	assert(!c.allows(SET_POSITION), "absent flags refuse");
	assert(c.allows(REFRESH), "refresh needs no control");
}

fn void capability_of_each_command() @test
{
	assert(cap_of(PLAY) == TRANSPORT && cap_of(SET_POSITION) == SEEK, "transport and seek");
	assert(cap_of(SET_LOOP) == LOOP && cap_of(QUIT) == QUIT, "loop and quit");
}

fn void events_for_added_changed_and_removed_players() @test
{
	Player[2] before_players = {
		{ .handle = 1, .id = "a", .status = PAUSED, .track = { .id = "/t/1" }, .is_active = true },
		{ .handle = 2, .id = "b", .status = STOPPED },
	};
	Player[2] after_players = {
		{ .handle = 1, .id = "a", .status = PLAYING, .track = { .id = "/t/2" } },
		{ .handle = 3, .id = "c", .status = PLAYING, .is_active = true },
	};
	State before = { .players = before_players[..] };
	State after = { .players = after_players[..] };
	List{Event} out;
	out.init(mem);
	defer out.free();
	ulong[1] seeks = { 1 };
	collect_events(&before, &after, seeks[..], &out);
	usz status = 0;
	usz track = 0;
	usz seeked = 0;
	usz added = 0;
	usz removed = 0;
	usz active = 0;
	foreach (e : out.array_view())
	{
		switch (e.kind)
		{
			case STATUS_CHANGED: status++;
			case TRACK_CHANGED: track++;
			case SEEKED: seeked++;
			case PLAYER_ADDED: added++;
			case PLAYER_REMOVED: removed++;
			case ACTIVE_CHANGED: active++;
			default: break;
		}
	}
	assert(status == 1 && track == 1 && seeked == 1, "status, track and seek of player 1");
	assert(added == 1 && removed == 1 && active == 1, "player 3 added, 2 removed, active changed");
}

fn void unchanged_state_emits_nothing() @test
{
	Player[1] players = { { .handle = 1, .id = "a", .status = PLAYING, .is_active = true } };
	State s = { .players = players[..] };
	List{Event} out;
	out.init(mem);
	defer out.free();
	ulong[] no_seeks = {};
	collect_events(&s, &s, no_seeks, &out);
	assert(out.size == 0, "no change, no events");
}

fn void maps_playback_and_loop_text() @test
{
	assert(mpris_convert::playback_of("Playing") == PLAYING, "Playing");
	assert(mpris_convert::playback_of("Paused") == PAUSED, "Paused");
	assert(mpris_convert::playback_of("nonsense") == STOPPED, "unknown is stopped");
	assert(mpris_convert::loop_of("Playlist") == PLAYLIST, "Playlist");
	assert(mpris_convert::loop_text(TRACK) == "Track", "Track text");
}

fn void track_id_rejects_the_no_track_values() @test
{
	assert(mpris_convert::track_id_of("/") == "", "a bare slash is no track (research: souvlaki defect)");
	assert(mpris_convert::track_id_of(mpris_convert::NO_TRACK_PATH) == "", "NoTrack is no track");
	assert(mpris_convert::track_id_of("not a path") == "", "not an object path");
	assert(mpris_convert::track_id_of("/org/x/track/7") == "/org/x/track/7", "a real id is kept");
}

fn void length_and_volume_conversions() @test
{
	assert(!mpris_convert::length_of(0).has_value, "zero length is unknown");
	assert(mpris_convert::length_of(2_500_000).value == secs(2) + 500_000, "microseconds");
	assert(mpris_convert::volume_of(1.5).value == (Level)1.0f, "above nominal clamps to 1");
	assert(!mpris_convert::volume_of(bitcast((ulong)0x7FF8000000000000, double)).has_value, "NaN is unknown");
}

fn void zero_rate_while_playing_reads_as_paused() @test
{
	assert(mpris_convert::effective_status(PLAYING, (PlaybackRate)0.0) == PAUSED, "rate 0 is paused");
	assert(mpris_convert::effective_status(PLAYING, (PlaybackRate)1.0) == PLAYING, "rate 1 plays");
}

fn void track_from_metadata() @test
{
	@pool()
	{
		Allocator a = tmem;
		Value artists = value::array(a, "s", { value::str(a, "Ann")!!, value::str(a, "Bo")!! })!!;
		Value meta = value::array(a, "{sv}", {
			value::dict_entry(a, value::str(a, "mpris:trackid")!!, value::variant(a, value::path(a, "/t/9")!!))!!,
			value::dict_entry(a, value::str(a, "xesam:title")!!, value::variant(a, value::str(a, "Song")!!))!!,
			value::dict_entry(a, value::str(a, "xesam:artist")!!, value::variant(a, artists))!!,
			value::dict_entry(a, value::str(a, "mpris:length")!!, value::variant(a, value::i64(3_000_000)))!!,
		})!!;
		DynamicArenaAllocator arena;
		arena.init(mem, 1024);
		defer arena.free();
		Track t = mpris_convert::track_of(meta, &arena);
		assert(t.id == "/t/9" && t.title == "Song", "id and title");
		assert(t.artists.len == 2 && t.artists[1] == "Bo", "artist list");
		assert(t.length.value == secs(3), "length");
		assert(t.album == "" && t.art_url == "", "absent text is empty");
	};
}
