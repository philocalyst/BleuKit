<*
 Backend.MPRIS property values converted to the media model. Pure: no sockets, no
 clocks. The D-Bus values are read by `mpris_session.c3`; this file decides what
 they mean.

 Sources, all Backend.MPRIS 2.2 unless noted (`https://specifications.freedesktop.org/mpris-spec/latest/`):
 * bus name prefix and object path, "Bus Name Policy" and "Entry point";
 * `Metadata` keys, "Metadata_Map" (mpris:trackid, mpris:length, mpris:artUrl, xesam:*);
 * `NoTrack` and "/" as no-track values, `TrackId` of `SetPosition` (the spec text);
 * `PlaybackStatus`, `LoopStatus`, `Rate` (0.0 means paused), `Volume` (0.0 mute, 1.0 nominal);
 * `CanControl` and the `Can*` flags, "Player" page.
*>
module bleu::media::mpris_convert;
import std::collections::maybe, std::time, bleu::dbus::value, bleu::dbus::names, bleu::media, bleu::unit;

<* Prefix of every Backend.MPRIS bus name, including the trailing dot (2.2 "Bus Name Policy"). *>
const String BUS_NAME_PREFIX  = "org.mpris.MediaPlayer2.";
<* Object path of the root and Player interfaces (2.2 "Entry point"). *>
const String OBJECT_PATH      = "/org/mpris/MediaPlayer2";
<* The root interface: Raise, Quit, Identity, DesktopEntry, CanRaise, CanQuit. *>
const String ROOT_INTERFACE   = "org.mpris.MediaPlayer2";
<* The Player interface: transport, position, metadata, volume. *>
const String PLAYER_INTERFACE = "org.mpris.MediaPlayer2.Player";
<* Object path a player uses for "no track" (2.2 `TrackId`). *>
const String NO_TRACK_PATH    = "/org/mpris/MediaPlayer2/TrackList/NoTrack";

<* True for a bus name that an Backend.MPRIS player may own (prefix plus at least one more character). *>
fn bool is_player_name(String name) => name.len > BUS_NAME_PREFIX.len && name.starts_with(BUS_NAME_PREFIX);

<* `PlaybackStatus` text to a status. Anything unknown is treated as stopped. *>
fn Playback playback_of(String status)
{
	if (status == "Playing") return Playback.PLAYING;
	if (status == "Paused") return Playback.PAUSED;
	return Playback.STOPPED;
}

<* `LoopStatus` text to a loop mode. Anything unknown is treated as no repeat. *>
fn Loop loop_of(String status)
{
	if (status == "Track") return Loop.TRACK;
	if (status == "Playlist") return Loop.PLAYLIST;
	return Loop.NONE;
}

<* The `LoopStatus` text for a loop mode. *>
fn String loop_text(Loop loop)
{
	switch (loop)
	{
		case Loop.NONE: return "None";
		case Loop.TRACK: return "Track";
		case Loop.PLAYLIST: return "Playlist";
	}
}

<*
 The track id a player reported, or "" when it has none. "/" and the NoTrack
 path mean no track; so does anything that is not a valid object path.
*>
fn String track_id_of(String path)
{
	if (path == "/" || path == NO_TRACK_PATH || !names::is_object_path(path)) return "";
	return path;
}

<* A length in microseconds as a track length. Zero or negative is unknown. *>
fn Maybe{Duration} length_of(long microseconds)
{
	if (microseconds <= 0) return { };
	return maybe::value((Duration)microseconds);
}

<* A volume as a `Level`. NaN is unknown; above 1.0 is clamped, because `Level` cannot hold it. *>
fn Maybe{Level} volume_of(double volume)
{
	if (volume != volume) return { };
	return maybe::value(unit::level((float)volume));
}

<* A rate as the model stores it. NaN becomes normal speed. Zero is kept; `Player.position_now` treats it as paused. *>
fn PlaybackRate rate_of(double rate)
{
	if (rate != rate) return (PlaybackRate)1.0;
	return (PlaybackRate)rate;
}

<*
 The status to show. A player that says "Playing" at rate 0.0 is not moving,
 so it is paused (Backend.MPRIS 2.2, `Rate`: the player should act as if Pause was called).
*>
fn Playback effective_status(Playback reported, PlaybackRate rate)
{
	if (reported == Playback.PLAYING && (double)rate == 0.0) return Playback.PAUSED;
	return reported;
}

