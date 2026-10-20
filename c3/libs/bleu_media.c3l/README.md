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
  (`PLAYER_ADDED`, `PLAYER_REMOVED`, `STATUS_CHANGED`, `TRACK_CHANGED`, `SEEKED`,
  `ACTIVE_CHANGED`, `BACKEND_FAILED`: the backend cannot read the players; `id` says why).
* Commands take a player `handle` and return `Operation{bool}*` (complete with
  `true` when the player's reply arrived): `play`, `pause`, `play_pause`, `stop`,
  `next`, `previous`, `seek(offset)`, `set_position(track_id, position)`,
  `set_rate` (refused with INVALID_ARGUMENT when not finite or beyond `MAX_RATE`),
  `set_volume` (clamped to [0, 1]), `set_shuffle`, `set_loop`, `raise`, `quit`.
  A command still queued when the service closes completes with DISCONNECTED.
* `Media.refresh()`: read the players now.
* `Player.position_now(now)` extrapolates a position from its anchor (`position.c3`).
  `media::monotonic_now()` is the clock `now` comes from.
* `position_at`, `sane_rate`, `select_active` (Playing > Paused > Stopped, then most recent), `Controls.allows`.

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

Run = executed on Linux against the mock (`tests/run.sh`, 37 live checks).
Unit = `@test` functions in `src/media_test.c3` (28 tests: pure logic, including the parsers of all three platforms, and the abandon hook).
Compiled = type-checked with `c3c compile-only` for the platform. Nothing else was run.

| Capability | Linux MPRIS | Windows SMTC | macOS scripting |
| --- | --- | --- | --- |
| Observe players, identity, track, art URL (https or file only) | Run | Compiled | Compiled |
| Position, extrapolation, clamp | Run (live) and Unit | Compiled (anchor from LastUpdatedTime; a zero stamp counts as no age) | Compiled |
| Change events (status, track, seek, removal) | Run | Compiled (polled) | Compiled (polled) |
| Publishes only on change (a steady player publishes nothing) | Run (live) | Compiled (polled) | Compiled (polled) |
| `SEEKED` event | Run | Not done (SMTC has no seek event) | Not done |
| Play | Run | Compiled | Compiled |
| Pause | Compiled | Compiled | Compiled |
| PlayPause, Stop, Next, Previous | Compiled | Compiled | Compiled |
| `ACTIVE_CHANGED` event | Compiled | Compiled | Compiled |
| `BACKEND_FAILED` event | Not done (the bus is lost, not reported) | Compiled (COM, open, and three failed polls) | Not done |
| Refusal when a control is absent | Run (`Next` on b) | Compiled | Compiled |
| Absolute seek, stale-track refusal | Run | Compiled (no track id: not checked) | Compiled (no track id) |
| Relative seek | Compiled | Compiled (refused without an anchor) | Compiled |
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
* Linux, `SetPosition` on a player with no track id: it is sent as a relative seek from the
  last anchor, and the track is not compared with the one the caller saw (the API carries only
  the track id, so a title or length check needs an API change). A track that changes between
  the read and the command takes the seek.
* Windows: change events (polled every refresh interval instead), volume, raise,
  quit, track ids, thumbnails, `SEEKED`. The session manager is probed by the worker,
  not by `open`: an absent one shows as `BACKEND_FAILED`. Not run anywhere.
* macOS: MediaRemote (private) observer and its Perl adapter, rate, shuffle and
  repeat read-back, change events, a scripted player that is not Music or
  Spotify. Automation denial appears as an absent player (`error::last()` holds
  the reason on the worker). Not run anywhere.
* macOS scripting: each poll reads both apps synchronously on the worker. A hung or
  permission-prompting app delays the other app and the commands for the Apple event
  timeout. Needs a timeout in `bleu_objc` or a reader thread per app (not done).
* The scripted players have no track check on a seek. Titles and artists that contain
  tabs are kept whole (the text fields are last); a tab in an artist or album is split as
  if it were a field separator, and the reading is still kept.

## Verified how

* Linux: `tests/run.sh` starts a private `dbus-daemon` on a short socket path,
  `tests/mock_players.py` (dbus-next; three players, one of them vanishes, a control
  interface), and `tests/live/main.c3`. Result: `LIVE OK`, 37 of 37, including the check
  that a steady playing player publishes nothing for two seconds (that check fails on the
  pre-fix library). The unit tests: the 28 media tests pass
  (`c3c compile-test libs/bleu_media.c3l/src/*.c3`, run from a private directory; the run
  reports every test of the dependencies too).
* Abandon on stop: the unit test runs a hub with a worker that never takes commands, posts one
  and stops; the command completes with DISCONNECTED. `Media.open` passes the same hook; that
  wiring is not covered by a test (it needs a backend).
* Windows and macOS: `c3c compile-only` for `windows-x64`, `windows-aarch64`,
  `macos-aarch64`, `macos-x64`; all clean. Vtable slots and enum values checked
  against windows-rs 0.62.2 (`docs/research/media_impl.md`).
