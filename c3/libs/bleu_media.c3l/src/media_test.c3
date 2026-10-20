module bleu::media;
import std::collections::list, std::collections::maybe, std::thread, std::time, bleu::dbus::value, bleu::error, bleu::media::mpris_convert, bleu::media::smtc_convert, bleu::media::scripting_convert, bleu::operation, bleu::rt::worker, bleu::service, bleu::unit;

<* Seconds as a Duration, for test arithmetic. *>
fn Duration secs(long n) => (Duration)(n * 1_000_000);

fn void extrapolates_while_playing() @test
{
	Anchor a             = { .position = secs(10), .taken_at = secs(100) };
	Maybe{Duration} none = { };
	assert(position_at(a, PLAYING, 1.0, none, secs(102)) == secs(12), "two seconds at rate 1");
	assert(position_at(a, PLAYING, 2.0, none, secs(102)) == secs(14), "rate 2 doubles the elapsed time");
	assert(position_at(a, PLAYING, -1.0, none, secs(102)) == secs(8), "negative rate rewinds");
}

fn void holds_while_paused_and_stopped() @test
{
	Anchor a             = { .position = secs(10), .taken_at = secs(100) };
	Maybe{Duration} none = { };
	assert(position_at(a, PAUSED, 1.0, none, secs(500)) == secs(10), "paused stays at the anchor");
	assert(position_at(a, PLAYING, 0.0, none, secs(500)) == secs(10), "rate 0 is paused");
	assert(position_at(a, STOPPED, 1.0, none, secs(500)) == time::DURATION_ZERO, "stopped is at zero");
}

