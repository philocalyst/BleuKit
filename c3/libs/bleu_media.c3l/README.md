# bleu_media

Observe and control the media players of other applications: the now-playing
card (what is playing, its track, its position), and transport (play, pause,
seek, next, previous, volume, shuffle, repeat). Module root `bleu::media`.
Depends on `bleu_core`, `bleu_rt`, `bleu_service`, `bleu_dbus` (Linux),
`bleu_win` (Windows), `bleu_objc` (macOS). Spec: `docs/research/media_notify_tray.md`
part (A). Deviations and checks: `docs/research/media_impl.md`.

## Public API

* `media::open(allocator, Options) -> Media*?`: first working backend, or `Options.backend`.
* `Media.close()`, `Media.backend_name()`, `Media.capability(Cap)`.
* `Media.latest()`, `Media.wait_after(seen, timeout)`: the state, retained (`release()`).
* `Media.watch(listener, ctx)` / `unwatch`; `Media.subscribe()` for `Event`s
  (`PLAYER_ADDED`, `PLAYER_REMOVED`, `STATUS_CHANGED`, `TRACK_CHANGED`, `SEEKED`, `ACTIVE_CHANGED`).
* Commands take a player `handle` and return `Operation{bool}*` (complete with
  `true` when the player's reply arrived): `play`, `pause`, `play_pause`, `stop`,
  `next`, `previous`, `seek(offset)`, `set_position(track_id, position)`,
  `set_rate`, `set_volume`, `set_shuffle`, `set_loop`, `raise`, `quit`.
* `Media.refresh()`: read the players now.
* `Player.position_now(now)` extrapolates a position from its anchor (`position.c3`).
  `media::monotonic_now()` is the clock `now` comes from.
* `position_at`, `select_active` (Playing > Paused > Stopped, then most recent), `Controls.allows`.

Caller side, in short:

```c3
Media* media = media::open(mem, { .backend = AUTO })!;
defer media.close();
if (try snapshot = media.latest())
{
	defer snapshot.release();
	foreach (&p : snapshot.value.players)
	{
		if (p.is_active) io::printfn("%s: %s", p.track.title, p.position_now(media::monotonic_now()).value);
	}
}
Operation{bool}* done = media.play(handle)!;
defer done.release();
done.wait(time::sec(2))!;
```

## Coverage

Run = executed on Linux against the mock (`tests/run.sh`, 36 live checks).
Unit = `@test` functions in `src/media_test.c3` (21 tests: pure logic, including the parsers of all three platforms).
Compiled = type-checked with `c3c compile-only` for the platform. Nothing else was run.

| Capability | Linux MPRIS | Windows SMTC | macOS scripting |
| --- | --- | --- | --- |
| Observe players, identity, track, art URL | Run | Compiled | Compiled |
| Position, extrapolation, clamp | Run (live) and Unit | Compiled (anchor from LastUpdatedTime) | Compiled |
| Change events (status, track, seek, removal) | Run | Compiled (polled) | Compiled (polled) |
| `SEEKED` event | Run | Not done (SMTC has no seek event) | Not done |
| Play | Run | Compiled | Compiled |
| Pause | Compiled | Compiled | Compiled |
| PlayPause, Stop, Next, Previous | Compiled | Compiled | Compiled |
| `ACTIVE_CHANGED` event | Compiled | Compiled | Compiled |
| Refusal when a control is absent | Run (`Next` on b) | Compiled | Compiled |
| Absolute seek, stale-track refusal | Run | Compiled (no track id: not checked) | Compiled (no track id) |
| Relative seek | Compiled | Compiled | Compiled |
| Trackless absolute as relative seek | Run | Compiled | Compiled |
| Volume | Run | UNSUPPORTED (no SMTC volume) | Compiled |
| Shuffle | Run | Compiled | Compiled (unknown state) |
| Repeat (loop) | Compiled | Compiled | Compiled (unknown state) |
| Rate | Compiled | Compiled | UNSUPPORTED |
| Raise, Quit | Compiled | UNSUPPORTED | Compiled |
| Vanishing player removed | Run | Compiled | Compiled (not running) |
| Publish our own session | UNSUPPORTED (cut) | UNSUPPORTED (cut) | UNSUPPORTED (no API) |
| MediaRemote (private) observer | UNSUPPORTED_OS | UNSUPPORTED_OS | UNSUPPORTED_BACKEND (not implemented) |

## Not done

* Linux: MPRIS export (publishing our session), `GetArtworkFd` (2.3 art bytes),
  `TrackList`, `Playlists`, `OpenUri`. A bus disconnect ends the worker: `latest()`
  keeps the last state and no reconnect happens (the shell restarts the service).
* Windows: change events (polled every refresh interval instead), volume, raise,
  quit, track ids, thumbnails, `SEEKED`. Not run anywhere.
* macOS: MediaRemote (private) observer and its Perl adapter, rate, shuffle and
  repeat read-back, change events, a scripted player that is not Music or
  Spotify. Automation denial appears as an absent player (`error::last()` holds
  the reason on the worker). Not run anywhere.
* A `SetPosition` on Linux for a player with a track id is checked against the
  track the service last read; a change the service has not read yet is refused
  (`INVALID_STATE`) rather than sent.

## Verified how

* Linux: `tests/run.sh` starts a private `dbus-daemon` on a short socket path,
  `tests/mock_players.py` (dbus-next; three players, one of them vanishes, a control
  interface), and `tests/live/main.c3`. Result: `LIVE OK`, 36 of 36, on three
  consecutive runs against the committed `bleu_dbus`. The unit tests: the 21 media
  tests pass (`c3c compile-test libs/bleu_media.c3l/src/*.c3`, run from a private
  directory; the run reports every test of the dependencies too).
* Windows and macOS: `c3c compile-only` for `windows-x64`, `windows-aarch64`,
  `macos-aarch64`, `macos-x64`; all clean. Vtable slots and enum values checked
  against windows-rs 0.62.2 (`docs/research/media_impl.md`).
