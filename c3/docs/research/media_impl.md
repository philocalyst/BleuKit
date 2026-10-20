# media: implementation notes

Implements `docs/research/media_notify_tray.md` part (A), the v1 cut (section 6).
Library: `libs/bleu_media.c3l` (README there has the API, the coverage matrix and
the not-done list). This file records what differs from the research, and what
was checked against which source.

## Deviations from the research

* **Model.** `PlaybackRate` is an `alias` of `double` (a `typedef` made every
  literal need a cast). `Volume` is a `Level`, so a player reporting more than
  1.0 is clamped to 1.0; `Level` cannot hold it, and the spec asks for `Level`.
  `shuffle` and `loop` are `Maybe` (unknown on macOS). Players carry a
  service-assigned `handle` (never 0) that commands name; the platform id
  (`id`) can be reused by a later player, so commands do not use it.
* **Commands carry a track id.** `set_position(player, track_id, position)` copies
  the id into the command (at most `TRACK_ID_CAPACITY` = 256 bytes; longer is
  `INVALID_ARGUMENT`). The research's `SetPosition` check is done by the service:
  when the track has changed, the command is refused with `INVALID_STATE` before
  the player is asked. The player is also asked to ignore a stale id (MPRIS 2.2),
  but the service does not rely on that.
* **Linux trackless SetPosition.** A player without `mpris:trackid` (or with "/")
  gets its absolute target sent as a relative `Seek` from the last anchor, as the
  research's Quickshell note suggests.
* **Options.** `bus_address` is added (tests use a private bus; "" is the session
  bus). Not in the research draft.
* **Cap.** The research's `Cap` list is replaced by service-level capabilities
  (`OBSERVE`, `TRANSPORT`, `SEEK`, `RATE`, `VOLUME`, `SHUFFLE`, `LOOP`, `RAISE`,
  `QUIT`, `PUBLISH_SESSION`, `NOW_PLAYING_PRIVATE`). Per-player abilities are the
  `Controls` struct, filled from each player's own answers.
* **Windows is polled.** The research subscribes to SMTC change events. Those need
  COM delegates implemented in C3; v1 polls every refresh interval (one second)
  and after each command. Seeks appear as position changes, not `SEEKED`.
* **macOS is scripting-only.** Music and Spotify, through `bleu::objc::applescript`.
  The MediaRemote route is not implemented: `NOW_PLAYING_PRIVATE` is
  `UNSUPPORTED_BACKEND`. Reason: the only working route on macOS 15.4 and later
  (the research's section 2.2) is a Perl adapter that loads a framework built
  from ungive's source, which means running a foreign binary we have not built or
  reviewed. The in-process route returns nothing for ordinary bundles on 15.4+
  (single source: the adapter README). A `*_private.c3` file would be unrunnable
  here, so none was written.
* **Position anchors.** Linux: each read anchors (`taken_at` after the reply),
  re-anchored once per refresh interval while playing. Windows: the anchor's
  monotonic time is the reading time minus the age of `LastUpdatedTime`; the
  anchor is kept while the reported pair is unchanged. This conversion is the
  research's `(UNVERIFIED)` item; it is not checked on a machine.
* **Clamping.** `position_at` clamps to `[0, length]`; the research's Quickshell
  and `mpris` crate do not (the research records this as a deliberate deviation).

## Bugs of reference code avoided

* souvlaki `mpris:trackid` = "/" (research 2.1): "/" is read as "no track", and
  it is never sent as an id.
* souvlaki ignores `TrackId` in `SetPosition`: the service checks the id first.
* souvlaki never emits `Seeked`: the service subscribes and re-anchors on it, and
  the test checks that a `SEEKED` event arrives.

## Verified

Linux (run): `tests/run.sh`, 36 of 36 checks, three consecutive runs, against the
committed `bleu_dbus`. A player's track id, artists, length, art URL, controls,
volume, shuffle, `Seeked`, vanishing, a refused stale id and a trackless
absolute seek were all observed through the service, not assumed.

Windows and macOS (compile-only, `c3c compile-only`, all four targets for
macOS and both for Windows, zero errors). Facts used, with where they were read:

* SMTC vtable slots (the research's section 2.3 names the classes and IIDs; the
  slot order was read from the bindings):
  `windows-rs` 0.62.2 `src/Windows/Media/Control/mod.rs`,
  `IGlobalSystemMediaTransportControlsSession_Vtbl` (SourceAppUserModelId 6,
  TryGetMediaPropertiesAsync 7, GetTimelineProperties 8, GetPlaybackInfo 9,
  TryPlayAsync 10 ... TryChangePlaybackPositionAsync 24),
  `..SessionManager_Vtbl` (GetCurrentSession 6, GetSessions 7),
  `..SessionManagerStatics_Vtbl` (RequestAsync 6), `..SessionMediaProperties_Vtbl`
  (Title 6, Artist 9, AlbumTitle 10), `..SessionPlaybackInfo_Vtbl` (Controls 6,
  PlaybackStatus 7, AutoRepeatMode 9, PlaybackRate 10, IsShuffleActive 11),
  `..SessionTimelineProperties_Vtbl` (Position 10, LastUpdatedTime 11),
  `..SessionPlaybackControls_Vtbl` (IsPlayEnabled 6 ... IsPlaybackPositionEnabled 20).
* `IAsyncOperation<T>` (SetCompleted 6, Completed 7, GetResults 8) and
  `IReference<T>` (Value 6): `windows-future` 0.3.2 `src/bindings.rs`, and
  `windows` 0.62.2 `src/Windows/Foundation/mod.rs`.
* `IVectorView<T>` (GetAt 6, Size 7): `windows-collections` 0.3.2 `src/bindings.rs`.
* `GlobalSystemMediaTransportControlsSessionPlaybackStatus` Closed 0, Opened 1,
  Changing 2, Stopped 3, Playing 4, Paused 5, and
  `MediaPlaybackAutoRepeatMode` None 0, Track 1, List 2: `windows-rs` 0.62.2
  `src/Windows/Media/Control/mod.rs` and `src/Windows/Media/mod.rs`.
* SMTC class and statics IIDs: `2050c4ee-11a0-57de-aed7-c97c70338245` (statics,
  from the `define_interface!` line in windows-rs), and the class name
  `Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager`.
* Microsoft Learn returned no content from this sandbox, so Microsoft's own text
  was not read. Every enum value above comes from windows-rs alone (single-source;
  windows-rs is generated from the Windows metadata).
* MPRIS 2.2 rules (bus prefix, `NoTrack`, `Rate` 0 is paused, `Seeked`, Position
  not signalled): the research's section 2.1, where the spec lines were read.
* AppleScript: `application id "..." is running` does not launch the app, and
  `tab` is an AppleScript constant (both single-source: Apple's AppleScript
  language guide, not fetched here). Scripts were not executed.

## Open risks

* The Windows and macOS code has never run. The vtable calls, the apartment
  setup (`winrt::enter` on the worker, MTA), the poll cost (several COM calls per
  session per second) and the AppleScript read format are the parts most likely
  to be wrong. The first real run on Windows and on macOS should start with the
  unit-level check of `smtc_convert` and `scripting_convert` (both pure, tested).
* Linux `Session.read` takes a full `GetAll` on each `PropertiesChanged`; a player
  that sends one per second costs three calls per second. Acceptable for v1.