fn void clamps_to_track_bounds() @test
{
	Anchor a               = { .position = secs(58), .taken_at = secs(100) };
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

fn Maybe{Duration} none_length() @local => { };

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
	Playback[] none_s = { };
	Duration[] none_t = { };
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
	State after  = { .players = after_players[..] };
	List{Event} out;
	out.init(mem);
	defer out.free();
	ulong[1] seeks = { 1 };
	collect_events(&before, &after, seeks[..], &out);
	usz status  = 0;
	usz track   = 0;
	usz seeked  = 0;
	usz added   = 0;
	usz removed = 0;
	usz active  = 0;
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
	State s           = { .players = players[..] };
	List{Event} out;
	out.init(mem);
	defer out.free();
	ulong[] no_seeks = { };
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
		Allocator a   = tmem;
		Value artists = value::array(a, "s", { value::str(a, "Ann")!!, value::str(a, "Bo")!! })!!;
		Value meta = value::array(
			a,
			"{sv}",
			{
				value::dict_entry(a, value::str(a, "mpris:trackid")!!, value::variant(a, value::path(a, "/t/9")!!))!!,
				value::dict_entry(a, value::str(a, "xesam:title")!!, value::variant(a, value::str(a, "Song")!!))!!,
				value::dict_entry(a, value::str(a, "xesam:artist")!!, value::variant(a, artists))!!,
				value::dict_entry(a, value::str(a, "mpris:length")!!, value::variant(a, value::i64(3_000_000)))!!,
			}
		)!!;
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

fn void smtc_status_and_repeat_values() @test
{
	assert(smtc_convert::playback_of_status(4) == Playback.PLAYING, "Playing is 4");
	assert(smtc_convert::playback_of_status(5) == Playback.PAUSED, "Paused is 5");
	assert(smtc_convert::playback_of_status(0) == Playback.STOPPED, "Closed is stopped");
	assert(smtc_convert::loop_of_repeat(2) == Loop.PLAYLIST, "List is a playlist loop");
	assert(smtc_convert::repeat_of_loop(Loop.TRACK) == 1, "track loop is 1");
}

fn void smtc_ticks_and_age() @test
{
	assert(smtc_convert::micros_of_ticks(25_000_000) == secs(2) + 500_000, "100 ns ticks to microseconds");
	assert(smtc_convert::ticks_of_micros(secs(3)) == 30_000_000, "and back");
	long stamped = (smtc_convert::UNIX_EPOCH_IN_MICRO_FROM_1601 + 5_000_000) * 10;
	assert(smtc_convert::age_of(stamped, (Time)12_000_000) == secs(7), "age is now minus the stamp");
	assert(smtc_convert::age_of(stamped, (Time)4_000_000) == time::DURATION_ZERO, "a future stamp is no age");
}

fn void smtc_controls_follow_what_is_reported() @test
{
	ReportedControls r = { .toggle = true, .position = true };
	Controls c         = smtc_convert::controls_of(r);
	assert(c.play_pause && c.seek && c.set_position && !c.next && !c.raise && !c.quit, "toggle gives play-pause");
	assert(!c.set_volume, "SMTC has no volume");
}

fn void scripting_reading_lines() @test
{
	Reading r = scripting_convert::parse_reading("playing\t12345\t70\t180000\tSong\tAnn\tAlbum")!!;
	assert(r.status == Playback.PLAYING && r.position_ms == 12345 && r.volume == 70, "state, position, volume");
	assert(r.length_ms == 180000 && r.title == "Song" && r.artist == "Ann" && r.album == "Album", "length and text");
	Reading p = scripting_convert::parse_reading("paused\t0\t100\t0\t\t\t")!!;
	assert(p.status == Playback.PAUSED && p.title == "", "a paused player with no track text");
}

fn void scripting_rejects_malformed_lines() @test
{
	if (catch err = scripting_convert::parse_reading("playing\t1\t2"))
	{
		assert(err == error::PROTOCOL, "too few fields");
	}
	else
	{
		assert(false, "too few fields must fail");
	}
	if (catch err = scripting_convert::parse_reading("playing\tx\t2\t3\ta\tb\tc"))
	{
		assert(err == error::PROTOCOL, "a non-number");
	}
	else
	{
		assert(false, "a non-number must fail");
	}
	if (catch err = scripting_convert::parse_reading(""))
	{
		assert(err == error::PROTOCOL, "an empty line is no reading");
	}
	else
	{
		assert(false, "an empty line must fail");
	}
}
// Regression (M-01): a command still queued when the worker stops fails with DISCONNECTED; before, nothing completed it.
fn void a_command_left_queued_at_stop_fails() @test
{
	MediaHub hub;
	hub.start(mem, "media-test", "test", &wait_until_stopped, null, service::DEFAULT_QUEUE{State, Command, Event}, &abandon_command)!!;
	CommandOp* op = operation::begin(mem);
	Command c     = command(PLAY, 1);
	c.op = op.retain();
	hub.post(c)!!;
	hub.stop();
	if (catch err = op.wait(time::sec(2)))
	{
		assert(err == error::DISCONNECTED, "the abandoned command fails with DISCONNECTED");
	}
	else
	{
		assert(false, "the abandoned command must complete");
	}
	op.release();
	hub.free();
}

// The worker of the test above: runs until stopped, and never takes a command.
fn void wait_until_stopped(void* backend, MediaHub* hub, Host{Command}* host) @private
{
	while (!host.stopping()) thread::sleep(time::ms(1))!!;
}

// Regression (M-02): a reading that agrees with the anchor keeps it, so an unchanged player does not republish.
fn void a_steady_reading_keeps_the_anchor() @test
{
	Maybe{Duration} none = { };
	Anchor known         = { .position = secs(10), .taken_at = secs(100) };
	Maybe{Anchor} current = maybe::value(known);
	Anchor same           = { .position = secs(12), .taken_at = secs(102) };
	assert(!needs_reanchor(current, same, PLAYING, 1.0, none), "a reading that agrees changes nothing");
	Anchor jumped = { .position = secs(20), .taken_at = secs(102) };
	assert(needs_reanchor(current, jumped, PLAYING, 1.0, none), "a reading that disagrees replaces the anchor");
	Maybe{Anchor} no_anchor = { };
	assert(needs_reanchor(no_anchor, same, PLAYING, 1.0, none), "without an anchor, take the reading");
}

// Regression (M-03): a title with a tab is kept whole; the artist and album are the last two fields.
fn void a_title_with_tabs_is_kept_whole() @test
{
	Reading r = scripting_convert::parse_reading("playing\t12345\t70\t180000\tPart one\tPart two\tAnn\tAlbum")!!;
	assert(r.title == "Part one\tPart two", "the title keeps its tab");
	assert(r.artist == "Ann" && r.album == "Album", "artist and album are the last two fields");
}

// Regression (M-04): a zero LastUpdatedTime (1601) is unknown, not 424 years old.
fn void an_unset_stamp_is_no_age() @test
{
	assert(smtc_convert::age_of(0, (Time)12_000_000) == time::DURATION_ZERO, "a zero stamp counts as no age");
	assert(smtc_convert::age_of(0, (Time)12_000_000) < smtc_convert::MAX_STAMP_AGE, "and the position stays bounded");
}

// Regression (M-05): a peer's rate is made safe: NaN is normal speed, a huge rate is clamped to MAX_RATE.
fn void a_peer_rate_is_made_safe() @test
{
	Anchor a               = { .position = secs(10), .taken_at = secs(100) };
	Maybe{Duration} none   = { };
	PlaybackRate huge      = (PlaybackRate)1.0e15;
	PlaybackRate nan       = bitcast((ulong)0x7FF8000000000000, double);
	PlaybackRate infinity  = bitcast((ulong)0x7FF0000000000000, double);
	assert(position_at(a, PLAYING, huge, none, secs(102)) == secs(42), "clamped to MAX_RATE: 10 + 2 * 16");
	assert(position_at(a, PLAYING, nan, none, secs(102)) == secs(12), "NaN is normal speed");
	assert(sane_rate(infinity) == 1.0, "an infinity is normal speed");
	assert(position_at(a, PLAYING, (PlaybackRate)-huge, none, secs(102)) == time::DURATION_ZERO, "a huge rewind stops at zero");
}

// Regression (L-04): only https and file art URLs are kept.
fn void only_https_and_file_art_urls_are_kept() @test
{
	@pool()
	{
		assert(mpris_convert::art_url_text("https://e.org/a.png", tmem) == "https://e.org/a.png");
		assert(mpris_convert::art_url_text("file:///tmp/a.png", tmem) == "file:///tmp/a.png");
		assert(mpris_convert::art_url_text("http://e.org/a.png", tmem) == "", "http is dropped");
		assert(mpris_convert::art_url_text("javascript:alert(1)", tmem) == "", "any other scheme is dropped");
	};
}

// Peer text is cut to MAX_TEXT_BYTES on a character boundary.
fn void long_peer_text_is_cut() @test
{
	@pool()
	{
		char[] long_text = alloc::new_array(tmem, char, 5000);
		for (sz k = 0; k < long_text.len; k++) long_text[k] = 'a';
		assert(cut_utf8((String)long_text, MAX_TEXT_BYTES).len == MAX_TEXT_BYTES);
	};
}
