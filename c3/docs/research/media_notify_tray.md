# Research spike: media, notify, tray

Status: research only. No code was compiled or run against a live desktop; every
claim below was read from a primary source or a shipped implementation's source,
and the citation says which. Date of research: 2026-10-20. Template:
`docs/research/TEMPLATE.md`. Three services, sections 1 to 6 for each.

Legend used throughout:

* `[read]` the file was read in full or for the cited lines.
* `[README]` only the project README or docs page was read.
* `[not reached]` the source could not be fetched (github.com HTML/API blocked,
  the raw path does not exist, or the page is a login wall). Not used as evidence.
* `(single-source)` one source only. `(UNVERIFIED)` could not be checked here;
  treat as a hypothesis for the implementer to test.

Source short names:

* `MPRIS-2.2` = https://specifications.freedesktop.org/mpris-spec/latest/ (served version 2.2).
* `MPRIS-2.3-src` = https://gitlab.freedesktop.org/mpris/mpris-spec/-/archive/master/mpris-spec-master.tar.gz, files `spec/all.xml` and `spec/org.mpris.MediaPlayer2.*.xml` (version 2.3, the newer source).
* `NOTIF-1.3` = https://gitlab.freedesktop.org/xdg/xdg-specs/-/raw/master/notification/notification-spec.xml (Desktop Notifications Specification 1.3, 18 Aug 2024). Same text as specifications.freedesktop.org/notification-spec/latest/.
* `SNI-wiki` = https://www.freedesktop.org/wiki/Specifications/StatusNotifierItem/ (and sub-pages). `SNI-xml` = https://gitlab.freedesktop.org/xdg/xdg-specs/-/raw/master/status-notifier-item/status-notifier-item-spec.xml (version 0.1, date TBD).
* `KSNI-src` = https://invent.kde.org/frameworks/kstatusnotifieritem/-/archive/master/kstatusnotifieritem-master.tar.gz (KDE Frameworks, KStatusNotifierItem + libdbusmenu-qt exporter).
* `DBUSMENU-ksni` = `spec/DBusMenu.xml` inside crate `ksni` 0.3.1. `DBUSMENU-KDE` = `src/libdbusmenu-qt/com.canonical.dbusmenu.xml` inside `KSNI-src`.
* `DBUS-spec` = https://dbus.freedesktop.org/doc/dbus-specification.html.
* `PORTAL-notif` = https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Notification.html (portal version 2 docs).
* `APPLE-JSON` = https://developer.apple.com/tutorials/data/documentation/<path>.json (the JSON behind the doc pages; the HTML pages are JavaScript shells).
* `MS-*` = learn.microsoft.com pages; the full URL of each short name is listed below.
* `windows-rs` = crate `windows` 0.62.2, `src/Windows/Media/Control/mod.rs` and `src/Windows/UI/Notifications/Management/mod.rs`.
* `ungive-adapter` = https://github.com/ungive/mediaremote-adapter (raw files via raw.githubusercontent.com, branch master, fetched 2026-10-20).
* `MS-manager` = https://learn.microsoft.com/en-us/uwp/api/windows.media.control.globalsystemmediatransportcontrolssessionmanager; `MS-session` = same path ending `...controls.globalsystemmediatransportcontrolssession`; `MS-playbackinfo` = `...globalsystemmediatransportcontrolssessionplaybackinfo`; `MS-timeline` = `...globalsystemmediatransportcontrolssessiontimelineproperties`; `MS-media` = `...globalsystemmediatransportcontrolssessionmediaproperties`; `MS-controls` = `...globalsystemmediatransportcontrolssessionplaybackcontrols`; all under https://learn.microsoft.com/en-us/uwp/api/windows.media.control.
* `MS-listener` = https://learn.microsoft.com/en-us/uwp/api/windows.ui.notifications.management.usernotificationlistener; `MS-listener-status` = `...usernotificationlisteneraccessstatus` (same host, `/en-us/uwp/api/`); `MS-listener-guide` = https://learn.microsoft.com/en-us/windows/apps/design/shell/tiles-and-notifications/notification-listener.
* `MS-toast-manager` = https://learn.microsoft.com/en-us/uwp/api/windows.ui.notifications.toastnotificationmanager.createtoastnotifier; `MS-appids` = https://learn.microsoft.com/en-us/windows/win32/shell/appids.
* `MS-shellapi-nim` = https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shell_notifyiconw; `MS-notifyicondataw` = https://learn.microsoft.com/en-us/windows/win32/api/shellapi/ns-shellapi-notifyicondataw.

---

# media

Observe and control other applications' media players (Linux MPRIS, macOS
MediaRemote and scripting bridges, Windows SMTC), and optionally publish our own
session.

## 1. What a shell needs

Priority order, highest first:

1. **Player list with identity.** Every running player: stable id (bus name or
   AUMID or bundle id), human name (`Identity`), icon key (`DesktopEntry`, or
   the AUMID/bundle id mapped to an app icon), and a notion of which one is
   "active". Used by a media widget and a quick-settings tile.
2. **Now-playing card.** Playback status (playing/paused/stopped), title,
   artist, album, art (as a URL or as bytes), track length, current position.
3. **Position with a progress bar that moves smoothly.** Position is never
   pushed on Linux, and on Windows it is pushed only as a timestamped anchor.
   The service must extrapolate between reads and re-anchor on every event.
4. **Transport.** Play, pause, play/pause toggle, stop, next, previous; each
   gated by a capability flag (CanGoNext, IsNextEnabled, ...).
5. **Seek.** Relative seek and absolute set-position. Set-position must carry the
   track id so that a late click does not seek the next track.
6. **Change stream.** Players and state changes pushed as events (no polling of
   metadata). Position is the one thing that may be sampled.
7. **Secondary controls.** Volume, playback rate, shuffle, loop mode, raise the
   player window, quit the player. Each is optional; the UI shows it only when
   the capability says so.
8. **Open URI.** Rare in a shell. Keep it as a capability, not a v1 feature.
9. **Publish our own session (cut line).** Our own player appears in the OS
   now-playing UI and media keys reach us. Useful for a music app built with Bleu;
   not needed for a shell that only observes.

## 2. Per-platform native route (Linux / macOS / Windows)

### 2.1 Linux: MPRIS2 (route 1, preferred)

**Interface.** Object path `/org/mpris/MediaPlayer2` on the bus name
`org.mpris.MediaPlayer2.<name>` (optional `.instance<id>` suffix when several
instances run). Interfaces `org.mpris.MediaPlayer2` (root), `.Player`, optional
`.TrackList`, optional `.Playlists`. `[MPRIS-2.2]` "Bus Name Policy", "Entry point";
`[MPRIS-2.3-src]` `spec/all.xml` version 2.3.

* Root `org.mpris.MediaPlayer2`: methods `Raise()`, `Quit()`; properties `CanQuit b`,
  `Fullscreen b` (rw, optional), `CanSetFullscreen b`, `CanRaise b`, `HasTrackList b`,
  `Identity s`, `DesktopEntry s` (basename without `.desktop`), `SupportedUriSchemes as`,
  `SupportedMimeTypes as`. `[MPRIS-2.2]` root page.
* `org.mpris.MediaPlayer2.Player`:
  * methods `Next()`, `Previous()`, `Pause()`, `PlayPause()`, `Stop()`, `Play()`,
    `Seek(x Offset)` (microseconds, negative = back; beyond the end acts as Next),
    `SetPosition(o TrackId, x Position)` (ignored when TrackId is stale or
    Position is negative or beyond length), `OpenUri(s Uri)`.
  * 2.3 adds `GetArtworkFd()` returning a read-only fd with the artwork bytes and
    error `org.mpris.MediaPlayer2.Error.NoArtwork`. `[MPRIS-2.3-src]` Player.xml.
  * signal `Seeked(x Position)`.
  * properties: `PlaybackStatus s` (`Playing|Paused|Stopped`, read-only),
    `LoopStatus s` (`None|Track|Playlist`, rw), `Rate d` (rw, must not be 0.0),
    `Shuffle b` (rw), `Metadata a{sv}` (ro), `Volume d` (rw, 0.0 mute, 1.0 nominal,
    may exceed 1.0), `Position x` (ro, microseconds, NO PropertiesChanged),
    `MinimumRate d`, `MaximumRate d`, `CanGoNext b`, `CanGoPrevious b`,
    `CanPlay b`, `CanPause b`, `CanSeek b`, `CanControl b`.
    `[MPRIS-2.2]` Player page.
* `org.mpris.MediaPlayer2.TrackList` (optional): signals `TrackAdded`,
  `TrackRemoved`, `TrackMetadataChanged`, `TrackListReplaced`; mentioned in the
  spec's OpenUri text and in the `mpris` crate's event enum `[read]`.

**Discovery.** `ListNames` on `org.freedesktop.DBus`, filter the prefix
`org.mpris.MediaPlayer2.` (exact prefix, including the trailing dot), then track
additions and removals with `org.freedesktop.DBus.NameOwnerChanged`. The `mpris`
crate does exactly the ListNames filter with a 500 ms timeout and sorts by
lowercase name `[read: mpris-2.0.1 src/find.rs]`. Quickshell's
player-level code was read for position only, not for discovery.
A bus name containing `.instance<n>` is a second instance of the same player
(`MPRIS-2.2` "Bus Name Policy"). Two instances of one player must be two players.
Match rules: `NameOwnerChanged` with `arg0namespace='org.mpris.MediaPlayer2'`
(`DBUS-spec` documents `arg0namespace` since protocol revision 0.16 `[read]`).

**Metadata keys** (`a{sv}`), from `MPRIS-2.2` Metadata_Map and the `mpris` crate
accessors `[read: metadata.rs]`:

| key | type | note |
| --- | --- | --- |
| `mpris:trackid` | `o` | mandatory when a track exists; unique in the tracklist scope |
| `mpris:length` | `x` (int64) | microseconds; crate also accepts `t` |
| `mpris:artUrl` | `s` | `file://` or `http(s)://`; sandboxed players may not expose the file |
| `xesam:title` | `s` | |
| `xesam:artist` | `as` | list |
| `xesam:album` | `s` | |
| `xesam:albumArtist` | `as` | xesam ontology |
| `xesam:trackNumber` | `i` | crate reads `i32` |
| `xesam:discNumber` | `i` | crate reads `i32` |
| `xesam:url` | `s` | media URL |

Other xesam fields are allowed; unknown keys must be kept, not dropped.

**Position: the extrapolation rule.**

* The spec: "When this signal is not received, clients should assume that: When
  playing, the position progresses according to the rate property. When paused,
  it remains constant." `Seeked` is sent only for changes "inconsistent with the
  current playing state". `[MPRIS-2.2]` Seeked; `[MPRIS-2.3-src]` Player.xml
  lines 707-723 say the same.
* `Position` property: "The org.freedesktop.DBus.Properties.PropertiesChanged
  signal is not emitted when this property changes." `[MPRIS-2.2]`.
* The `mpris` crate: `position() = initial_position + elapsed`, where
  `elapsed = age_of_read * rate` if status is `Playing`, else 0. It does NOT
  clamp to `mpris:length` and does NOT use the reply time of the Position call
  `[read: mpris-2.0.1 src/progress.rs lines 384-425]`.
* Quickshell: `positionMs = cached_Position + (now - lastPositionTimestamp) * rate`
  when Playing; `pausedTime` when Paused (so it freezes); 0 when Stopped. It
  re-reads Position on PlaybackStatus change, 100 ms after a status change (for
  "exceptionally bad players"), on track change, and on `Seeked`. It uses
  `QDateTime::currentDateTime()` (wall clock) `[read: src/services/mpris/player.cpp lines 174-185, 311-313, 370-381]`.
* Astal polls `Position` once per second while `PlaybackStatus == Playing` and
  does no extrapolation `[read: lib/mpris/src/player.vala lines 799-829]`.
* Waybar goes through libplayerctl's `playerctl_player_get_position()` at its
  refresh interval `[read: src/modules/mpris/mpris.cpp lines 598-609]`. playerctl
  source itself was not reachable `[not reached]`.

**Rule adopted for this spike (recommendation):**

```
pos(now) = clamp(anchor.pos + (now - anchor.mono) * rate, 0, length)   if Playing
pos(now) = anchor.pos                                                   if Paused
pos(now) = 0                                                            if Stopped
```

* `now` and `anchor.mono` are monotonic clock readings, taken when the reply to
  the Position read arrives (not when the request is sent).
* Re-anchor (read Position again) on: PlaybackStatus change, `mpris:trackid`
  change, `Seeked`, Rate change (re-anchor before applying the new rate), reply to
  our own Seek or SetPosition, and every 1 s while Playing to bound drift.