<*
 What a player can do, from its `CanControl` and `Can*` answers. Without
 `CanControl` every method and setter is refused by the player (2.2
 `CanControl`), so all of them are false. Stop has no flag in Backend.MPRIS; it is
 offered whenever the player is controllable. Raise and quit come from the root
 interface.

 @param player : "Properties of the Player interface"
 @param root : "Properties of the root interface"
*>
fn Controls controls_of(Value player, Value root)
{
	bool control   = flag_of(player, "CanControl");
	bool can_play  = control && flag_of(player, "CanPlay");
	bool can_pause = control && flag_of(player, "CanPause");
	bool can_seek  = control && flag_of(player, "CanSeek");
	return {
		.play = can_play,
		.pause = can_pause,
		.play_pause = control && (flag_of(player, "CanPlay") || flag_of(player, "CanPause")),
		.stop = control,
		.next = control && flag_of(player, "CanGoNext"),
		.previous = control && flag_of(player, "CanGoPrevious"),
		.seek = can_seek,
		.set_position = can_seek,
		.set_rate = control,
		.set_volume = control,
		.set_shuffle = control,
		.set_loop = control,
		.raise = flag_of(root, "CanRaise"),
		.quit = flag_of(root, "CanQuit"),
	};
}

<*
 The track in an `a{sv}` of metadata. The strings are copied into `allocator`;
 `metadata` itself may be freed afterwards.
*>
fn Track track_of(Value metadata, Allocator allocator)
{
	Track track = {
		.id = media::copy_text(track_id_of(object_path_of(metadata, "mpris:trackid")), allocator),
		.title = media::copy_text(text_of(metadata, "xesam:title"), allocator),
		.album = media::copy_text(text_of(metadata, "xesam:album"), allocator),
		.art_url = media::copy_text(text_of(metadata, "mpris:artUrl"), allocator),
		.artists = artists_of(metadata, "xesam:artist", allocator),
		.length = length_of(int_of(metadata, "mpris:length")),
	};
	return track;
}

<* A copy of `track` whose strings live in `allocator`. *>
fn Track copy_track(Track* track, Allocator allocator)
{
	String[] artists = { };
	if (track.artists.len > 0)
	{
		artists = alloc::new_array(allocator, String, track.artists.len);
		foreach (i, artist : track.artists) artists[i] = media::copy_text(artist, allocator);
	}
	return {
		.id = media::copy_text(track.id, allocator),
		.title = media::copy_text(track.title, allocator),
		.artists = artists,
		.album = media::copy_text(track.album, allocator),
		.art_url = media::copy_text(track.art_url, allocator),
		.length = track.length,
	};
}

<* The string under `key` in an `a{sv}`, or "" when absent or not a string. The text is only valid while `dict` is. *>
fn String text_of(Value dict, String key)
{
	if (try v = dict.dict_get(key))
	{
		if (try s = v.as_string()) return s;
	}
	return "";
}

<* The object path under `key`, or "" when absent or not an object path. *>
fn String object_path_of(Value dict, String key)
{
	if (try v = dict.dict_get(key))
	{
		if (try p = v.as_object_path()) return p;
	}
	return "";
}

<* The integer under `key` as a 64-bit signed value (`x` or `t`), or 0 when absent. *>
fn long int_of(Value dict, String key)
{
	if (try v = dict.dict_get(key))
	{
		if (try n = v.as_i64()) return n;
		if (try n = v.as_u64()) return n <= (ulong)long::max ? (long)n : long::max;
	}
	return 0;
}

<* The double under `key`, or NaN when absent (so that `volume_of` reports unknown). *>
fn double double_of(Value dict, String key)
{
	if (try v = dict.dict_get(key))
	{
		if (try d = v.as_f64()) return d;
	}
	return bitcast((ulong)0x7FF8000000000000, double);
}

<* The boolean under `key`, or false when absent. *>
fn bool flag_of(Value dict, String key)
{
	if (try v = dict.dict_get(key))
	{
		if (try b = v.as_bool()) return b;
	}
	return false;
}

<* The `as` under `key` as strings copied into `allocator`. Entries that are not strings are dropped. *>
fn String[] artists_of(Value dict, String key, Allocator allocator)
{
	if (try list = dict.dict_get(key))
	{
		usz count = list.count();
		if (count == 0) return { };
		String[] artists = alloc::new_array(allocator, String, (sz)count);
		usz kept         = 0;
		for (usz i = 0; i < count; i++)
		{
			if (try item = list.at(i))
			{
				if (try text = item.as_string())
				{
					artists[kept++] = text.copy(allocator);
				}
			}
		}
		return artists[0:(sz)kept];
	}
	return { };
}