* `Rate == 0.0` must not be treated as a rate. Treat it as Paused (spec: "If it
  is, the media player should act as though Pause was called" `[MPRIS-2.2]` Rate).
* Clamp to `[0, length]` when length is known. Quickshell and the `mpris` crate
  do not clamp; that is a deliberate deviation.

**Capabilities.** `CanControl` false means every other property is read-only and
every method must be treated as failing (spec, CanControl text `[MPRIS-2.2]`).
Per method/property: `CanPlay` (Play, PlayPause), `CanPause` (Pause, PlayPause),
`CanSeek` (Seek, SetPosition, Position writes), `CanGoNext`, `CanGoPrevious`.
Rate range `MinimumRate..MaximumRate`. `HasTrackList` on the root.

**Commands and their errors.**

| command | argument | effect per spec |
| --- | --- | --- |
| `Play` | none | no effect if playing; resumes from current position |
| `Pause` | none | no effect if paused; `Play` afterwards resumes at the same place |
| `PlayPause` | none | pause if playing, resume if paused, start if stopped; spec text says it should raise an error if CanPause is false |
| `Stop` | none | `Play` afterwards starts from the beginning |
| `Next` / `Previous` | none | no effect if CanGoNext/CanGoPrevious false; when there is no next and repeat is off, playback stops |
| `Seek` | `x` offset (us) | negative seeks back; below 0 sets 0; past the end acts like Next |
| `SetPosition` | `o` TrackId, `x` position (us) | stale TrackId is ignored; out of range ignored |
| `OpenUri` | `s` uri | scheme must be in `SupportedUriSchemes`; wait for `mpris:trackid` change |
| `Raise` / `Quit` | none | effect only when CanRaise / CanQuit; may raise `org.freedesktop.DBus.Error.NotSupported` |

Errors to map: `org.freedesktop.DBus.Error.NotSupported`,
`org.mpris.MediaPlayer2.Error.NoArtwork` (2.3). `[MPRIS-2.3-src]` all.xml line 196.

**Events.** `org.freedesktop.DBus.Properties.PropertiesChanged` on
`org.mpris.MediaPlayer2.Player` (and on the root interface) for every property
except `Position` and `CanControl`; `Seeked` on the Player interface. For
TrackList, the four signals above.

**Art.** `mpris:artUrl` is the common path. For `file://` URLs, read the file
locally (no sandbox concern unless the player is in Flatpak). For sandboxed
players, call `GetArtworkFd` (2.3) and read with `pread(2)` from offset 0; if the
fd is memfd-sealed, mapping is safe (`MPRIS-2.3-src` Player.xml GetArtworkFd).
Players that only implement 2.2 will not have this method.

**Permissions and daemons.** None on the session bus. Players inside a sandbox
may hide their files from us; that is a player-side limit.

**Call sequence (happy path, observer):**

1. `conn = session bus` (`bleu::dbus`).
2. `names = ListNames()`; keep names with prefix `org.mpris.MediaPlayer2.`.
3. Add match `NameOwnerChanged` with `arg0namespace=org.mpris.MediaPlayer2`.
4. For each name: `GetAll(org.mpris.MediaPlayer2)` and `GetAll(org.mpris.MediaPlayer2.Player)`;
   if `HasTrackList`, `GetAll(org.mpris.MediaPlayer2.TrackList)`.
5. Add match `PropertiesChanged` with `sender=<name>`, `path=/org/mpris/MediaPlayer2`, and a
   second match for `Seeked`.
6. Anchor position: `Get(Player, Position)`, stamp monotonic time.
7. On signal: update cache; if PlaybackStatus or trackid changed, re-anchor.
8. On `NameOwnerChanged` with new owner empty: remove player; if the name is
   reclaimed (new owner set) with a `.instance` suffix, treat as new player.
9. Stop: remove match rules; drop all player state.

**Pitfalls.**

* Players that register the name but do not implement Player (CanControl false).
* Players that send no PropertiesChanged for Metadata until a second later
  (Jellyfin, YouTube per Quickshell comments) `[read quickshell player.cpp 311-313, 378-385]`.
* Players that export `Position` but never update it. The `mpris` crate documents a probe:
  query `initial_position` twice while Playing; if both are 0, the client probably has no
  position support (`progress.rs` docs `[read]`). Do not assume `CanSeek` implies a live Position.
* `mpris:trackid` may be missing or non-unique on bad players. Quickshell's comments
  note players that set `xesam:url` or `mpris:trackid` inconsistently `[read player.cpp ~line 292]`.
  Avoid using trackid as the only identity for the player-level state.

**Publishing our own session (cut line).** Export `org.mpris.MediaPlayer2.<app>`
with the root and Player interfaces. Reference implementation: `mpris-server` 0.8.1
`[read: src/player.rs]`: `set_position` on the local model does NOT emit
PropertiesChanged (correct for Position); the server emits `Seeked` only when
`Player::seeked()` is called. `souvlaki` 0.8.3 `[read: src/platform/mpris/zbus.rs]`
has four defects that must not be copied: `set_position` ignores the `TrackId`
argument (stale-call protection missing, line 243); `Seeked` is never emitted
(comment line 240); `Rate`, `MinimumRate`, `MaximumRate` are hard-coded `1.0`
(lines 272, 343-349); `mpris:trackid` is the constant `/` (line 293), which
breaks uniqueness and makes SetPosition staleness checks meaningless.

### 2.2 macOS: MediaRemote (private, route 2) and scripting (route 3)

**Honest status.** There is no public API for observing or controlling another
app's now-playing session. `MPNowPlayingInfoCenter` is publish-only: "An object
for setting the Now Playing information for media that your app plays." `[APPLE-JSON]
mediaplayer/mpnowplayinginfocenter.json`. It has `nowPlayingInfo`, `playbackState`,
and `MPNowPlayingSession` for several players, all for the app's own media.

**Route 2a: MediaRemote.framework (private), in-process.** Loaded at run time:
`CFBundleCreate(NULL, "/System/Library/PrivateFrameworks/MediaRemote.framework")`
then `CFBundleGetFunctionPointerForName(bundle, CFSTR("<symbol>"))`. This is
exactly the "resolve at run time, never link" rule of `docs/ARCHITECTURE.md`
`[read: ungive-adapter src/private/MediaRemote.m, the init method]`.
Symbols (typedefs in `src/private/MediaRemote.h` `[read]`):

* `bool MRMediaRemoteSendCommand(MRCommand command, id userInfo)`
* `void MRMediaRemoteSetElapsedTime(double seconds)` (seconds, not microseconds)
* `void MRMediaRemoteSetPlaybackSpeed(int)`, `MRMediaRemoteSetShuffleMode(int)`, `MRMediaRemoteSetRepeatMode(int)`
* `void MRMediaRemoteRegisterForNowPlayingNotifications(dispatch_queue_t)`,
  `MRMediaRemoteUnregisterForNowPlayingNotifications()`
* `void MRMediaRemoteGetNowPlayingInfo(dispatch_queue_t, void (^)(NSDictionary *))`
* `void MRMediaRemoteGetNowPlayingApplicationPID(dispatch_queue_t, void (^)(int))`
* `void MRMediaRemoteGetNowPlayingClient(dispatch_queue_t, void (^)(id))`
* `void MRMediaRemoteGetNowPlayingApplicationIsPlaying(dispatch_queue_t, void (^)(bool))`

Notifications (`NSString` globals, `[read: src/private/MediaRemote.m]`):
`kMRMediaRemoteNowPlayingInfoDidChangeNotification`,
`kMRMediaRemoteNowPlayingApplicationDidChangeNotification`,
`kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification` (user-info key
`kMRMediaRemoteNowPlayingApplicationIsPlayingUserInfoKey`),
`kMRMediaRemoteNowPlayingPlaybackQueueDidChangeNotification`,
`kMRMediaRemoteNowPlayingApplicationPIDUserInfoKey`.

Info-dictionary keys (`kMRMediaRemoteNowPlayingInfo*`, values as the string name
without prefix): `Title`, `Artist`, `Album`, `Duration`, `ElapsedTime`,
`PlaybackRate`, `Timestamp`, `ArtworkData`, `ArtworkMIMEType`, `Composer`, `Genre`,
`Timestamp`, `TrackNumber`, `TotalTrackCount`, `TotalDiscCount`, `QueueIndex`,
`TotalQueueCount`, `ChapterNumber`, `UniqueIdentifier`, `ContentItemIdentifier`,
`RadioStationIdentifier`, `RadioStationHash`, `MediaType`, `ServiceIdentifier`,
`IsAdvertisement`, `IsBanned`, `IsLiked`, `IsInWishList`, `IsMusicApp`,
`ProhibitsSkip`, `RepeatMode`, `ShuffleMode`, `StartTime`, `Supports*` flags
`[read: MediaRemote.m]`.

**Commands** (`MRCommand`, `[read: src/private/MediaRemote.h` lines 68-96`]`):

| value | name | value | name |
| --- | --- | --- | --- |
| 0 | kMRPlay | 8 | kMRStartForwardSeek |
| 1 | kMRPause | 9 | kMREndForwardSeek |
| 2 | kMRTogglePlayPause | 10 | kMRStartBackwardSeek |
| 3 | kMRStop | 11 | kMREndBackwardSeek |
| 4 | kMRNextTrack | 12 | kMRGoBackFifteenSeconds |
| 5 | kMRPreviousTrack | 13 | kMRSkipFifteenSeconds |
| 6 | kMRToggleShuffle | 0x6A / 0x6B | kMRLikeTrack / kMRBanTrack |
| 7 | kMRToggleRepeat | 0x6C / 0x6D | kMRAddTrackToWishList / kMRRemoveTrackFromWishList |

Shuffle and repeat modes (adapter's public enums, `include/MediaRemoteAdapter.h`
`[read]`): shuffle 1 off, 2 albums, 3 tracks; repeat 1 off, 2 track, 3 playlist.

**Call sequence (observer, in-process):**

1. `dlopen`-style load of the framework through `bleu::dl` equivalents
   (`CFBundleCreate`, `CFBundleGetFunctionPointerForName`); any missing symbol
   gives `UNSUPPORTED_BACKEND`.
2. `MRMediaRemoteRegisterForNowPlayingNotifications(queue)` on our serial queue;
   observe the notifications above with `NSNotificationCenter`.
3. On each notification: `MRMediaRemoteGetNowPlayingInfo` and
   `MRMediaRemoteGetNowPlayingApplicationIsPlaying` and
   `MRMediaRemoteGetNowPlayingApplicationPID`; resolve bundle id from PID with
   `NSRunningApplication`.
4. Commands: `MRMediaRemoteSendCommand(cmd, nil)` returns bool;
   `MRMediaRemoteSetElapsedTime(sec)` seeks.
5. Stop: `Unregister...` and remove observers.

Timestamp rule: the adapter computes the live position as
`ElapsedTime + (now - Timestamp) * PlaybackRate` when `PlaybackRate >= 0`
`[read: ungive-adapter src/adapter/now_playing.m lines 26-50]`. This is the same
rule as MPRIS, anchored on the `Timestamp` key instead of our own read.

**macOS 15.4 and later: the breakage and the workaround.** `[README]` The adapter
README says the framework is "completely non-functional when being loaded directly
from within an app, starting with macOS 15.4" and that the processes that work
have bundle identifiers starting with `com.apple.` (the Perl binary
`/usr/bin/perl` has `com.apple.perl5`, shown in a `mediaremoted` log line)
`[README]` "Why this works". The README links issue threads (LosslessSwitcher #161,
LyricFever #94, boring.notch #417, ...) `[not reached]`. So the in-process route
returns nothing for an ordinary bundle; the claim that the check is by bundle
identifier prefix is `(single-source)`.

**Route 2b: the Perl adapter (workaround, route 2a').** The adapter runs
`/usr/bin/perl mediaremote-adapter.pl <MediaRemoteAdapter.framework> <cmd>`.
The Perl script `DynaLoader::dl_load_file` loads our framework, finds a symbol
`adapter_<cmd>` (or `adapter_<cmd>_env` with `MEDIAREMOTEADAPTER_PARAM_*` and
`MEDIAREMOTEADAPTER_OPTION_*` environment variables) and calls it
`[read: bin/mediaremote-adapter.pl lines 96-300]`. Commands: `get`, `stream`
(JSON lines with `type:"data"`, `diff`, `payload`), `send <id>`, `seek <us>`,
`shuffle`, `repeat`, `speed`, `test`. `stream` diffs: `payload` is a partial
update when `diff:true`; a key set to `null` is removed `[README]`.
The framework itself is built from C/ObjC in the CMake project
(`src/adapter/*.m`, `src/private/MediaRemote.m`) `[read: CMakeLists.txt]`.
The README badge says it was tested on macOS 27.0 build 26A5425a, last checked
September 2026 `[README]` (badge, not independently verified).

Implication for Bleu: the private route for the observer is a child process
(`/usr/bin/perl`) emitting JSON, not an in-process C3 call. This is the only
route that works on 15.4+ without the user installing anything, and it is
exactly the thing `ARCHITECTURE.md` asks to be quarantined in a `*_private.c3`
file with an observed-OS note.

**Route 3: scripting bridges (public, per app).** `tell application "Spotify"`
with `player state`, `player position`, `artwork url of current track`, `sound
volume`, `set player position` `[read: Hammerspoon extensions/spotify/spotify.lua
lines 26-330]`. Music.app is the same idea with its own dictionary. Each target
app needs an Automation permission (AppleEvents, TCC) `(UNVERIFIED: TCC prompt
text and per-app grant behaviour not checked here)`. Polling-only; no change
events. Artwork URL is provided by Spotify but not by every app.

**Permissions.** In-process MediaRemote: none needed, but broken on 15.4+ for
ordinary bundles. Perl route: no TCC prompt is documented in the README
`[README]`. AppleEvents: Automation TCC per target app `(UNVERIFIED)`.

**Pitfalls.** Callbacks arrive on arbitrary queues: marshal into the worker
mailbox (ARCHITECTURE "Threads"). Artwork arrives late and sometimes unloads for
a moment; the adapter keeps the old artwork when the track has not changed
`[README]` "Built-in fixes". `kMRMediaRemoteNowPlayingInfo*` may be absent; the
adapter treats a missing title as "not valid" unless `--allow-missing-title`
`[README]`. Track-change debounce quirk: `com.tidal.desktop` sends mixed metadata
for a moment (adapter's experimental debounce flag) `[README]`.

### 2.3 Windows: SMTC (route 1)

**Classes and IIDs** (`windows-rs`, namespace `Windows.Media.Control`):

* `GlobalSystemMediaTransportControlsSessionManager` (class). Statics interface
  `IGlobalSystemMediaTransportControlsSessionManagerStatics` IID
  `2050c4ee-11a0-57de-aed7-c97c70338245`; instance interface
  `IGlobalSystemMediaTransportControlsSessionManager` IID `cace8eac-e86e-504a-ab31-5ff8ff1bce49`.
  `[read: windows-rs Windows/Media/Control/mod.rs lines 673, 688]`.
* `GlobalSystemMediaTransportControlsSession` IID `7148c835-9b14-5ae2-ab85-dc9b1c14e1a8` `[read: mod.rs line 639]`.
* Property/return types: `Position` and timeline times are `Windows.Foundation.TimeSpan`
  (`pub Duration: i64`, 100-ns ticks); `LastUpdatedTime` is `DateTime`
  (`UniversalTime: i64`); `PlaybackRate` is `IReference<f64>` (nullable);
  `IsShuffleActive` is `IReference<bool>`; `AutoRepeatMode` is
  `IReference<MediaPlaybackAutoRepeatMode>`; `Thumbnail` is `IRandomAccessStreamReference`.
  `[read: windows-rs Windows/Media/Control/mod.rs lines 575-610, 342-350, 498-535; Foundation mod.rs 2444]`.
  `[MS-timeline]` `GlobalSystemMediaTransportControlsSessionTimelineProperties`:
  `Position` is "current as of LastUpdatedTime".

**Call sequence:**

1. Initialise COM (the class is `Threading(Both)` and `MarshalingBehavior(Agile)`
   `[MS-manager]` class page, so any apartment works).
2. `RequestAsync()` (statics) returns `IAsyncOperation<Manager>`; await it.
3. `GetCurrentSession()` and `GetSessions()` (IVectorView).
4. Subscribe `SessionsChanged` and `CurrentSessionChanged` on the manager.
5. For each session: `SourceAppUserModelId` (the player id), then
   `TryGetMediaPropertiesAsync()` (Title, Artist, AlbumTitle, AlbumArtist,
   TrackNumber, AlbumTrackCount, Subtitle, Genres, PlaybackType, Thumbnail),
   `GetPlaybackInfo()` (PlaybackStatus, Controls, AutoRepeatMode, IsShuffleActive,
   PlaybackRate), `GetTimelineProperties()` (StartTime, EndTime, MinSeekTime,
   MaxSeekTime, Position, LastUpdatedTime).
6. Subscribe per session: `MediaPropertiesChanged`, `PlaybackInfoChanged`,
   `TimelinePropertiesChanged` `[MS-session]`.
7. Commands: `TryPlayAsync`, `TryPauseAsync`, `TryTogglePlayPauseAsync`,
   `TryStopAsync`, `TrySkipNextAsync`, `TrySkipPreviousAsync`,
   `TryChangePlaybackPositionAsync(Int64 ticks)`, `TryChangePlaybackRateAsync(double)`,
   `TryChangeShuffleActiveAsync(bool)`, `TryChangeAutoRepeatModeAsync`,
   `TryFastForwardAsync`, `TryRewindAsync`. Each returns `bool` (accepted)
   `[windows-rs]` `TryChangePlaybackPositionAsync(&self, i64) -> IAsyncOperation<bool>`.

**Controls flags** `GlobalSystemMediaTransportControlsSessionPlaybackControls`:
`IsPlayEnabled`, `IsPauseEnabled`, `IsPlayPauseToggleEnabled`, `IsStopEnabled`,
`IsNextEnabled`, `IsPreviousEnabled`, `IsFastForwardEnabled`, `IsRewindEnabled`,
`IsPlaybackPositionEnabled`, `IsPlaybackRateEnabled`, `IsShuffleEnabled`,
`IsRepeatEnabled`, `IsRecordEnabled`, `IsChannelUpEnabled`, `IsChannelDownEnabled`
`[MS-controls]`.

**Position rule.** Windows gives an anchor (`Position` as of `LastUpdatedTime`)
and the PlaybackRate. Use the same formula as the Linux section, with
`anchor = Position`, `anchor.mono` = `LastUpdatedTime` converted to our monotonic
clock by the difference of wall clocks at receipt `(UNVERIFIED: conversion
approach; test clock skew)`. Null PlaybackRate: treat as 1.0 `(UNVERIFIED: no
documented null meaning)`.

**Permissions and manifest.** The manager page lists the app capability
`globalMediaControl` `[MS-manager]`. Whether an unpackaged desktop app needs it or
can get it is not verified here `(UNVERIFIED)`.

**Pitfalls.** Sessions come and go (a player that closes gives no state change
until the next `SessionsChanged`); keep sessions keyed by AUMID; media properties
may be stale until `MediaPropertiesChanged` (call `TryGetMediaPropertiesAsync`
again on `TimelinePropertiesChanged` if the title changes). Thumbnail is an
`IRandomAccessStreamReference`: `OpenReadAsync` and read into bytes (not
inspected here `(UNVERIFIED)`).

**Rust binding route.** `windows` 0.62.2 with features `Media_Control` (which
implies `Media` and `Foundation`; `Cargo.toml` features) and
`Storage_Streams` for the thumbnail `[read: windows-rs Cargo.toml lines 199, 209]`.
The C3 route is `bleu::win` COM + WinRT activation of the statics; the IIDs
above are what `bleu::win` needs.

**Publishing our own session (cut line).** `SystemMediaTransportControls`
(not read `[not reached]`). `souvlaki` 0.8.3 implements the Windows side
`[read: src/platform/windows/mod.rs, 220 lines]`; not reviewed in depth.

## 3. Reference implementations (prove it works)

| project | language | file (URL or crate path) | what to copy | read status |
| --- | --- | --- | --- | --- |
| `mpris` crate 2.0.1 | Rust (client) | `static.crates.io/crates/mpris/mpris-2.0.1.crate`: `src/progress.rs`, `src/find.rs`, `src/metadata.rs` | discovery by ListNames+prefix, active-player choice, position extrapolation (and its no-clamp gap) | [read] progress, find, metadata |
| `mpris-server` 0.8.1 | Rust (server) | crate `src/player.rs`, `src/lib.rs`, `src/local_server.rs` | server trait shape, Seeked emission, Position without PropertiesChanged | [read] player, lib in part |
| `souvlaki` 0.8.3 | Rust (cross-platform controls) | crate `src/platform/mpris/zbus.rs`, `src/platform/macos/mod.rs`, `src/platform/windows/mod.rs` | what NOT to do (defects listed in 2.1) | [read] mpris zbus.rs; [read in part] macos/windows |
| Quickshell `Services.Mpris` | C++/Qt | `raw.githubusercontent.com/quickshell-mirror/quickshell/master/src/services/mpris/player.cpp` | re-query on status and track change, pausedTime freeze | [read] player.cpp |
| Astal mpris | Vala | `raw.githubusercontent.com/Aylur/astal/main/lib/mpris/src/player.vala` | 1 s position poll while playing | [read] lines 790-880 |
| Waybar `modules/mpris/mpris.cpp` | C++ | `raw.githubusercontent.com/Alexays/Waybar/master/src/modules/mpris/mpris.cpp` | uses libplayerctl; formats position | [read] in part |
| ungive `mediaremote-adapter` | ObjC + Perl | `raw.githubusercontent.com/ungive/mediaremote-adapter/master/`: `bin/mediaremote-adapter.pl`, `src/private/MediaRemote.m`, `src/private/MediaRemote.h`, `src/adapter/*.m`, `include/MediaRemoteAdapter.h`, `README.md`, `CMakeLists.txt` | the only public read of the private MediaRemote symbols, keys, command IDs, and the 15.4 workaround | [read] all listed |
| ungive `media-control` | ObjC CLI | `raw.githubusercontent.com/ungive/media-control/master/README.md` | CLI shape for stream output | [README] |
| Hammerspoon `spotify` | Lua | `raw.githubusercontent.com/Hammerspoon/hammerspoon/master/extensions/spotify/spotify.lua` | AppleScript property names for Spotify | [read] |
| windows-rs 0.62.2 | Rust bindings | crate `windows-0.62.2` `src/Windows/Media/Control/mod.rs` | exact IIDs, method and property types for SMTC | [read] |
| playerctl | C | `altdesktop/playerctl` | libplayerctl semantics | [not reached] (GitHub) |
| DankMaterialShell | Go/QML | `raw.githubusercontent.com/AvengeMedia/DankMaterialShell/master/README.md` | only README; source paths guessed wrong | [README] |

## 4. Double validation

| claim | source A | source B | status |
| --- | --- | --- | --- |
| MPRIS bus prefix `org.mpris.MediaPlayer2.`, path `/org/mpris/MediaPlayer2` | `MPRIS-2.2` Bus Name Policy and Entry point | `mpris` crate `find.rs` (`MPRIS2_PREFIX`) | confirmed |
| Position has no PropertiesChanged; rate-based extrapolation when Playing; constant when Paused | `MPRIS-2.2` Position and Seeked; `MPRIS-2.3-src` Player.xml | Quickshell `positionMs` and `mpris` crate `elapsed()` | confirmed |
| Spec 2.3 adds GetArtworkFd and NoArtwork error | `MPRIS-2.3-src` all.xml changelog and Player.xml | `specifications.freedesktop.org/mpris-spec/latest/` still serves 2.2 | (single-source for 2.3 text: git master; the published page lags) |
| `SetPosition` ignores stale TrackId | `MPRIS-2.2` SetPosition text | souvlaki zbus.rs line 243 ignores it (defect) | confirmed |
| `mpris:length` is int64 in microseconds | `MPRIS-2.2` Metadata_Map text | `mpris` crate `length_in_microseconds` | confirmed |
| Notification `image-data` is `(iiibiiay)`: width, height, rowstride, has_alpha, bits_per_sample=8, channels (4 if alpha else 3), data | `NOTIF-1.3` Formats | `notify-rust` `image.rs` `to_tuple` (same order) | confirmed |
| Notification closed reasons 1..4 | `NOTIF-1.3` NotificationClosed | dunst `dbus.c` `signal_notification_closed` and reason strings | confirmed |
| Stack-tag hints `synchronous`, `private-synchronous`, `x-canonical-private-synchronous`, `x-dunst-stack-tag` | dunst `dbus.c` lines 147-152 | none for the non-spec ones (not in NOTIF-1.3) | (single-source: dunst) |
| `value` progress hint (INT32 or UINT32) | dunst `dbus.c` lines 785-792 | NOT in NOTIF-1.3 table | (single-source: dunst; de-facto) |
| `ActivationToken` signal | `NOTIF-1.3` ActivationToken | KDE `org.freedesktop.Notifications.xml` in `KSNI-src` | confirmed as spec; dunst does not emit it (grep of dbus.c); Astal declares, does not emit |
| `NotificationReplied` and `Inhibit`/`UnInhibit`/`Inhibited` | KDE `org.freedesktop.Notifications.xml` (marked "non-standard") | none | (single-source: KDE) |
| StatusNotifierItem method/property/signal names and types | `SNI-xml` / `SNI-wiki` | `KSNI-src` `org.kde.StatusNotifierItem.xml`; ksni `spec/StatusNotifierItem.xml`; system-tray `item.rs` | confirmed; KDE interface name is `org.kde.StatusNotifierItem`, spec text says `org.freedesktop.StatusNotifierItem` |
| `WindowId` type | `SNI-wiki` says UINT32 | KDE XML says `i`; ksni comment and system-tray read `i32` | conflict: use `i` when reading (KDE behaviour) |
| `Scroll` orientation string | `SNI-wiki` lower-case `horizontal`/`vertical` | ksni `tray.rs` lines 6-7 says KDE uses `Horizontal`/`Vertical` | conflict: accept both, send lower-case to freedesktop-named items |
| IconPixmap ARGB32 in network byte order (bytes A,R,G,B per pixel) | `SNI-xml` "Icon pixmap" | KDE `kstatusnotifieritem.cpp` `imageToStruct` (qToBigEndian per 32-bit word); Waybar `item.cpp` lines 421-431 (ARGB to RGBA) | confirmed |
| DBusMenu `GetLayout(i,i,as)->(u,(ia{sv}av))` | `DBUSMENU-ksni` `spec/DBusMenu.xml` | `DBUSMENU-KDE` `com.canonical.dbusmenu.xml`; system-tray `dbus_menu_proxy.rs` | confirmed (three copies) |
| `Event(i,s,v,u)`, `AboutToShow(i)->b` | DBUSMENU-ksni | DBUSMENU-KDE + KDE exporter `DBusMenuExporterDBus::Event`, `AboutToShow` | confirmed |
| Layout revision, LayoutUpdated(u,i) | DBUSMENU-KDE | system-tray `layout_updated(revision, parent)` | confirmed |
| Watcher is `org.kde.StatusNotifierWatcher` in practice | ksni, KDE, Quickshell, Waybar, Astal, system-tray all use it | `SNI-wiki` says `org.freedesktop.StatusNotifierWatcher` | conflict: claim both names on the bus only if needed; de-facto is KDE |
| Registered item strings are `<bus>` + `<path>` concatenated (e.g. `:1.72/org/...`) | system-tray `status_notifier_watcher.rs` `format!("{service}{objpath}")` | Waybar `watcher.cpp` lines 120 (`%s%s`) | confirmed |
| Electron >= 43.4.1 registers `bus/path` in one argument | Waybar `watcher.cpp` lines 99-102 comment | system-tray `parse_service` splits only a leading `/` (path-only form) | (single-source: Waybar); system-tray would likely reject it `(UNVERIFIED by running)` |
| `kAXExtrasMenuBarAttribute` is a `String` constant, macOS 10.8+ | `APPLE-JSON` applicationservices/kaxextrasmenubarattribute.json | none fetched | (single-source: Apple) |
| `kAXTrustedCheckOptionPrompt` exists, macOS 10.9+ | `APPLE-JSON` kaxtrustedcheckoptionprompt.json | none | (single-source: Apple) |
| `UNUserNotificationCenter.requestAuthorization`, `willPresent` delegate | `APPLE-JSON` (names and abstracts) | none | (single-source: Apple) |
| `getDeliveredNotifications` returns only the app's own notifications | `APPLE-JSON` usernotifications_unusernotificationcenter.json: "all of your app's delivered notifications" | none | confirmed by wording (single-source) |
| `MPNowPlayingInfoCenter` is publish-only | `APPLE-JSON` mediaplayer/mpnowplayinginfocenter.json | none | (single-source: Apple) |
| MediaRemote symbol names and command IDs | `ungive-adapter` `MediaRemote.m`, `MediaRemote.h` | `ungive-adapter` `MediaRemoteAdapter.h` (kMRA* duplicates) | (single-source: ungive; Apple never published them) |
| MediaRemote returns nothing for ordinary bundles since macOS 15.4 | `ungive-adapter` README | `[not reached]` issue threads | (single-source: README) |
| SMTC `RequestAsync`, `GetCurrentSession`, `GetSessions`, `SessionsChanged`, `CurrentSessionChanged`, `TryChangePlaybackPositionAsync` | `MS-manager`, `MS-session` | `windows-rs` bindings (same names, same signatures) | confirmed |
| SMTC position is "current as of LastUpdatedTime" | `MS-timeline` | none | (single-source: Microsoft) |
| UserNotificationListener: Unspecified 0, Allowed 1, Denied 2 | `MS-listener-status` | none | (single-source: Microsoft) |
| Shell_NotifyIcon `NIM_SETVERSION` with `NOTIFYICON_VERSION_4`: LOWORD(lParam) event, HIWORD icon id, wParam anchor | `MS-shellapi-nim`, `MS-notifyicondataw` | `tray-icon` 0.21.0 uses legacy mode (no NIM_SETVERSION) | confirmed (docs); tray-icon chooses legacy `(read)` |
| Desktop toast needs a Start-menu shortcut with `System.AppUserModel.ID` | `MS-toast-manager` "Remarks" | `MS-appids` "Where to Assign an AppUserModelID" | confirmed |
| Desktop toasts cannot be scheduled | `MS-toast-manager` Remarks | none | (single-source: Microsoft) |

## 5. Proposed Bleu model

Draft only; not compiled. Style follows `docs/STYLE.md` (0.8.5 rules). State is
plain data: no pointers, no optionals in structs (a `bool` plus value instead),
`typedef` quantities, `String` and slices. Time is `Duration` (microseconds,
`bleu::time`) and a monotonic `Duration` since service start for anchors.

```c3
module bleu::media;
import bleu::error, bleu::availability;

typedef Volume = double;        // MPRIS scale: 0.0 mute, 1.0 nominal, may exceed 1.0
typedef PlaybackRate = double;  // multiplier; never 0.0 in state (0.0 is mapped to PAUSED)

enum Playback : char { STOPPED, PLAYING, PAUSED }        // MPRIS PlaybackStatus; SMTC Changing/Closed map to STOPPED
enum Loop : char { NONE, TRACK, PLAYLIST }                // MPRIS LoopStatus; SMTC None/Track/List

struct Anchor {                                            // extrapolation anchor (see rule in section 2.1)
    Duration position;      // position at the anchor, microseconds
    Duration mono;          // monotonic time of the anchor reading
}

struct Track {
    String track_id;        // mpris:trackid, AUMID, or bundle-derived; "" when none
    String title;
    String artist;
    String album;
    String art_url;         // may be "" (use art bytes capability instead)
    bool has_length;
    Duration length;        // valid when has_length
    int track_number;       // 0 when unknown
}

struct Player {
    String id;              // bus name (Linux), AUMID (Windows), bundle id (macOS)
    String identity;        // human name
    String desktop_entry;   // "" when unknown
    Playback status;
    Track track;
    Anchor anchor;
    PlaybackRate rate;      // 1.0 when unknown
    Volume volume;          // valid when Cap.VOLUME is available for this player
    bool shuffle;
    Loop loop;
    bool is_active;         // the one the shell shows
}

struct State {              // the Snapshot payload, published through Observable{State}
    Player[] players;
}

enum Cap : char {           // every optional operation (ARCHITECTURE rule 5)
    CONTROL, PLAY, PAUSE, STOP, NEXT, PREVIOUS, SEEK, SET_POSITION,
    SET_RATE, SHUFFLE, LOOP, VOLUME, RAISE, QUIT, OPEN_URI, ART_BYTES,
    PUBLISH_SESSION,
}

enum Change : char {        // Stream{Event} payload: transients, not state
    PLAYER_ADDED, PLAYER_REMOVED, STATUS, TRACK, SEEKED, RATE, VOLUME, SHUFFLE, LOOP, CAPS,
}

struct Event {
    Change change;
    String player_id;
}

struct Options {
    // Options.backend forces one of the backends listed below (empty = probe by priority).
    String backend;
    Duration position_refresh;   // while PLAYING; default 1 s (Astal and this spike agree)
}

// Backend priority (ARCHITECTURE rule 7)
//   linux:   mpris (1)
//   darwin:  mediaremote_perl (1, private, runtime probe with `test`), scripting (2, per app)
//   windows: smtc (1)
// Availability for Cap.PUBLISH_SESSION: linux mpris_export (1), darwin UNSUPPORTED (no public API),
// windows UNSUPPORTED until SMTC publishing is evaluated.
// Operation results: transport commands return Operation{bool} (accepted by the player).
```

Behaviour notes for the implementer:

* `Track.track_id` must be treated as opaque; never assume it is unique across players.
* `Anchor` is re-set on every event listed in section 2.1, not on a timer.
* `has_length == false` disables the progress bar and clamp.
* `Cap.SET_POSITION` requires `track_id != ""` on Linux; without it, fall back to a relative Seek
  (the Quickshell approach `[read]`).

## 6. Risks and cut lines

Hard:

* **macOS is the hard platform.** The only working observer route is the private
  MediaRemote via `/usr/bin/perl` (a child process with JSON). It depends on a
  Perl binary's bundle id, is undocumented, and was broken for ordinary apps in
  15.4 `[README]`. It needs a version-probed `test` before use.
* **Position is never pushed on Linux or Windows.** Every shell that does not
  extrapolate looks janky. The extrapolation rule above is the main quality risk.
* **Windows SMTC sessions are keyed by AUMID**, which is not always a stable
  player identity (packaged vs unpackaged apps, browsers). Expect duplicates.
* **Publishing our own session** on macOS has no public API. On Windows it is
  unresearched.

Not possible without private API or admin rights:

* Observing other apps' now-playing on macOS 15.4+ without the Perl workaround.
* Controlling a player that has no MPRIS/SMTC/AppleEvents surface (e.g. browser tabs,
  unless the browser exports MPRIS itself).
* Reading another app's artwork bytes on Linux if the player is sandboxed and does
  not implement `GetArtworkFd` (2.3). Art URL then fails.

Recommended first version (cut line):

1. Linux MPRIS observer and transport, with the extrapolation rule, Seek and
   SetPosition, capabilities, art from `file://` and `http(s)://`.
2. Windows SMTC observer and transport (manager, sessions, properties, timeline,
   commands). Thumbnail bytes as a later capability.
3. macOS: scripting-only backend (Spotify, Music) first; mark the MediaRemote
   Perl route as a separate, later, quarantined backend behind `Cap` availability
   `BACKEND_MISSING`/`UNSUPPORTED_BACKEND` when the probe fails.
4. Leave out: OpenUri, Fullscreen, Playlists, Quit, publishing our own session,
   GetArtworkFd, MediaRemote like/ban commands.

---

# notify

A notification server (a shell's notification centre), a client for sending
notifications, and observation of others' notifications where we are not the
daemon. Linux (freedesktop daemon), macOS (UserNotifications, private
usernoted), Windows (toasts, UserNotificationListener).

## 1. What a shell needs

Priority order:

1. **Receive** `Notify` from any app: summary, body (with the markup subset),
   app name, app icon, actions, expire timeout, `replaces_id` atomic replace.
   Return a non-zero id.
2. **Emit** `NotificationClosed(id, reason)` with reasons 1..4 and `ActionInvoked(id, key)`
   (including `default`). Support `CloseNotification(id)`.
3. **Capabilities and server info.** `GetCapabilities` and `GetServerInformation`
   must match actual behaviour: a server that claims `body-markup` must strip
   unsupported tags; a server that claims `actions` must emit `ActionInvoked`.
4. **Hints that change behaviour**: `urgency` (critical never auto-expires),
   `transient`, `resident` (no auto-close after an action), `suppress-sound`,
   `sound-name`/`sound-file`, `category` (grouping), `desktop-entry` (app icon
   and app identity), `image-data` / `image-path` (per spec precedence),
   `value` (progress bar; de facto), stack tags (`x-canonical-private-synchronous`
   and friends; de facto; replace the previous one in the same stack).
5. **Do not disturb and history.** Do-not-disturb suppresses popups but keeps
   history. History is a store the shell draws; not in the spec.
6. **Activation token.** `ActivationToken(id, token)` before `ActionInvoked`, so
   the activated app can take focus (Wayland xdg-activation or X11 startup id).
7. **Sending as a client.** Our shell sends `Notify` for its own events
   (battery low, screenshot done). Needs the same hint vocabulary.
8. **Observing other servers (cut line).** Only when we are not the daemon.
9. **Inline reply (KDE extension, optional).**

## 2. Per-platform native route (Linux / macOS / Windows)

### 2.1 Linux: freedesktop Notifications server (route 1, preferred)

**Interface.** Bus name `org.freedesktop.Notifications`, object
`/org/freedesktop/Notifications`, interface `org.freedesktop.Notifications`
`[NOTIF-1.3]` "Basic Design".

Methods (`[NOTIF-1.3]` D-Bus Protocol):

| method | in | out | notes |
| --- | --- | --- | --- |
| `Notify` | `s app_name`, `u replaces_id`, `s app_icon`, `s summary`, `s body`, `as actions`, `a{sv} hints`, `i expire_timeout` | `u id` | id never 0; replace returns same id; expire -1 server default, 0 never, >0 ms |
| `CloseNotification` | `u id` | none | emits `NotificationClosed` reason 3; unknown id: empty D-Bus error |
| `GetCapabilities` | none | `as` | see table below |
| `GetServerInformation` | none | `s name, s vendor, s version, s spec_version` | spec_version "1.3" for 1.3 compliance |

Signals:

* `NotificationClosed(u id, u reason)`: 1 expired, 2 dismissed by user, 3 closed by
  `CloseNotification`, 4 undefined/reserved. The id is invalid after the signal.
* `ActionInvoked(u id, s action_key)`: user clicked the notification (`default`) or
  an action button.
* `ActivationToken(u id, s activation_token)`: may precede `ActionInvoked`; token
  is an X11 startup id or an xdg-activation token `[NOTIF-1.3]`.

Non-spec (KDE, `org.freedesktop.Notifications.xml` in `KSNI-src`, marked "non-standard"):
signal `NotificationReplied(u id, s text)`; methods `Inhibit(s desktop_entry, s reason,
a{sv} hints) -> u`, `UnInhibit(u)`; property `Inhibited b`. `(single-source: KDE)`.

**Capabilities** (`[NOTIF-1.3]` Server Capabilities): `action-icons`, `actions`,
`body`, `body-hyperlinks`, `body-images`, `body-markup`, `icon-multi`,
`icon-static` (mutually exclusive with `icon-multi`), `persistence`, `sound`,
and vendor caps `x-<vendor>-...`. dunst advertises `actions`, `body`,
`body-hyperlinks`, `icon-static`, the four stack-tag hints, and `body-markup`
when markup is on `[read: dunst src/dbus.c lines 692-716]`. dunst does NOT
advertise `persistence` but keeps history through its own `org.dunstproject.cmd0`
interface `[read: dunst dbus.c lines 81-100]`.

**Hints** (`a{sv}`; values are variants; `[NOTIF-1.3]` Standard Hints table):

| name | type | spec version | notes |
| --- | --- | --- | --- |
| `action-icons` | `b` | >= 1.2 | actions are icon names; annotate with localized label |
| `category` | `s` | | `class.specific`, e.g. `im.received`, `transfer.complete` |
| `desktop-entry` | `s` | | basename of the .desktop file (e.g. `rhythmbox`) |
| `image-data` | `(iiibiiay)` | >= 1.2 | width, height, rowstride, has_alpha, bits_per_sample (8), channels (3 or 4), data (RGB or RGBA bytes) |
| `image_data`, `icon_data` | `(iiibiiay)` | 1.1 / <1.1 | deprecated; dunst reads them |
| `image-path` | `s` | >= 1.2 | file URI or theme name; `image_path` deprecated |
| `resident` | `b` | >= 1.2 | do not remove on action invoke |
| `sound-file` | `s` | | path |
| `sound-name` | `s` | | themed sound name |
| `suppress-sound` | `b` | | sender plays its own sound |
| `transient` | `b` | >= 1.2 | bypass persistence |
| `x`, `y` | `i` | | point at screen position (both required) |
| `urgency` | `y` | | 0 low, 1 normal, 2 critical |
| `value` | `i` or `u` | (de facto) | progress 0..100; dunst reads INT32 then UINT32 `[read dbus.c lines 785-792]`; not in NOTIF-1.3 |
| `synchronous`, `private-synchronous`, `x-canonical-private-synchronous`, `x-dunst-stack-tag` | `s` | (de facto) | stack tag: replace earlier notification with same tag; dunst takes the first found `[read dbus.c lines 147-152]` |

**Image precedence** (`[NOTIF-1.3]` Priorities): a server that shows one image
uses `image-data`, then `image-path`, then `app_icon`, then `icon_data`. A server
that shows icon and image uses `app_icon` as the icon and `image-data`, then
`image-path`, then `icon_data` as the image.

**Markup** (`[NOTIF-1.3]` Markup): `<b>`, `<i>`, `<u>`, `<a href="...">`, `<img src alt>`
(image optional). Unsupported tags are stripped by the server; a server that does not
support markup must strip all tags client-side (`body-markup` cap absent).
Images must be local files; the 200x100 maximum is advice.

**Expiry and urgency.** Critical urgency must not expire automatically; expire 0
never expires `[NOTIF-1.3]`. Astal: `expire_timeout < 0` uses the server default;
`ignore-timeout` setting disables expiry `[read: Astal daemon.vala lines 74-130]`.

**Replace.** `replaces_id != 0` must replace atomically and return the same id.
Ids are unique for the session and not reused until uint32 overflow `[NOTIF-1.3]`.

**Call sequence (server):**

1. Own `org.freedesktop.Notifications` on the session bus (`bleu::dbus`). If it is
   already owned by another daemon, we are not the daemon: go to observer mode
   (2.1 observe).
2. Export `/org/freedesktop/Notifications` with the interface above.
3. `Notify`: validate the type signature; allocate id (or reuse on replace); copy
   fields into the store; convert `image-data` to a cached file or an in-memory
   image (Astal's `Notify` is lines 74-100 and writes a cache file via `cache_image`
   (line 166) and sets `image-path` `[read]`); set expiry timer unless `resident`, `urgency=critical`, or
   `expire==0`; publish state; return id.
4. On click or button: emit `ActivationToken` (if we have one), then
   `ActionInvoked(id, key)`. If not resident, close with a reason (see below).
5. On expiry or dismissal: emit `NotificationClosed(id, 1|2)`.
6. `CloseNotification`: remove, emit `NotificationClosed(id, 3)`.

Reason to use after an action: the spec defines no "action" reason. Astal uses
`CLOSED` (3) after `ActionInvoked` when not resident `[read: astal daemon.vala lines 60-64; enums.vala lines 7-11 CLOSED = 3]`.
dunst uses its own reason enum `[read]`. Choose reason 2 (dismissed) and document it,
or 3; the spec does not say `(UNVERIFIED: which convention clients expect)`.

**Observing when we are not the daemon.** D-Bus `BecomeMonitor` (method on
`org.freedesktop.DBus.Monitoring`, object `/org/freedesktop/DBus`) turns a
connection into a monitor that sees all messages. Only a user "privileged on this
bus (by some implementation-specific definition)" may do it. The `eavesdrop='true'`
match rule is deprecated in favour of it `[DBUS-spec]` Monitoring section and
`eavesdrop` text. A monitor sees `Notify` calls and the daemon's signals, not the
other daemon's rendered state. Whether the default session policy grants it is
`(UNVERIFIED)`.

Astal's "proxy" mode is a different thing: it only works when the other daemon is
Astal itself (it checks `Name`, `Vendor`, `Version` from `GetServerInformation`,
then calls its own non-spec methods `GetNotification`, `EmitResolved`,
`EmitActionInvoked`) `[read: astal proxy.vala lines 1-95]`. Do not copy the
non-spec methods; they are not in the spec.

**Activation token.** The spec allows the server to generate tokens. dunst does
not emit `ActivationToken` (not found in `dbus.c`). Astal declares the signal
with a TODO and does not emit it `[read: astal daemon.vala line 162]`. A
compositor-issued token (xdg-activation) for a notification we do not own is
`(UNVERIFIED: how a non-focused daemon obtains one on Wayland)`.

**Portal (note, route 1b).** Sandboxed apps use `org.freedesktop.portal.Notification`
version 2 `[PORTAL-notif]`: `AddNotification(s id, a{sv} notification)`,
`RemoveNotification(s id)`, signal `ActionInvoked(s id, s action, av parameter)`,
property `SupportedOptions a{sv}` (`category`, `button-purpose`), `version u`.
Notification keys: `title`, `body`, `markup-body`, `icon` (`v`: `(sv)` with
`themed` or `file-descriptor`; `bytes` deprecated), `priority` (`low`, `normal`,
`high`, `urgent`), `default-action`, `default-action-target`, `buttons`,
`display-hint` (`as`). The frontend is `org.freedesktop.portal.Desktop`
`(UNVERIFIED: bus name taken from portal convention, not from the doc page)`.
A desktop-side backend is `org.freedesktop.impl.portal.Notification` `(UNVERIFIED:
name not read; portal source not reachable)`.

**Sending as a client (route 1c).** Call `Notify` with `desktop-entry` set to our
application id, `image-data` only when needed (prefer `image-path`), and check
`GetCapabilities` first. Use `replaces_id` to update a progress notification.

### 2.2 macOS: UserNotifications (send) and private stores (observe)

**Send (public).** `UNUserNotificationCenter.current()`;
`requestAuthorization(options:completionHandler:)` with `UNAuthorizationOptions`;
`UNMutableNotificationContent` (title, body, categoryIdentifier, userInfo);
`UNNotificationCategory` (identifier, actions) registered with
`setNotificationCategories`; `UNNotificationRequest` added with `add(_:withCompletionHandler:)`;
`UNUserNotificationCenterDelegate` with `userNotificationCenter(_:willPresent:withCompletionHandler:)`
to show banners in the foreground `[APPLE-JSON]` usernotifications_*.json. Actions
are delivered to the delegate's `didReceive` method `(UNVERIFIED: name not fetched)`.
Needs the app's bundle identity `(UNVERIFIED)`. Authorization status via
`getNotificationSettings`.

**Observe others (no public API).** `UNUserNotificationCenter.getDeliveredNotifications`
returns "all of your app's delivered notifications" only `[APPLE-JSON]`. There is
no public route to other apps' notifications.

**Private store (route 2, not verified here).** The task brief names the
`usernoted` database at `$(getconf DARWIN_USER_DIR)com.apple.notificationcenter/db2/db`
(SQLite) and a Full Disk Access requirement. Not verified in this spike
`(UNVERIFIED)`. Reading it is a private, schema-unstable route; it would be
quarantined as `*_private.c3` with an observed-OS note.

**Distributed notifications.** `NSDistributedNotificationCenter` is "a notification
dispatch mechanism that enables the broadcast of notifications across task
boundaries" `[APPLE-JSON]` (abstract only). It carries app-level messages, not the
system notification list `(UNVERIFIED: whether any system notification is broadcast)`.

**What a replacement notification centre can and cannot do on macOS.** It can
draw its own UI for its own notifications (send path). It cannot suppress the
system's banners or the Notification Center list for other apps; no public API
exists for that `(UNVERIFIED for every OS release; high confidence from the absence of
public API in APPLE-JSON)`. A menu-bar notification UI would use `NSStatusItem`
(`[APPLE-JSON]` appkit/nsstatusitem.json: "An individual element displayed in the
system menu bar").

**Permissions.** Notification authorization (`requestAuthorization`). Private
store: Full Disk Access `(UNVERIFIED)`.

### 2.3 Windows: toasts (send) and UserNotificationListener (observe)

**Send.** `Windows.UI.Notifications.ToastNotificationManager.CreateToastNotifier(appId)`
then `.Show(ToastNotification)`. `[MS-toast-manager]` "CreateToastNotifier(appID)".
For a desktop app, "the app must have a shortcut on the Start screen" and "the shortcut
must have an AppUserModelID" `[MS-toast-manager]` Remarks. The no-argument overload is
not for desktop apps (same page). Desktop apps cannot schedule toasts (same page).
AUMID is set on the shortcut's `System.AppUserModel.ID` property `[MS-appids]`.
Toast XML: `ToastNotificationManager.GetTemplateContent(...)` (not fetched `(UNVERIFIED)`).

**Observe others.** `Windows.UI.Notifications.Management.UserNotificationListener`
`[MS-listener]`:

* `UserNotificationListener.Current` (static).
* `RequestAccessAsync()` returns `UserNotificationListenerAccessStatus`
  (Unspecified 0, Allowed 1, Denied 2 `[MS-listener-status]`); "must call
  RequestAccessAsync from a UI-thread" (class remarks).
* `GetNotificationsAsync(NotificationKinds)` returns `IVectorView<UserNotification>`;
  `GetNotification(UInt32)`, `RemoveNotification(UInt32)`, `ClearNotifications()`,
  `GetAccessStatus()`; event `NotificationChanged` (added or removed).
* The class is `Threading(MTA)` `[MS-listener]` header.
* The notification-listener page says: "To use the notification listener, you must
  add the User Notification Listener capability to your app manifest" `[MS-listener-guide]`.

Packaged-app requirement: the capability lives in the app manifest, which implies a
package identity. Whether an unpackaged desktop app can call it `(UNVERIFIED)`;
treat as "packaged only" for planning.

**Windows-rs bindings** (`windows` 0.62.2, feature `UI_Notifications_Management`
which implies `UI_Notifications`): `IUserNotificationListener` IID
`62553e41-8a06-4cef-8215-6033a5be4b03`; statics
`IUserNotificationListenerStatics` IID `ff6123cf-4386-4aa3-b73d-b804e5b63b23`
`[read: windows-rs src/Windows/UI/Notifications/Management/mod.rs lines 1, 18]`.

**Replacing the Action Center.** No public API. We cannot suppress toasts from
other apps.

**Permissions.** Listener access prompt (user consent) and the manifest
capability. Toast sending: none beyond the AUMID shortcut.

## 3. Reference implementations (prove it works)

| project | language | file (URL or crate path) | what to copy | read status |
| --- | --- | --- | --- | --- |
| dunst | C (GDBus) | `raw.githubusercontent.com/dunst-project/dunst/master/src/dbus.c` | full server: hint parsing, stack tags, capability list, closed reasons, history control interface | [read] dbus.c (sections read: interface XML, hints, GetCapabilities, closed signal) |
| Astal notifd | Vala | `raw.githubusercontent.com/Aylur/astal/main/lib/notifd/src/daemon.vala`, `proxy.vala`, `notification.vala`, `notifd.vala` | daemon vs proxy ownership pattern, image cache, expiry, `dont-disturb` flag | [read] all four |
| notify-rust 4.11.7 | Rust (client; stub server) | crate `src/image.rs`, `src/server.rs`, `src/hints/constants.rs`, `src/notification.rs` | image tuple and hint names as clients see them. Server is a stub (empty GetCapabilities, no-op CloseNotification) and must not be copied | [read] image, server, constants |
| KDE KStatusNotifierItem | C++ | `KSNI-src` `src/org.freedesktop.Notifications.xml` | KDE extensions (NotificationReplied, Inhibit) | [read] XML |
| xdg-desktop-portal Notification docs | docs | `PORTAL-notif` | sandboxed notification API v2 | [read] docs |
| freedesktop notification spec | spec | `NOTIF-1.3` | the normative text | [read] full |
| mako | C | `github.com/emersion/mako` | the reference C daemon the brief names | [not reached] (GitHub blocked; raw path guesses 404) |
| swaync, fnott | C / Rust | GitHub | further daemon examples | [not reached] |
| DankMaterialShell core notifications | Go | `raw.githubusercontent.com/AvengeMedia/DankMaterialShell/master/` | not located (README only) | [README] |
| Quickshell Services.Notifications | C++ | docs at `quickshell.org/docs/v0.2.0/types/Quickshell.Services.Notifications/` | API shape only | [not read] (page exists, not fetched in full) |
| Microsoft UserNotificationListener | docs | `MS-listener*` | Windows observer API | [read] |
| Apple UserNotifications | docs | `APPLE-JSON` usernotifications_*.json | macOS sender API | [read] |

## 4. Double validation

| claim | source A | source B | status |
| --- | --- | --- | --- |
| Notify signature `susssasa{sv}i` returns `u` | `NOTIF-1.3` | dunst `dbus.c` `dbus_message_to_notification` requires `(susssasa{sv}i)` | confirmed |
| CloseNotification emits NotificationClosed reason 3 | `NOTIF-1.3` | Astal `close_notification` resolves with `ClosedReason.CLOSED` | Astal `enums.vala` lines 7-11: EXPIRED=1, DISMISSED_BY_USER=2, CLOSED=3, UNDEFINED=4 | confirmed |
| Reason 1 expired, 2 dismissed, 4 undefined | `NOTIF-1.3` | dunst reason strings `time`, `user`, `signal` (dbus.c 1143-1152) | confirmed |
| `image-data` (iiibiiay), 8 bits, channels 3/4 | `NOTIF-1.3` | notify-rust `image.rs` (`from_raw_data` with `bits_per_sample=8`, channels from alpha) | confirmed |
| `expire_timeout` -1 server default, 0 never | `NOTIF-1.3` | Astal `Notify` (`expire_timeout < 0` -> default setting) | confirmed |
| Critical must not auto-expire | `NOTIF-1.3` urgency text | Astal does not special-case critical `(read)`: a gap in Astal | confirmed by spec; reference deviates |
| `GetServerInformation` spec_version | `NOTIF-1.3` | dunst returns "1.2", Astal returns "1.2" | observed: both reference daemons advertise 1.2 |
| `value` progress hint | dunst dbus.c 785-792 | not in NOTIF-1.3 | (single-source: dunst) |
| `x-canonical-private-synchronous` stack tag | dunst dbus.c 150 | not in NOTIF-1.3 | (single-source: dunst) |
| dunst does not emit ActivationToken | dunst dbus.c (grep: no emission) | NOTIF-1.3 defines the signal | confirmed by absence in the read file `(single-source: one file)` |
| Portal v2 AddNotification / RemoveNotification / ActionInvoked | `PORTAL-notif` | none | (single-source: portal docs) |
| UserNotificationCenter returns only own notifications | `APPLE-JSON` getDeliveredNotifications wording | none | (single-source: Apple) |
| Listener needs User Notification Listener capability | `MS-listener-guide` | none | (single-source: Microsoft) |
| Listener RequestAccessAsync from UI thread | `MS-listener` class remarks | none | (single-source: Microsoft) |
| Desktop toast needs Start-menu shortcut with AUMID | `MS-toast-manager` Remarks | `MS-appids` | confirmed |

## 5. Proposed Bleu model

Draft only; not compiled. Server-side state plus the client-side send and observe
types. Ids are `NoteId` (`uint`, never 0). Closed reasons match the spec's numbers.

```c3
module bleu::notify;
import bleu::error, bleu::availability;

typedef NoteId = uint;          // u32 from NOTIF-1.3; 0 is never a valid id

enum Urgency : char { LOW, NORMAL, CRITICAL }   // spec 0, 1, 2 (dunst/astal store as byte)
enum Markup : char { NONE, SUBSET }             // body is plain or spec subset (b, i, u, a, img)

constset CloseReason : uint {                   // spec numbers, not ordinals
    EXPIRED = 1,
    DISMISSED = 2,
    CLOSED_BY_CALL = 3,
    UNDEFINED = 4,
}

struct Action {
    String key;                 // "default" is the click action
    String label;
}

struct Image {                  // image-data (iiibiiay), already converted; pixels owned by snapshot
    int width;
    int height;
    int rowstride;
    bool has_alpha;
    int channels;               // 3 or 4
    ubyte[] pixels;             // RGB or RGBA, row-major
}

struct Notification {
    NoteId id;
    String app_name;
    String desktop_entry;       // "" when unknown
    String category;            // "" when unknown
    String summary;
    String body;
    Markup markup;
    Urgency urgency;
    Action[] actions;
    String app_icon;            // theme name or file URI, "" when absent
    String image_path;          // "" when absent
    bool has_image;
    Image image;                // valid when has_image
    bool has_progress;
    int progress;               // 0..100, valid when has_progress
    String stack_tag;           // "" when absent
    bool resident;
    bool transient;
    bool suppress_sound;
    bool has_expiry;            // false means server default
    Duration expire_after;      // 0 = never, valid when has_expiry
}

struct State {                  // Snapshot payload; Observable{State}
    Notification[] active;      // on screen or queued
    Notification[] history;     // kept for the notification centre list
    bool do_not_disturb;
}

enum Cap : char {               // ARCHITECTURE rule 5
    ACTIONS, BODY_MARKUP, BODY_IMAGES, IMAGE_DATA, PERSISTENCE, SOUND,
    ACTIVATION_TOKEN, PROGRESS, STACK_TAG, INLINE_REPLY, SEND, OBSERVE,
}

enum Kind : char { RECEIVED, CLOSED, INVOKED, TOKEN, REPLIED }

struct Event {                  // Stream{Event}: transients
    Kind kind;
    NoteId id;
    CloseReason reason;         // valid for CLOSED
    String action_key;          // valid for INVOKED
    String token;               // valid for TOKEN
    String text;                // valid for REPLIED
}

struct Options {
    String backend;             // "" = probe; forced name otherwise
}

// Backend priority (ARCHITECTURE rule 7)
//   linux:   fdo_server (1: we own org.freedesktop.Notifications); fdo_observer (2: BecomeMonitor, UNVERIFIED policy)
//   darwin:  un_send (1: UserNotifications, send only); private_db (2, quarantined, UNVERIFIED)
//   windows: toast_send (1, needs AUMID shortcut); listener (2: packaged, consent)
// Availability: SEND on all; ACTIONS on fdo_server only if the shell renders actions;
// OBSERVE on darwin is UNSUPPORTED_BACKEND (no public API); on windows PERMISSION_NEEDED until consent.
```

## 6. Risks and cut lines

Hard:

* **We cannot be the daemon and the notification renderer at once without
  owning the bus name.** If another daemon owns `org.freedesktop.Notifications`,
  our server cannot start; the honest result is `BACKEND_MISSING` with the
  owner name. Replacing the user's daemon is a product decision, not a library one.
* **Spec and de-facto disagree.** `value`, stack tags, `x-canonical-private-synchronous`,
  KDE's `NotificationReplied` and `Inhibit` are outside NOTIF-1.3. Implement the
  spec first; add the de-facto ones behind Caps.
* **Reason after action** is undefined in the spec (section 2.1).
* **Activation tokens** on Wayland need compositor cooperation (UNVERIFIED).
* **macOS** cannot observe others and cannot suppress system banners; the private
  store is unstable and FDA-gated (UNVERIFIED).
* **Windows listener** is probably packaged-only (UNVERIFIED); toasts need an
  AUMID shortcut for desktop apps; scheduling is not available to desktop apps.

Cannot be done without private API or admin rights: suppress other apps'
notifications on macOS or Windows; read the macOS notification store without FDA;
become the Windows listener without packaging.

Recommended first version (cut line):

1. Linux: `fdo_server` with the full core method and signal set (section 2.1), hints
   `urgency`, `category`, `desktop-entry`, `image-data`, `image-path`, `resident`,
   `transient`, `suppress-sound`, `value`, one stack-tag hint, actions, markup
   (`b`, `i`, `u`, `a`), expiry rules, replace, `CloseNotification`, reasons 1-3.
   `ActivationToken` behind a Cap until a token source is proven.
2. Send: Linux client (`Notify`), Windows toasts (AUMID), macOS UserNotifications.
3. Leave out for v1: history UI backing (state exists, UI later), portal backend,
   KDE `NotificationReplied`/`Inhibit`, observing other servers on Linux
   (BecomeMonitor), all Windows listener work, all macOS private store work.

---

# tray

Be the system-tray host (show other apps' tray items on Linux), publish our own
icon (cut line), and show the menus. No host exists on macOS or Windows, so
those platforms get publish-only.

## 1. What a shell needs

Priority order:

1. **Item list.** Each item: stable id (bus name + path), `Id`, `Title`,
   `Category`, `Status` (Passive, Active, NeedsAttention), `ItemIsMenu`.
2. **Icon.** `IconName` (theme lookup, with `IconThemePath`) or `IconPixmap`
   (ARGB32, network order) when no name; `AttentionIconName`/`AttentionIconPixmap`
   when NeedsAttention; `OverlayIconName`/`OverlayIconPixmap`.
3. **Tooltip.** `ToolTip (sa(iiay)ss)`: icon name, icon data, title, description
   (small markup subset).
4. **Activation.** Left click: `Activate(x,y)`, or `ContextMenu(x,y)` when
   `ItemIsMenu`. Middle: `SecondaryActivate(x,y)`. Right: `ContextMenu(x,y)`.
   Wheel: `Scroll(delta, orientation)`.
5. **Menu.** The DBusMenu tree from `Menu` path: `GetLayout`, `AboutToShow` before
   showing a submenu, `Event` for `clicked` and `hovered`/`opened`/`closed`, and
   reacting to `LayoutUpdated` and `ItemsPropertiesUpdated`.
6. **Live updates.** `NewTitle`, `NewIcon`, `NewAttentionIcon`, `NewOverlayIcon`,
   `NewToolTip`, `NewStatus`, `NewMenu` (KDE) `[SNI-xml]` and `[KSNI-src]`.
7. **Lifecycle.** Items appear and disappear; a restarting watcher re-announces
   items.
8. **Publish our own icon (cut line).** Show our app's tray icon and menu on Linux
   (SNI export) and on Windows (`Shell_NotifyIconW`) and macOS (`NSStatusItem`).
9. **XEmbed fallback (cut line).** Old X11 `_NET_SYSTEM_TRAY_S<n>` `[xdg-specs systemtray-spec.xml v0.3]`.

## 2. Per-platform native route (Linux / macOS / Windows)

### 2.1 Linux: StatusNotifier host (route 1)

**Watcher.** Bus name `org.kde.StatusNotifierWatcher`, object `/StatusNotifierWatcher`
(KDE and every reference implementation read here use this name). The freedesktop
wiki names `org.freedesktop.StatusNotifierWatcher` `[SNI-wiki]` `StatusNotifierWatcher`
page. Conflict recorded in section 4. Interface `org.kde.StatusNotifierWatcher`
`[KSNI-src]` `org.kde.StatusNotifierWatcher.xml`:

* methods `RegisterStatusNotifierItem(s service)`, `RegisterStatusNotifierHost(s service)`;
* properties `RegisteredStatusNotifierItems as` (ro), `IsStatusNotifierHostRegistered b` (ro),
  `ProtocolVersion i` (ro, 0);
* signals `StatusNotifierItemRegistered(s)`, `StatusNotifierItemUnregistered(s)`,
  `StatusNotifierHostRegistered()`, `StatusNotifierHostUnregistered()`.

Item strings in `RegisteredStatusNotifierItems` are the bus name followed by the
object path with no separator: `":1.72/org/ayatana/NotificationItem/x"` or
`":1.58/StatusNotifierItem"`. Split at the first `/` `[read: system-tray
client.rs parse_address and status_notifier_watcher.rs format!("{service}{objpath}")]`.

**Ownership pattern (what references do).**

* system-tray: serves the watcher itself if it can (`request_name_with_flags` with no
  flags); on `NameTaken` it defers to the existing watcher `[read: status_notifier_watcher.rs
  attach_to, lines 245-262]`. It then registers as a host under a generated name
  `org.freedesktop.StatusNotifierHost-<pid>-<n>` with `DoNotQueue` `[read: client.rs
  lines 160-185]` and calls `RegisterStatusNotifierHost`.
* Waybar: owns the name with `ALLOW_REPLACEMENT | REPLACE`, so it takes over from another
  watcher `[read: src/modules/sni/watcher.cpp lines 10-15]`.
* KDE item side: checks `ProtocolVersion` on the watcher before registering
  `[read: KSNI-src kstatusnotifieritem.cpp lines 915-937]`.
* Quickshell: registers the watcher name; if it is taken, watches it and retries when
  it goes away `[read: quickshell-mirror status_notifier/watcher.cpp lines 46-73]`.

Recommendation: try to own the watcher name; if owned, act as host only; re-register
on `NameOwnerChanged` of the watcher name; on watcher loss, clear and rebuild.

**Host registration.** `RegisterStatusNotifierHost(s)` with a unique well-known
name `org.kde.StatusNotifierHost-<pid>-<n>` or `org.freedesktop.StatusNotifierHost-…`.
The spec describes `org.freedesktop.StatusNotifierHost-id` `[SNI-wiki]` StatusNotifierHost.
Use the name the watcher accepts (the references use `freedesktop` for host and
`kde` for the watcher).

**Item properties.** Interface on the item is `org.kde.StatusNotifierItem` (KDE
and system-tray `PROPERTIES_INTERFACE`) `[read: system-tray client.rs line 83]`;
the freedesktop spec text names `org.freedesktop.StatusNotifierItem`. Read the KDE
name and fall back to the freedesktop name. Properties (`[KSNI-src]`
`org.kde.StatusNotifierItem.xml`, same as `[SNI-xml]`):

| property | type | notes |
| --- | --- | --- |
| `Category` | `s` | ApplicationStatus, Communications, SystemServices, Hardware |
| `Id` | `s` | stable id per app |
| `Title` | `s` | |
| `Status` | `s` | Passive, Active, NeedsAttention |
| `WindowId` | `i` (KDE, system-tray) / `u` (spec wiki) | conflict, section 4 |
| `IconThemePath` | `s` | extra theme dir |
| `Menu` | `o` | DBusMenu object path; `"/NO_DBUSMENU"` is used by some items (Quickshell check `[read: quickshell item.cpp line 109]`) |
| `ItemIsMenu` | `b` | prefer menu on activation |
| `IconName` | `s` | |
| `IconPixmap` | `a(iiay)` | ARGB32, network order |
| `OverlayIconName`, `OverlayIconPixmap` | `s`, `a(iiay)` | |
| `AttentionIconName`, `AttentionIconPixmap`, `AttentionMovieName` | `s`, `a(iiay)`, `s` | |
| `ToolTip` | `(sa(iiay)ss)` | icon name, icon data, title, description (markup subset) |

Methods on the item: `Activate(i x, i y)`, `SecondaryActivate(i x, i y)`,
`ContextMenu(i x, i y)`, `Scroll(i delta, s orientation)`, KDE adds
`ProvideXdgActivationToken(s token)` `[KSNI-src]` `org.kde.StatusNotifierItem.xml`
line 52. Signals: `NewTitle`, `NewIcon`, `NewAttentionIcon`, `NewOverlayIcon`,
`NewToolTip`, `NewStatus(s status)`, KDE `NewMenu`.

Scroll orientation: freedesktop lower-case `horizontal|vertical`; ksni's comment
says KDE uses `Horizontal|Vertical` `[read: ksni tray.rs lines 6-7]`. Send lower-case;
accept both when reading back (not needed for the spec).

**Icon conversion (`a(iiay)` to pixels).** Each struct is `(width i, height i, data ay)`,
data is `width*height*4` bytes, ARGB32, network byte order: byte 0 alpha, 1 red,
2 green, 3 blue (`SNI-xml`). Waybar's conversion: copy with
`alpha=src[i], rgba = src[i+1..i+3], alpha last` `[read: waybar item.cpp lines 421-431]`
and picks the largest pixmap whose `size == 4*w*h` `[read lines 410-419]`. KDE builds
the same bytes by `qToBigEndian` on each 32-bit word `[read KSNI-src kstatusnotifieritem.cpp
lines 1209-1229]`. Two sources agree.

**DBusMenu (`com.canonical.dbusmenu` at the item's `Menu` path, same bus name).**
Interface XML (three copies agree; `[DBUSMENU-ksni]`, `[DBUSMENU-KDE]`):

| member | signature | notes |
| --- | --- | --- |
| `GetLayout` | in `i parentId, i recursionDepth, as propertyNames` -> out `u revision, (ia{sv}av) layout` | root id 0; depth -1 all, 0 none, n levels; empty names = all properties |
| `GetGroupProperties` | in `ai ids, as propertyNames` -> out `a(ia{sv}) properties` | |
| `GetProperty` | in `i id, s name` -> out `v value` | debugging |
| `Event` | in `i id, s eventId, v data, u timestamp` | `clicked`, `hovered`, `opened`, `closed`; vendor `x-<vendor>-` |
| `EventGroup` | a(isvu) | batch |
| `AboutToShow` | in `i id` -> out `b needUpdate` | call before showing a submenu; if true, re-read layout |
| `AboutToShowGroup` | batch | |
| signal `ItemsPropertiesUpdated` | `a(ia{sv}) updatedProps, a(ias) removedProps` | |
| signal `LayoutUpdated` | `u revision, i parent` | re-read layout |
| signal `ItemActivationRequested` | `i id, u timestamp` | |
| property `Version u`, `TextDirection s` (`ltr`/`rtl`), `Status s` (`normal`/`notice`), `IconThemePath as` | | |

Menu item properties (`[DBUSMENU-ksni]` dox table): `type` (`standard`, `separator`,
`x-…`), `label` (`__` displays `_`; a single `_` is a mnemonic marker and is not
shown), `enabled`, `visible`, `icon-name`, `icon-data` (PNG bytes), `shortcut`
(`aas`), `toggle-type` (`""`, `checkmark`, `radio`), `toggle-state` (`-1` default,
`0` off, `1` on, else indeterminate), `children-display` (`submenu`), `disposition`
(`normal`, `informative`, `warning`, `alert`).

**Call sequence (host, happy path):**

1. Connect to the session bus; try to own `org.kde.StatusNotifierWatcher`; if owned
   by another watcher, continue as host only.
2. Export `/StatusNotifierWatcher` if we own it (serve the interface above).
3. Own `org.freedesktop.StatusNotifierHost-<pid>-<n>` (or `kde` name); call
   `RegisterStatusNotifierHost`.
4. `RegisteredStatusNotifierItems` (initial); for each: split bus/path; `GetAll(org.kde.StatusNotifierItem)`;
   subscribe `PropertiesChanged`-less signals on the item path (`NewIcon` etc.) by
   member match with `sender=<bus>`, `path=<path>`.
5. If `Menu != ""`: `GetLayout(0, -1 or 10, [])`; subscribe `LayoutUpdated` and
   `ItemsPropertiesUpdated` on the menu path.
6. On `StatusNotifierItemRegistered`/`Unregistered`: add/remove items.
7. Activation: `Activate`/`SecondaryActivate`/`ContextMenu`/`Scroll` with screen
   coordinates (x,y) as hints; never block the UI thread on the reply (system-tray
   uses a 1 s timeout `[read client.rs activate]`).
8. Menu click: `Event(id, "clicked", variant int32 0, timestamp)` (system-tray does
   exactly this `[read client.rs]`). Use `NO_REPLY_EXPECTED` if available; KDE's
   exporter handles `clicked` asynchronously because dbusmenu-glib blocks on Event
   `[read dbusmenuexporterdbus_p.cpp lines 43-60]`.
9. Watcher loss: clear items; when a watcher reappears, re-read
   `RegisteredStatusNotifierItems` (system-tray clears on `NameAcquired` of the
   watcher name `[read client.rs]`).

**Activation semantics (what Waybar and ksni do).**

* Left click on an `ItemIsMenu` item, or right click: open menu (ours) if the layout
  exists, else call `ContextMenu` `[read waybar item.cpp handleClick lines 624-655]`.
  Waybar also falls back to `ContextMenu` when `Menu` exists but serves no layout
  (for example Steam) `[read lines 630-636]`.
* ksni comment: GNOME's appindicator extension only treats `ItemIsMenu` correctly
  if `Activate` returns `UnknownMethod`; ksni does that `[read ksni dbus_interface.rs
  lines 70-80]`.

**Publishing our own icon (cut line).** Own `org.kde.StatusNotifierItem-<pid>-<n>`,
export `/StatusNotifierItem` (interface above) and `/MenuBar` (ksni `MENU_PATH`),
then `RegisterStatusNotifierItem(<bus name>)` with the bus name (not path; KDE
registers the bus name only `[read KSNI-src kstatusnotifieritem.cpp lines 934]`).
Serve `com.canonical.dbusmenu` at `/MenuBar` with `GetLayout` returning `revision`,
bumped on each change, and `LayoutUpdated` emitted with a 0 ms coalescing timer
(KDE exporter `[read libdbusmenu-qt/dbusmenuexporter.cpp lines 186-219, 430-451]`).
References: ksni 0.3.1 (`src/service.rs`, `src/dbus_interface.rs`, `src/menu.rs`
989 lines, not read in full) and KDE exporter (read in part).

**XEmbed (cut line).** X11 only, `_NET_SYSTEM_TRAY_OPCODE`, `SYSTEM_TRAY_REQUEST_DOCK = 0`
`[xdg-specs systemtray-spec.xml]`. Not needed on Wayland.

### 2.2 macOS: no tray host; our own NSStatusItem; others' menu-bar extras via AX (private-ish)

**Own icon (public).** `NSStatusItem`: "An individual element displayed in the
system menu bar" `[APPLE-JSON]` appkit/nsstatusitem.json (macOS platform). Create via
`NSStatusBar.system.statusItem(withLength:)` `(UNVERIFIED: selector not in the fetched
abstract; known API)`.

**Others' menu-bar extras (Accessibility).** Apple's accessibility attribute
`kAXExtrasMenuBarAttribute` is a `String` constant, macOS 10.8+ `[APPLE-JSON]`
applicationservices/kaxextrasmenubarattribute.json. The route: get the pid of the
owner process (`SystemUIServer`, `ControlCenter` on newer systems, `UNVERIFIED`
which process owns which items on macOS 26), `AXUIElementCreateApplication(pid)`,
`AXUIElementCopyAttributeValue(app, kAXExtrasMenuBarAttribute, ...)`, then children
(`AXMenuBarItem`/`AXMenuBar`) and `AXPress` to activate `(UNVERIFIED: attribute and
action names not fetched)`.

Permission: Accessibility (TCC). `AXIsProcessTrustedWithOptions` with
`kAXTrustedCheckOptionPrompt` `[APPLE-JSON]` applicationservices/kaxtrustedcheckoptionprompt.json
(macOS 10.9+). Precise AX function reference pages returned 404 on the HTML route
and were not reached through the JSON route `[not reached]`.

Prior art: Ice (menu bar manager) requires macOS 14+ and "uses a number of system
APIs" `[README]` jordanbaird/Ice; which APIs is not stated. Not read further.

### 2.3 Windows: no host API; own icon via Shell_NotifyIconW; others via UI Automation (UNVERIFIED)

**Own icon (public).** `Shell_NotifyIconW(dwMessage, PNOTIFYICONDATAW)`
`[MS-shellapi-nim]`: `NIM_ADD` (0), `NIM_MODIFY` (1), `NIM_DELETE` (2), `NIM_SETVERSION`
(4). `NIM_SETVERSION` must follow every `NIM_ADD`; the version is not persisted
across logoff. Version 4 (`NOTIFYICON_VERSION_4`) changes the callback: `LOWORD(lParam)`
is the event (`NIN_SELECT`, `NIN_POPUPOPEN`, `WM_CONTEXTMENU`, ...),
`HIWORD(lParam)` is the icon id, `GET_X_LPARAM(wParam)`/`GET_Y_LPARAM(wParam)` are
anchor coordinates `[MS-shellapi-nim]` and `[MS-notifyicondataw]`. `NOTIFYICONDATAW`
fields used: `cbSize`, `hWnd`, `uID`, `uFlags` (`NIF_MESSAGE` 1, `NIF_ICON` 2,
`NIF_TIP` 4, `NIF_INFO` 0x10, `NIF_GUID` 0x20, `NIF_SHOWTIP` 0x80), `uCallbackMessage`,
`hIcon`, `szTip[128]` (Windows 2000+), `guidItem`, `uVersion`, `szInfo`,
`szInfoTitle`, `dwInfoFlags`, `hBalloonIcon` `[MS-notifyicondataw]`.
`NIF_GUID` (Windows 7+) identifies the icon; once used, keep using the GUID
`[MS-notifyicondataw]` remark.

Taskbar restart: when Explorer restarts, the application must re-add its icons.
`tray-icon` 0.21.0 registers `RegisterWindowMessageA("TaskbarCreated")` and re-adds
on that message `[read tray-icon src/platform_impl/windows/mod.rs lines 48-51, 334]`.
The Microsoft pages fetched did not contain the string `TaskbarCreated`
`(single-source: tray-icon)`.

**Others' tray icons (no public API).** The brief's two candidates:

* UI Automation on `Shell_TrayWnd` and `NotifyIconOverflowWindow` (the overflow area)
  `(UNVERIFIED: element tree, control types and whether Windows 11 exposes all items;
  not read)`.
* The `TrayNotify` registry state under `HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\TrayNotify`
  `(UNVERIFIED: value names and binary layout not verified here; undocumented)`.

Recommendation: do not build a Windows host in v1. If later needed, UI Automation is
the less fragile of the two, and it gives no icon pixels reliably.

### 2.4 Summary for tray

| platform | host (show others) | publish own icon |
| --- | --- | --- |
| Linux | SNI watcher + host (public D-Bus spec, de facto KDE names) | SNI item + dbusmenu export |
| macOS | none (AX route private-ish; permission heavy) | `NSStatusItem` |
| Windows | none (UIA / TrayNotify undocumented) | `Shell_NotifyIconW` v4 |

## 3. Reference implementations (prove it works)

| project | language | file (URL or crate path) | what to copy | read status |
| --- | --- | --- | --- | --- |
| system-tray 0.8.0 | Rust (client/host) | crate `src/client.rs`, `src/item.rs`, `src/menu.rs`, `src/dbus/status_notifier_watcher.rs`, `src/dbus/dbus_menu_proxy.rs`, `src/data.rs` | full host flow: watcher serving, item lifecycle, menu fetch and diff, activation | [read] client.rs, item.rs (parts), watcher.rs (parts), dbus_menu_proxy.rs, menu.rs (parts). Defects in section 6 |
| ksni 0.3.1 | Rust (publisher) | crate `spec/StatusNotifierItem.xml`, `spec/StatusNotifierWatcher.xml`, `spec/DBusMenu.xml`, `src/dbus_interface.rs`, `src/tray.rs`, `src/service.rs`, `src/menu.rs` | item and menu publishing, `UnknownMethod` trick for GNOME, icon struct | [read] XML, dbus_interface.rs (parts), tray.rs (parts), service.rs (grep); menu.rs not read in full |
| KDE KStatusNotifierItem + libdbusmenu-qt | C++ (publisher) | `KSNI-src` `src/kstatusnotifieritem.cpp`, `src/kstatusnotifieritemdbus_p.cpp`, `src/org.kde.StatusNotifierItem.xml`, `src/libdbusmenu-qt/dbusmenuexporter*.cpp`, `com.canonical.dbusmenu.xml` | the reference publisher and DBusMenu exporter; icon serialization | [read] registration, imageToStruct, exporter Event/AboutToShow/LayoutUpdated (parts) |
| Waybar `modules/sni` | C++ (host) | `raw.githubusercontent.com/Alexays/Waybar/master/src/modules/sni/item.cpp`, `watcher.cpp`, `tray.cpp` | watcher takeover, Electron combined-name fix, icon conversion, click mapping | [read] item.cpp (activation, icon), watcher.cpp (registration), tray.cpp (partial) |
| Quickshell `Services.SystemTray` | C++ (host) | `raw.githubusercontent.com/quickshell-mirror/quickshell/master/src/services/status_notifier/item.cpp`, `watcher.cpp`, `item.hpp`, `host.cpp` | watcher takeover retry, `NO_DBUSMENU` sentinel, `Scroll` names | [read] item.cpp (parts), watcher.cpp (parts); host.cpp not read |
| Astal tray | Vala (host) | `raw.githubusercontent.com/Aylur/astal/main/lib/tray/src/tray.vala`, `tray-item.vala`, `watcher.vala` | host with libdbusmenu importer (`DBusMenu.Importer`), `is_menu` default | [read] tray.vala (parts), tray-item.vala (parts); watcher.vala not read |
| tray-icon 0.21.0 | Rust (Windows publisher) | crate `src/platform_impl/windows/mod.rs` | legacy `Shell_NotifyIconW` usage, TaskbarCreated | [read] parts |
| freedesktop StatusNotifierItem spec | spec | `SNI-xml`, `SNI-wiki` | normative text | [read] |
| freedesktop systemtray (XEmbed) spec | spec | xdg-specs `systemtray/systemtray-spec.xml` | cut line only | [read] header and dock opcode |
| Electron (≥ 43.4.1) | n/a | not read | item registration form | [not reached]: only Waybar's comment |
| GNOME appindicator extension | JS | not reached | GNOME behaviour | [not reached] (ksni comment only) |
| DankMaterialShell | Go/QML | README only | | [README] |
| Ice (macOS) | Swift | README | menu-bar management scope | [README] |
| windows-rs 0.62.2 | Rust bindings | not used for tray | | |

## 4. Double validation

| claim | source A | source B | status |
| --- | --- | --- | --- |
| Watcher name `org.kde.StatusNotifierWatcher`, path `/StatusNotifierWatcher` | `KSNI-src` `org.kde.StatusNotifierWatcher.xml` | system-tray `lib.rs` line 47-48; ksni `dbus_interface.rs` lines 16-18; Waybar `watcher.cpp` line 11; Quickshell `watcher.cpp` line 56 | confirmed (de facto) |
| Watcher name `org.freedesktop.StatusNotifierWatcher` | `SNI-wiki` StatusNotifierWatcher text | none of the references serves it | conflict: wiki vs practice; claim KDE name, optionally also serve the freedesktop alias (UNVERIFIED that clients need it) |
| Host registration method `RegisterStatusNotifierHost(s)` | `SNI-wiki` | system-tray client.rs line ~180; KDE XML | confirmed |
| Items registered as `bus` + `path` concatenated | system-tray `format!("{service}{objpath}")` | Waybar `watcher.cpp` line 120 `%s%s` | confirmed |
| Electron ≥ 43.4.1 passes `bus/path` in one argument | Waybar `watcher.cpp` lines 99-102 (comment) | none | (single-source: Waybar); system-tray `parse_service` handles only a leading `/` `(UNVERIFIED by running)` |
| `IconPixmap` is `a(iiay)` ARGB32 network order | `SNI-xml` | KDE `imageToStruct` (qToBigEndian), Waybar `item.cpp` 421-431 | confirmed |
| `WindowId` is `u` | `SNI-wiki` | KDE XML says `i`; system-tray and ksni use `i32` | conflict; read as `i` |
| Scroll orientation lower-case | `SNI-xml` / `SNI-wiki` | ksni `tray.rs` comment says KDE is capitalised | conflict; send lower-case |
| `DBusMenu.GetLayout` `(ia{sv}av)` with revision `u` | `DBUSMENU-ksni` | `DBUSMENU-KDE`; system-tray `dbus_menu_proxy.rs` `get_layout` | confirmed (three copies) |
| `Event` signature `i s v u` | `DBUSMENU-ksni` | `DBUSMENU-KDE`; system-tray proxy `event(id, &str, &Value, u32)` | confirmed |
| `AboutToShow(i) -> b` | `DBUSMENU-ksni` | `DBUSMENU-KDE`; system-tray proxy | confirmed |
| `LayoutUpdated(u revision, i parent)` | `DBUSMENU-KDE` | system-tray `layout_updated(revision, parent)` | confirmed |
| `ItemsPropertiesUpdated(a(ia{sv}), a(ias))` | `DBUSMENU-KDE` | system-tray proxy `items_properties_updated` | confirmed |
| `label` underscore rule: `__` shows `_`; single `_` mnemonic | `DBUSMENU-ksni` dox | system-tray `menu.rs` line 247 `replace('_', "")` removes all underscores | conflict: system-tray is wrong for `__` `(read)` |
| NIM_SETVERSION 4 event encoding | `MS-shellapi-nim` | `MS-notifyicondataw` (same text) | confirmed |
| `tray-icon` uses legacy callback (no NIM_SETVERSION) | `tray-icon` source (no `NIM_SETVERSION` in grep) | | confirmed for 0.21.0 |
| `TaskbarCreated` re-add needed | `tray-icon` source (lines 48-51, 334) | Microsoft pages fetched did not contain the string | (single-source: tray-icon) |
| `kAXExtrasMenuBarAttribute` | `APPLE-JSON` | none | (single-source: Apple) |
| macOS: no public host API for others' menu-bar extras | `APPLE-JSON` (none listed) | Ice README needing system APIs | (single-source: absence in docs) |

## 5. Proposed Bleu model

Draft only; not compiled. The host is a Linux backend of `bleu::tray`; the model
is platform-neutral. Strings for ids and paths are `String`. Pixmaps are owned by
the snapshot.

```c3
module bleu::tray;
import bleu::error, bleu::availability;

enum Category : char { APPLICATION, COMMUNICATIONS, SYSTEM_SERVICES, HARDWARE }
enum Status : char { PASSIVE, ACTIVE, NEEDS_ATTENTION }          // "Unknown" maps to PASSIVE and a flag

struct Pixmap {                 // a(iiay) element, ARGB32, converted to RGBA by the backend
    int width;
    int height;
    ubyte[] pixels;             // width * height * 4
}

struct Tooltip {
    String icon_name;
    Pixmap[] icon_pixmaps;
    String title;
    String description;         // markup subset, caller strips or renders
}

enum Toggle : char { NONE, CHECKMARK, RADIO }
enum ToggleState : char { OFF, ON, INDETERMINATE }   // spec 0, 1, else
enum Disposition : char { NORMAL, INFORMATIVE, WARNING, ALERT }

struct MenuItem {               // flat list with parent index: no recursion in state
    int id;                     // DBusMenu id; 0 is the root
    int parent_id;              // -1 for the root
    bool is_separator;
    String label;               // "__" already converted to "_"; single "_" removed
    bool enabled;
    bool visible;
    String icon_name;
    Pixmap[] icon_pixmaps;      // icon-data is PNG: decoded by the backend or left empty
    Toggle toggle;
    ToggleState toggle_state;
    bool has_submenu;           // children-display == "submenu"
    Disposition disposition;
}

struct Item {
    String id;                  // bus name + "/" + object path, stable for the item's life
    String bus_name;
    String object_path;
    String item_id;             // SNI "Id"
    String title;
    Category category;
    Status status;
    bool item_is_menu;
    String icon_name;
    Pixmap[] icon_pixmaps;
    String attention_icon_name;
    Pixmap[] attention_icon_pixmaps;
    String overlay_icon_name;
    Pixmap[] overlay_icon_pixmaps;
    String icon_theme_path;
    bool has_tooltip;
    Tooltip tooltip;            // valid when has_tooltip
    String menu_path;           // "" when no menu
    uint menu_revision;         // DBusMenu revision of the MenuItem[] below
    MenuItem[] menu;            // flat, root is id 0
}

struct State {                  // Snapshot payload
    Item[] items;
}

enum Cap : char {               // ARCHITECTURE rule 5
    ACTIVATE, SECONDARY_ACTIVATE, CONTEXT_MENU, SCROLL,
    MENU_TREE, MENU_EVENTS, MENU_ABOUT_TO_SHOW,
    ICON_NAME, ICON_PIXMAP, ATTENTION, OVERLAY, TOOLTIP,
    PUBLISH_OWN_ICON, PUBLISH_OWN_MENU,
}

enum MenuEventKind : char { CLICKED, HOVERED, OPENED, CLOSED }

enum Change : char { ITEM_ADDED, ITEM_REMOVED, STATUS, ICON, ATTENTION, OVERLAY, TITLE, TOOLTIP, MENU, MENU_PROPS }

struct Event {
    Change change;
    String item_id;
    int menu_parent_id;         // valid for MENU changes
}

struct Options {
    String backend;             // "" = probe; forced name otherwise
    bool own_watcher_name;      // try to own org.kde.StatusNotifierWatcher
}

// Backend priority (ARCHITECTURE rule 7)
//   linux:   sni_host (1, watcher client + host; takes over the watcher name only when asked)
//   darwin:  none for the host; publish NSStatusItem (own icon)
//   windows: none for the host; publish Shell_NotifyIconW (own icon)
// Availability (examples): HOST on darwin/windows = UNSUPPORTED_OS (no public host API);
// PUBLISH_OWN_ICON on linux = BACKEND_MISSING when no watcher is reachable.
```

Operations: `Activate`, `SecondaryActivate`, `ContextMenu`, `Scroll` return
`Operation{bool}` (accepted by the item). `AboutToShow(item, menu_id)` returns
`Operation{bool}` (needs update). Menu events are fire-and-forget.

## 6. Risks and cut lines

Hard:

* **Watcher name ownership.** Several watchers on one session bus is a
  configuration fight. References disagree: system-tray defers, Waybar takes over,
  Quickshell retries. We must pick and document one.
* **Spec and practice differ** on the watcher name, the item interface name,
  `WindowId` type, and Scroll orientation case. Read what is sent; send what KDE
  expects, and test against KDE and Waybar.
* **GNOME** shows SNI items only through an extension; `ItemIsMenu` semantics need
  the `UnknownMethod` trick `[read ksni]`. The extension is not reached here.
* **Electron's combined `bus/path` registration** `(single-source: Waybar)` breaks
  references that do not split it; ours must accept it.
* **Menus are stateful.** `LayoutUpdated` may arrive before the layout we last read
  is consumed; system-tray re-reads whole layouts with a 1 s timeout and depth 10
  `[read client.rs 492-520]`. Depth 10 truncates deep menus; use -1 or lazy
  `AboutToShow` for submenus.
* **Windows and macOS have no host API.** Listing other apps' tray icons there is
  private or UI-automation-based and unverified.

Bugs found in references (do not copy):

* system-tray 0.8.0 `IconPixmap::from_array` reads `height` from `fields.first()`
  (the width) `[read item.rs lines 168-171]`. Non-square icons come out wrong.
* system-tray 0.8.0 removes every `_` from labels `[read menu.rs line 247]`, which
  breaks the `__` rule.
* system-tray 0.8.0 `WATCHER_BUS` is only `org.kde.StatusNotifierWatcher`; no
  freedesktop alias `[read lib.rs line 47]`.
* system-tray 0.8.0 `parse_service` rejects a `bus/path` argument (only a leading `/`
  is special) `[read status_notifier_watcher.rs lines 299-336]` `(UNVERIFIED by running)`.
* Astal `tray-item.vala` declares `ContexMenu` (misspelled, line 131). It is not
  called in the read file, so the bug is latent.

Recommended first version (cut line):

1. Linux host: watcher client and host registration; items with `Id`, `Title`,
   `Status`, `Category`, `IconName`, `IconPixmap` (largest, ARGB to RGBA),
   `AttentionIcon*`, tooltip; activation (`Activate`, `SecondaryActivate`,
   `ContextMenu`, `Scroll`); DBusMenu `GetLayout` (depth bounded, lazy submenus with
   `AboutToShow`), `Event(clicked)`, `LayoutUpdated` and `ItemsPropertiesUpdated`.
   Accept both `org.kde.*` and `org.freedesktop.*` item interface names on read.
2. Linux publish own icon and menu (SNI export) behind `PUBLISH_OWN_ICON`.
3. Windows and macOS: publish own icon only (`Shell_NotifyIconW` v4; `NSStatusItem`).
4. Leave out: XEmbed, Windows and macOS tray listing (UIA, AX, TrayNotify),
   `ProvideXdgActivationToken`, `NewMenu` (KDE), `EventGroup` and `AboutToShowGroup`
   (use single calls), tooltip markup rendering beyond stripping.

---

## Cross-cutting findings for the lead

* The MPRIS spec as published (`specifications.freedesktop.org/mpris-spec/latest/`)
  is 2.2; the git master in `gitlab.freedesktop.org/mpris/mpris-spec` is 2.3 and adds
  `GetArtworkFd`. Target 2.3 when available, and check for the method at runtime.
* A shared "anchored position" utility (section 2.1 rule) serves media only; do not
  build it into `bleu_core` (ARCHITECTURE: vocabulary stays generic).
* Several private macOS routes (MediaRemote via `/usr/bin/perl`, usernoted store,
  Accessibility menu-bar extras) and Windows `TrayNotify` are UNVERIFIED or
  README-only here. Each needs its own `*_private.c3` with a probe and an OS note,
  and each should be verified on a real machine before a line of C3 depends on it.
* Reference coverage gaps: mako, swaync, fnott, playerctl, Quickshell notifications,
  Astal watcher, DankMaterialShell core, and Electron's registration code were not
  reached. Everything about them above is either absent or marked.
