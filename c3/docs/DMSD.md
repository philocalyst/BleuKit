# dmsd: DankMaterialShell's `core` server on Bleu

`apps/dmsd` is a daemon that answers the DankMaterialShell (DMS) QML shell on the
DMS line-JSON protocol, with the services of Bleu instead of DMS's Go code. The
unmodified shell connects to it. This page is the reference: what is covered, what
is not, how the wire compares with DMS, how to add a module, and what was verified.
The author's notes are in `apps/dmsd/README.md`.

Sources cited below are DMS `core/internal/server/...` at master commit `8be08999`
(a local checkout; the files read were compared byte for byte with
`raw.githubusercontent.com` master). `dms_surface.md` is the inventory, and its pins
(dankgo v1.6.3, DMS `806799614cd5`) were not re-checked against this revision. The Go
struct tags the tests use are in `apps/dmsd/tests/golden/go_tags.json`, regenerated with
`apps/dmsd/tests/extract_go_tags.py <DMS checkout>`.

## Status at a glance

| Part | State |
| --- | --- |
| Socket, handshake, framing, `ping`, `subscribe`, `unsubscribe` | done (bleu_ipc, DMS behaviour) |
| `getServerInfo`, `shell.ready` | done |
| `brightness` module (6 methods, 2 topics) | done, tested on a fake sysfs tree |
| `loginctl` module (11 methods, 1 topic; 4 answer `not supported`) | done, tested against a logind mock |
| `bluetooth` module (15 methods, 2 topics; `mpris.publish` and `subscribe` answer `not supported`) | done, tested against the BlueZ mock of `bleu_bluetooth` and a logind mock |
| `dgop` (sysinfo): `dgop.meta`, `dgop.modules`; `gpu`, `hardware` refused | done, partial: the fields Bleu does not report are zero or empty; tested against `/proc` |
| `clipboard` module (12 methods, 1 topic; 10 refused) | done, compiled only: no Wayland compositor here, so only its absence is run |
| `apps` module: `apppicker.open`, `browser.open`, `mime.*` (2 refused) | done, partial: no mimeinfo.cache, no MIME alias or subclass chains; `browser` not advertised |
| `evdev` (`evdev.getState` refused) | refused: bleu_input has no lock-key state |
| Refused modules: cups, tailscale, wellbeing, sysupdate, wallpaper, files, plugins, themes, registries | every DMS method answers `not supported: <why>`; no capability |
| Every other DMS module (network, bluetooth, audio-adjacent, ...) | not started: the method is `unknown method` until its module lands |

## Running

    dmsd [--socket PATH] [--fake-root DIR] [--module-off NAME]... [--debug]

* Without `--socket` the socket is `$XDG_RUNTIME_DIR/dmsd-<pid>.sock`, as DMS does
  (`dmsd` is the app name; DMS uses `danklinux-<pid>.sock`, so the shell must be told
  the path with `DMS_SOCKET`. See "Differences").
* `--fake-root DIR` reads the brightness sysfs tree under `DIR` and does not use logind.
  It is for tests; it never touches the real `/sys`.
* `--module-off NAME` (repeatable) does not start a module: `brightness`, `loginctl`.
* `--debug` prints what the modules do on stderr. Warnings are always printed.
* SIGINT and SIGTERM stop the daemon: the IPC server stops first, then the modules in
  reverse start order, then everything is freed. Exit status 0.

## Architecture

```
main.c3            args, signals (self-pipe), start modules, serve, stop in reverse order
module.c3          Module contract, Context, StatePump (state -> topic, on its own thread)
capabilities.c3    capability names of the started modules, for the handshake
server_methods.c3  getServerInfo, shell.ready
dms_json.c3        JSON lines (wire.Line), SuccessResult, camelCase names by hand
params.c3          request parameters, read as dankgo's params package reads them
brightness_math.c3 DMS's percent and raw-value formulas (pure, unit-tested)
mod_brightness.c3  brightness module: methods, topics, DMS device list
mod_loginctl.c3    loginctl module: session state, actions, sleep barrier
mod_bluetooth.c3   bluetooth module: methods, state topic, pairing prompts (over bleu_bluetooth)
bluetooth_wire.c3  the bluetooth module's DMS shapes: state, device, adapter, prompt
```

Threads: the IPC layer owns its I/O and handler threads (bleu_ipc). Each service
owns its worker (bleu_service). Each module adds a **StatePump** thread per topic and,
for loginctl, a **barrier** thread that reads power events. Nothing else runs.

### The module contract

```c3
struct Module {
    String name;          // "brightness"
    StartFn start;        // fn bool(Context*, Module*): open the service, register, publish; false = absent
    StopFn stop;          // fn void(Context*, Module*): unwatch, stop pumps, close the service
    String[] topics;      // the topics it publishes
    String[] capabilities;// names advertised when started
    void* state;          // the module's own state, allocated in start, freed in stop
    bool running;
}
```

* `start` registers its methods and topics **before** the server starts, then starts the
  pump. The first publication comes from the service's listener, which runs at once when a
  state already exists.
* A backend that is absent makes `start` return false after one line on stderr
  (`loginctl: not started: <reason>`). The capability is then not advertised. Never fatal.
* Module order is DMS's capability order (`loginctl`, then `brightness`,
  `server.go:429-509`), so the handshake lists them in that order.
* The `Module` descriptor is a `const` global whose slices point at `const` arrays. A
  descriptor built inside a function would hold slices that die with the frame (found by
  test; see the notes in `apps/dmsd/README.md`).

### StatePump: state to topic

A service's listener runs on the service's thread and must be quick, so it only calls
`pump.notify()`: a flag and a condition-variable signal. The pump thread wakes, reads
`service.latest()` (retained), encodes it as one JSON line in temporary memory, and calls
`topic.publish`. Notifications that arrive while it works are merged, so the last state
always wins and a burst costs one encode.

## Wire behaviour

Matches DMS unless listed under "Differences".

* Handshake line `{"apiVersion":38,"capabilities":[...]}` on accept, without an id.
* Requests `{"id":N,"method":...,"params":{...}}`; replies `{"id":N,"result":...}` or
  `{"id":N,"error":"text"}`. `ping` answers `{"pong":true}`. Unknown methods answer
  `unknown method: <name>`.
* Errors are plain strings. The text is DMS's where DMS's source has one, for example
  `missing or invalid 'device' parameter` (dankgo `params/params.go`), `device not found: X`
  and `percent out of range: N` (`brightness/manager.go`), `invalid shell pid` (`router.go:61`).
* `subscribe {services, clientId}`: the first frame is `{"id":N,"result":{"service":"server","data":ServerInfo}}`.
  Each topic that has a state sends it once; later publications follow. Every frame
  carries the subscribe request's id.
* Field names and their order are the Go `json` tags, written by hand. The tests
  compare them with `golden/go_tags.json`, which is extracted from the Go source.
* `[]` for an empty list, never `null`. `omitempty` follows the tags: `SuccessResult`
  leaves out an empty `message` and `value`; `ServerInfo` leaves out an empty `cliVersion`.

## Coverage

Columns: **done** (implemented and tested), **n/s** (`not supported: <why>`, the DMS method
has no Bleu equivalent in this design), **open** (not started; the method is
`unknown method` until its module exists). The method list is `dms_surface.md` section 2.

### Core and IPC

| Method | Status | Notes |
| --- | --- | --- |
| `ping` | done | bleu_ipc answers before any handler (as dankgo does) |
| `getServerInfo` | done | `apiVersion` 38, `cliVersion` "0.1.0", started modules |
| `subscribe` | done | bleu_ipc; services `all`, `server`, `brightness`, `brightness.update`, `loginctl` |
| `unsubscribe` | done | unknown method, as in DMS (`server.go:409-416`) |
| `shell.ready` | done | validates `pid`; the readiness side effect is not ported (see Differences) |
| `matugen.queue`, `matugen.status` | open | appearance |
| `clipboard.getConfig`, `clipboard.setConfig` | done | clipboard module (see its section); `setConfig` accepts only the running values |

### brightness (`brightness/handlers.go`)

| Method | Status | Notes |
| --- | --- | --- |
| `brightness.getState` | done | `State{devices}` |
| `brightness.setBrightness` {device, percent, exponential, exponent} | done | writes DMS's raw value; replies with the state |
| `brightness.increment` / `decrement` {device, step=10, exponential, exponent} | done | percent clamped to 0..100 |
| `brightness.rescan` | done | re-reads the backends; replies with the state |
| `brightness.subscribe` | n/s | DMS streams from it; use top-level `subscribe` with `brightness` |

| Topic | Status | Notes |
| --- | --- | --- |
| `brightness` | done | `State` on every change |
| `brightness.update` | done | `{device}` after each successful set, increment or decrement (not debounced) |

Device mapping (`brightness/sysfs.go`, `ddc.go`, `manager.go`):

* `class`: `backlight` (panel), `leds` (keyboard LED), `ddc` (monitor). Software gamma
  devices are not produced: Bleu's Linux backend has no gamma control.
* `id`: `backlight:<name>`, `leds:<name>`, `ddc:<connector>` (see Differences).
* `current`/`max`: the raw value and the maximum. `currentPercent`: DMS's `ValueToPercent`
  (sysfs, minimum 1 for backlights and 0 for LEDs) or `ddcPercentFromRaw`.
* Sorted by class rank (backlight, ddc, software, leds), then by name (`manager.go` sortDevices).
* LED names that DMS hides (`::lan`, `::capslock`, `::numlock`, `::scrolllock`, `::kana`,
  `::compose`) are left out (`sysfs.go:82-101`).

### loginctl (`loginctl/handlers.go`, `actions.go`, `monitor.go`)

| Method | Status | Notes |
| --- | --- | --- |
| `loginctl.getState` | done | `SessionState`, all 19 fields (see Differences for zeros) |
| `loginctl.lock` / `unlock` / `terminate` | done | Bleu session calls; the reply waits for the operation |
| `loginctl.setLockBeforeSuspend` {enabled} | done | flag read by the sleep barrier |
| `loginctl.setSleepInhibitorEnabled` {enabled} | done | `power.inhibit(SLEEP_DELAY, "DankMaterialShell", "Lock before suspend")`; on by default, as in DMS |
| `loginctl.lockerReady` | done | ends a sleep barrier's wait; kept until unlock, as DMS's `prelockedReady` |
| `loginctl.activate` | n/s | `not supported: bleu_session cannot activate a session` |
| `loginctl.setIdleHint` | n/s | `not supported: bleu_session reads the idle hint and cannot write it` |
| `loginctl.setLockedHint` | n/s | `not supported: bleu_session reads the locked hint and cannot write it` |
| `loginctl.subscribe` | n/s | streaming form; use top-level `subscribe` with `loginctl` |

| Topic | Status | Notes |
| --- | --- | --- |
| `loginctl` | done | `SessionState` on every change of the session state |

Sleep barrier (`monitor.go:52-95`): on `PrepareForSleep(true)`, if lock-before-suspend is
on and the session is not locked, the session is locked. While the sleep inhibitor is held
and no `lockerReady` came before, the barrier waits for `lockerReady`, up to
`LOCKER_READY_TIMEOUT` (5 s). Then it drops the inhibitor and acknowledges the power barrier.
On `RESUMED` the inhibitor is taken again if it is wanted. Measured: a suspend with
`lockerReady` after 1 s finishes in 2.0 s; without it, in 5.5 s.

### clipboard (`clipboard/handlers.go`, `types.go`) — `mod_clipboard.c3`, `bleu_clipboard`

Capability `clipboard`, topic `clipboard` (`State` on every change). Starts only when the
clipboard can be opened: Linux with a Wayland display that has a data-control protocol. On
other hosts the start-up line says so and the methods are `unknown method`.

| Method | Status | Notes |
| --- | --- | --- |
| `clipboard.getState` | done | `{enabled, history}`; `enabled` is true while the service runs; `current` is omitted (see below) |
| `clipboard.getHistory` | done | the history entries without payloads |
| `clipboard.getEntry` {id} | done | the entry with `data` (base64) of its first offered type; `null` when the entry is gone |
| `clipboard.deleteEntry` {id} | done | `not found` error when the entry is not there |
| `clipboard.deleteEntries` {ids} | done | `{deleted: N}` |
| `clipboard.clearHistory` | done | deletes each entry |
| `clipboard.copy` {text} | done | owns the selection with UTF-8 text |
| `clipboard.copyEntry` {id, textOnly} | done | owns the selection with the entry's first type; `textOnly` is ignored (no alternate type) |
| `clipboard.paste` | done | the current selection's text (UTF-8 types first); nothing is typed |
| `clipboard.pasteSupported` | done | `{supported: false}`: Bleu has no paste keystroke |
| `clipboard.getConfig` | done | the running service's values (see below) |
| `clipboard.setConfig` | done | accepted when every named value is the running one; else `not supported: <key> cannot change while the clipboard service runs` |
| `clipboard.subscribe` | n/s | streaming form; use top-level `subscribe` with `clipboard` |
| `clipboard.sendPaste`, `search`, `store`, `pinEntry`, `unpinEntry`, `getPinnedEntries`, `getPinnedCount`, `editEntry`, `copyFile` | n/s | Bleu has no paste keystroke, search index, pins, file lists or history editing (each reply says so) |

Differences from DMS's `Entry` and `State` (`clipboard/types.go:99-117`): `mimeType` is the
first MIME type the owner offered, not the stored type; `isImage` and `pinned` are false;
`hash`, `altData` and `altMimeType` are not kept; state entries carry no `data`; `current` is
omitted because Bleu's selection has no capture time (DMS's `Entry.timestamp`). `getConfig`
reports DMS's defaults that the service runs with: `maxHistory` 100, `maxEntrySize` 5 MiB,
`autoClearDays` 0, `clearAtStartup` true (Bleu's history is in memory, so it starts empty),
`disabled` false, `maxPinned` 0 (no pins). DMS keeps its history in a bbolt file and its
settings in `clsettings.json`; neither is read or written here. The history is also capped at
4 MiB of text (`bleu_clipboard`'s default), which DMS does not have. The error texts for a
missing entry and for "no text" are dmsd's wording: DMS's `clipboard/manager.go` was not read.

### apps: apppicker and mime (`apppicker/`, `mime/handlers.go`, dankgo `desktop/mime.go`) — `mod_apps.c3`

No capability is advertised (see Differences, item 16). Topic `browser.open_requested` carries
DMS's `OpenEvent` (`apppicker/models.go:3-7`).

| Method | Status | Notes |
| --- | --- | --- |
| `apppicker.open`, `browser.open` {target \| url, requestType, mimeType, categories} | done | publishes the event, answers `"ok"`; `invalid target parameter` as DMS |
| `mime.getDefault` {mimeType} | done | the default in `mimeapps.list` (exact type), else the first desktop file that declares it, else `""` |
| `mime.getDefault` {path} | n/s | no file-name to MIME-type lookup (no shared-mime-info glob table) |
| `mime.appsForMime` {mimeType} | done | the associated desktop IDs, never `null` |
| `mime.handlersForMime` {mimeType} | done | the associated apps from the `bleu::apps` catalogue, without NoDisplay and Terminal entries |
| `mime.queryDefaults` {mimeTypes} | done | `{defaults}` with keys in byte order (Go's map encoding); duplicates collapse |
| `mime.invalidate` | done | `{success: true}`: the MIME files are read on every request, so there is no cache to drop |
| `mime.setDefault`, `mime.setDefaults` | n/s | `bleu::xdg` reads `mimeapps.list` but has no writer |

Deviations from DMS's `dankgo/desktop/mime.go`: DMS's `GetDefault` falls back through
`mimeinfo.cache` and then every desktop entry that supports the type; `AppsForMime` also
follows the type's aliases and parents (`mimeChain`). Bleu's `bleu::xdg::mime` answers the
type given, from `mimeapps.list` and the desktop files, and does not read `mimeinfo.cache`
(a parser exists, the file is not read). So an application that is listed only in a cache, or
a type reached through an alias or a parent, is missing from these replies.

### dgop (`dgop/handlers.go`, dgop `gops/meta.go` and `models/*.go`) — `mod_sysinfo.c3`, `bleu_sysinfo`

Capability `dgop` (DMS always advertises it, `server.go:430`). Structs are written in dgop's
Go field order (`MetaInfo`, `CPUInfo`, `MemoryInfo`, `ProcessInfo`, `SystemInfo`). `dgop.meta`
computes the modules `cpu`, `memory`, `processes` and `system` and leaves out the others (as DMS
leaves out a module whose read fails). Unknown module names: `unknown module: <name>`; names are matched
exactly, where DMS lowercases them first (`gops/meta.go`, `GetMeta`).

| Method | Status | Notes |
| --- | --- | --- |
| `dgop.meta` {modules, limit, sort, noCpu, mergeChildren, gpuPciIds, cursors} | done, partial | see the field table |
| `dgop.modules` | done | `{available}`: the four modules dmsd computes, in dgop's order (dgop lists twelve) |
| `dgop.gpu`, `dgop.hardware` | n/s | Bleu's sysinfo reads no GPU and no hardware inventory |

Field table (`✓` from Bleu, `0`/`""` written where Bleu has no value, `—` omitted):

| Struct | Fields from Bleu | Written empty or zero |
| --- | --- | --- |
| `CPUInfo` | `count` (processors), `model`, `usage` (whole machine, 0 before the second sample), `coreUsage` | `frequency`, `temperature` (no per-CPU sensor is named), `total` and `cores` (cumulative tick counters, which only dgop's cursor uses: `[]`) |
| `MemoryInfo` | `total`, `used` (total minus available), `usedPercent`, `available`, `cached`, `swaptotal`, `swapfree` | `free` (Bleu reports `available` only), `buffers`, `sreclaimable`, `shared`, `zfsArcSize`, `gpuActive`, `gpuReclaim` |
| `ProcessInfo` | `pid`, `cpu` (divided by the processor count, so a machine percentage as dgop reports it), `memoryPercent`, `memoryKB`, `rssKB`, `rssPercent`, `username`, `command` (the short name), `fullCommand` | `ppid`, `pticks`, `memoryCalculation`, `pssKB`, `pssPercent`; `executablePath` and `childCount` are omitted |
| `SystemInfo` | `loadavg` (three values, two decimals, as `/proc/loadavg` prints them) | `processes`, `threads` (Bleu keeps only the busiest processes), `boottime` |

Not served, and why: `network`, `net-rate`, `disk`, `disk-rate` (Bleu reports rates, not the
cumulative byte and I/O counters dgop has), `diskmounts` (dgop's size strings are not read),
`gpu`, `gpu-temp`, `hardware`. Other parameters: `limit` defaults to 20 (DMS) and is clamped
to 500 (the service's `process_count`); a `sort` other than `cpu` leaves `processes` out (only
the CPU order is kept); `noCpu` zeroes the process CPU; `mergeChildren` is not applied (no
`childCount`, no merged rows); cursors are not read and `cursor` is never written. Memory
figures are dgop's own names for Bleu's values; `memoryKB` is the resident set size, the only
memory figure Bleu reads for a process, and dgop's definition of `memoryKB` was not read.

### evdev (`evdev/handlers.go`, `models.go`) — `mod_evdev.c3`

`evdev.getState` is refused: `bleu_input` reports keyboard layouts, and its README cuts the lock
keys (caps, num, scroll) from v1. No capability is advertised, and the `evdev` stream has no
topic here.

### Refused modules (`not supported`) — `mod_unsupported.c3`

Every method in the DMS handler tables of these modules answers `not supported: <why>`, and no
capability is advertised: cups (25, including `cups.subscribe`), tailscale (6), wellbeing (5),
sysupdate (8), wallpaper (4, including `wallpaper.subscribe`), files (13, the `files.*` names in
dankgo's `files/handlers.go`, reached through the `files.` prefix), plugins (6), themes (6) and
registries (3). The complete list, with its source, is `tests/golden/refused_methods.json`. The
reasons say that Bleu has no such service; none of them is a claim about DMS's behaviour.

### mpris (`mpris.command`, `bluetooth.mpris.publish`)

DMS's `mpris.command` stream is fed by the bluez manager: one subscriber is promoted to command
owner and receives a `lease`, AVRCP commands arrive on the stream, and the owner publishes a
player with `bluetooth.mpris.publish {lease, ...}` (`bluez/manager.go:596-719`,
`bluez/handlers.go:63-80`). Bleu cannot serve either half: `bleu_bluetooth` does not build AVRCP
on Linux, and `bleu_media`'s publishing side is cut from v1. The method is refused by
`mod_bluetooth.c3`, which owns it; `bleu_media` is not linked, because no DMS method reads the
players it observes (the shell uses its own MPRIS support).

### bluetooth (`bluez/handlers.go`, `manager.go`, `agent.go`, `broker.go`) — `mod_bluetooth.c3`, `bluetooth_wire.c3`

`device` takes the BlueZ object path DMS and the shell use (`/org/bluez/hci0/dev_AA_..`), or an
address. A request that waits for BlueZ is answered when it completes, not when it arrives, so no
handler thread is held while a pairing waits for the user.

| Method | Status | Notes |
| --- | --- | --- |
| `bluetooth.getState` | done | `BluetoothState`; DMS's zero state until the first publication |
| `bluetooth.startDiscovery` / `stopDiscovery` {adapter} | done | the default scan filter |
| `bluetooth.setPowered` {powered, adapter} | done | no rfkill unblock before power-on (Differences) |
| `bluetooth.togglePowered` {adapter} | done | `PoweredResult`, the opposite of the live state (`manager.go:780-796`) |
| `bluetooth.pair` {device} | done | answered when the pairing completes, as DMS's blocking call is; success trusts and connects the device (`manager.go:454-469`) |
| `bluetooth.connect` / `disconnect` {device} | done | a connect of a connected device succeeds (BlueZ's AlreadyConnected) |
| `bluetooth.remove` {device} | done | |
| `bluetooth.trust` / `untrust` {device} | done | |
| `bluetooth.pairing.submit` {token, secrets, accept} | done | `secrets.pin`, `secrets.passkey`, `secrets.decision` (`agent.go`) |
| `bluetooth.pairing.cancel` {token} | done | refuses the prompt: BlueZ gets Rejected where DMS sends Canceled |
| `bluetooth.mpris.publish` | n/s | the reason is the one in the mpris section above |
| `bluetooth.subscribe` | n/s | use top-level `subscribe` with `bluetooth` and `bluetooth.pairing` |

| Topic | Status | Notes |
| --- | --- | --- |
| `bluetooth` | done | `BluetoothState` on every change, retained (`server.go:651-658`) |
| `bluetooth.pairing` | done | one `PairingPrompt` per prompt, not retained (`server.go:673-680`); a code shown to the user has `token` "" and takes no answer |

Prompts (`agent.go`, `promptFor`): `requestType` is `confirm`, `pin`, `passkey`, `authorize`,
`display-pin` or `display-passkey`, and `fields` and `hints` follow the same calls. The `passkey`
key is sent for a confirmation and a displayed passkey only. The shell reads these names and the
`secrets` keys in `quickshell/Modals/BluetoothPairingModal.qml:375-400`.

### Not started (DMS methods that dmsd does not serve yet)

Each of these modules will follow `apps/dmsd/tests`' pattern once written. Until then
the method answers `unknown method: <name>`. Names are from `dms_surface.md` section 2.3.
The modules that are done, or refused, are above (`dgop`, `clipboard`, `apps`, `evdev`, the refused
modules); the rows that remain here belong to the modules not yet written.

| Module | Methods | Bleu service(s) |
| --- | --- | --- |
| network | getState, wifi.* (scan, networks, connect, disconnect, forget, toggle, enable, disable, setAutoconnect), ethernet.*, cellular.*, preference.set, info, qrcode*, vpn.*, hotspot.*, credentials.submit, credentials.cancel | network |
| gamma (wayland) | gamma.getState, setTemperature, setLocation, setManualTimes, setUseIPLocation, setGamma, setEnabled, icc.* | color |
| theme.auto | getState, setEnabled, setMode, setSchedule, setLocation, setUseIPLocation, trigger | appearance |
| freedesktop | getState, accounts.* (setIconFile, setRealName, setEmail, setLanguage, setLocation, getUserIconFile), settings.getColorScheme, settings.setIconTheme | appearance, session |
| location | getState, subscribe | location |
| wlroutput | getState, applyConfiguration, testConfiguration, subscribe | display |
| dbus | call, getProperty, setProperty, getAllProperties, introspect, listNames, subscribe, unsubscribe | out of scope for the shell (generic D-Bus proxy) |
| notify | watchAction, send | notify |

## Differences from DMS

Each is deliberate unless it says otherwise.

1. **Socket name.** `dmsd-<pid>.sock`, not `danklinux-<pid>.sock`. The shell reads the path
   from `DMS_SOCKET` (`DMSService.qml:38`), so it has to be given dmsd's path. Who sets
   `DMS_SOCKET` was not in the fetched sources (`dms_surface.md` section 8), so how a
   shell launch would pass it is unverified.
2. **`cliVersion`** is "0.1.0", not DMS's build version.
3. **Capability names.** DMS always advertises `plugins`, `dgop`, `lyrics`, `lyrics.plugins`.
   dmsd omits them: it does not provide those services.
4. **`loginctl` fields Bleu does not report** are empty or zero: `sessionPath`,
   `sessionClass`, `remoteHost`, `service`, `tty`, `display`, `idleSinceHint`, `vtnr`.
   `locked` and `lockedHint` are one value, as DMS sets both from `LockedHint`.
5. **DDC ids.** DMS uses `ddc:i2c-N`. Bleu does not expose the bus number, so dmsd uses
   `ddc:<connector>`. The shell takes ids from `getState`, so it stays consistent; a client
   that hard-codes `i2c-N` will not match.
6. **DDC names.** DMS names a monitor by its adapter or EDID name; dmsd uses the connector.
7. **Settling.** After a write, dmsd replies with the first state published after it, or
   the newest state after 500 ms. DMS updates its state before writing; the difference is
   at most 500 ms.
8. **`brightness.update`** is sent after every request, not debounced 150 ms as DMS does.
9. **`shell.ready`** validates the pid and logs it. DMS also informs its readiness
   tracker (`readiness.ShellReady`, not fetched); that tracker is not ported.
10. **Streaming methods.** `<module>.subscribe` streams in DMS. The protocol here answers
    once, so these answer `not supported` and point to top-level `subscribe`.
11. **Brightness exponent.** Sysfs uses the request's exponent; DDC uses the fixed 2.0 that
    DMS's `ddc.go` uses. The arithmetic is DMS's (`brightness_math.c3`).
12. **Lock-before-suspend.** DMS's lock and wait are reproduced. DMS also has a fallback
    timer (`initializeFallbackDelay`, `loginctl/manager.go`, not read in full); dmsd's wait is
    bounded at a fixed 5 s instead.
13. **Bleu's native panel (macOS `NATIVE`) and gamma/overlay devices** are not listed: DMS's
    `native` backend class is not in the fetched sources, and software brightness is not built
    on Linux.
14. **Errors** carry no status number (DMS has none). Each text is the DMS text where one exists.
15. **Refused methods** answer `not supported: <why>`, as the loginctl methods do. A method
    that dmsd knows by name and cannot serve is never shown as unknown, and its capability is
    never advertised.
16. **`browser` is not advertised.** DMS names the subscription `browser` (`server.go:682`) and
    labels its frames `browser.open_requested`. bleu_ipc labels a frame with its topic's own
    name, so a subscriber that asks for `browser` would get nothing, and a picker that depends
    on it would never open. The method still works for a subscriber that names
    `browser.open_requested`. Advertise the capability once bleu_ipc can label a topic under
    another name (a library change). The shell's own subscribe list was not read.
17. **`dgop` is advertised with partial coverage.** The shell's `dgop` calls for CPU, memory,
    processes and system work. The fields Bleu does not report are zero or empty (table in the
    `dgop` section). Cumulative counters, GPU and disk inventory are refused or left out.
18. **Clipboard history is in memory.** DMS's history persists across restarts; Bleu's does
    not, and `getConfig` reports `clearAtStartup` true to say so.

19. **Bluetooth identity.** Bleu identifies adapters and devices by address, so `path` is "" in `BluetoothState`. The `device` parameter takes either a BlueZ object path or an address.
20. **Bluetooth fields Bleu does not report.** `legacyPairing` is false. `icon` is derived from Bleu's icon class, named as BlueZ names it (`class_to_icon`, `gap_appearance_to_icon`), and is "" for a watch or a wearable. `alias` is "" when it equals the name, because Bleu keeps only the display name.
21. **First controller and order.** DMS takes `powered` and `discovering` from the first object path. dmsd takes them from the controller with the lowest address, and lists devices in address order (DMS's order is BlueZ's object order, unspecified).
22. **Pairing answers.** A refusal, or a cancel, sends BlueZ `Rejected`; DMS sends `Canceled`. A PIN answer must be 1 to 16 characters (Bleu refuses others). `authorize-service:<uuid>` arrives as `authorize`, because `bleu_bluetooth` drops the UUID.
23. **Codes shown to the user** (display-pin, display-passkey) carry `token` "": nothing waits for them, so DMS's random token has no counterpart.
24. **Auto trust and connect.** DMS does it when BlueZ reports a device it is pairing as paired (`manager.go:454-469`). dmsd does it when its own `pair` succeeds, and a failure is noted on stderr, as DMS logs it.
25. **No rfkill unblock.** DMS unblocks a Bluetooth rfkill switch before it powers the adapter on (`manager.go:798-806`). Bleu cannot write rfkill, so a soft-blocked radio refuses `setPowered {powered: true}` with the library's reason.
26. **One backend.** dmsd uses BlueZ only. DMS's module is BlueZ's, and Bleu's macOS and Windows backends have partial capabilities that would present as a working module.
27. **Waiting time.** A request waits at most the library's timeouts: 25 s for a call, 120 s for a pairing (prompts included). DMS waits for the bus reply without a bound of its own.

## Verified how

Run on Linux x86-64, C3 0.8.5, glibc, python 3.13, dbus-next 0.2.x, dbus-daemon 1.14:

* `apps/dmsd/tests/run.sh` (passes, all checks):
  * unit tests of the arithmetic (9 `@test` functions in `brightness_math_test.c3`);
  * build of the daemon;
  * 58 protocol checks through `check_dms.py`, which drives the daemon as the shell does
    (`dmsclient.py`): replies against the golden files, error texts, key order against the Go
    tags, raw values written to a fake sysfs tree against an independent Python copy of the
    DMS formulas, and the subscription frames;
  * the sleep barrier against the logind mock: suspend with `lockerReady` (about 2 s; the
    order lock, release, resume), and without it (about 5.5 s, the timeout);
  * clean shutdown on SIGTERM, and an absent bus that is reported once and not advertised.
* AddressSanitizer build (`--sanitize=address`), same protocol run and SIGTERM: no leak
  from dmsd's own code. The reports that remain are inside bleu_dbus and bleu_power (below).
* `tools/check-apps.sh dmsd`: compile-only for `linux-x64`, `linux-aarch64`, `macos-aarch64`,
  `macos-x64` (compiled, not run). Windows is skipped: dmsd is POSIX-only.
* The new modules (`dgop`, `clipboard`, `apps`, `evdev`, the refused modules) were type-checked
  for the four POSIX targets, and built and run on Linux x86-64 in a tree made of HEAD plus
  this work's files (the shared tree had another module that did not compile at that time).
  `apps/dmsd/tests/modules.sh` (run from `run.sh`) runs them against a private XDG tree with no
  bus, no display and no logind: 71 checks, which include dgop's values against `/proc` (CPU
  count, memory and swap totals, load average, process RSS and owners), the mime replies
  against the desktop files, the `browser.open_requested` frame, every DMS method of the
  refused modules against `golden/refused_methods.json`, and the handshake (`dgop` only).
  Also run: clean shutdown on SIGTERM, and clipboard reported absent once.
* Not run: the clipboard's backend (no Wayland compositor on this host; `bleu_clipboard`'s own
  tests use an in-process mock that a daemon test cannot reach), so every clipboard reply
  except the absence was compiled only.

Not run: any macOS build; a real logind; a real `/sys` with a backlight; a DMS shell
connected to dmsd (the protocol was checked against the QML client's documented behaviour, not
against the QML code itself).

* `apps/dmsd/tests/bluetooth.sh`, called by `run.sh`: its own private system bus, the BlueZ mock
  of `libs/bleu_bluetooth.c3l/tests/mock_bluez.py` (run from there, not copied) and the logind mock.
  `bluetooth_check.py` makes 50 checks: the handshake order, `getState` against
  `golden/bluetooth_state_initial.json`, the key order against `golden/bluetooth_go_tags.json`, power,
  discovery, pairing by confirmation, PIN (a wrong one, then the right one) and passkey (cancelled, then
  accepted), a refused token, connect, disconnect, trust, untrust, remove, the `not supported` texts and
  the state topic. Then a shutdown with a pairing in flight (exit 0), `--module-off bluetooth`, and a
  start with no BlueZ (not advertised, reported once). Stable over four runs.
* `tools/check-apps.sh dmsd` (the four POSIX targets) passed on a copy of the tree with this module,
  `loginctl` and `brightness`; the shared tree did not compile as a whole while other modules were in
  progress. On the same copy, `run.sh` passed its unit tests, build, sleep barrier, shutdown and the
  bluetooth section. Its golden handshake and the sections of other modules failed there, because the
  copy lacks those modules.


## Found in the libraries (not fixed here)

* `bleu_ipc`: a frame is labelled with its topic's name, so DMS's `browser` service (frames
  `browser.open_requested`) cannot be served as DMS names it (Differences, item 16).
* `bleu_input`: no lock-key (caps lock) state; the v1 cut in its README. evdev is refused for this.
* `bleu_xdg`: no shared-mime-info glob table, no `mimeinfo.cache` reader (the parser needs the
  text, and the file is not read), no writer for `mimeapps.list`.
* `bleu_sysinfo`: no cumulative network and disk counters, no GPU and no hardware inventory.
* `bleu_clipboard` `open`: its failure reason is not kept in the error state, so a caller that
  asks `failure_text` gets the message of an earlier, unrelated failure. dmsd names the reason
  itself on this path. The same hazard is in `contract::failure_text` (module.c3): it returns
  `error::last()` whenever it is set, which can be stale. Callers should name a reason they know.

* `bleu_dbus` `marshal.decode` (reader.c3:350) allocates a string in `Proxy.get_all_properties`
  (proxy.c3:129), called by `bleu_power`'s `connect_bus` (linux_logind.c3:209). ASan reports 6
  bytes leaked after the power service is closed. dmsd is not at fault: the allocation is
  inside the library.
* Earlier in this work `bleu_power` (HEAD, Linux) did not type-check: `make_hold` and
  `make_inhibitor` were called unqualified in `linux_calls.c3`, and `err` was shadowed in
  `linux_logind.c3`. It type-checks now in the tree this was verified on.

* `bleu_bluetooth` `probe` (`bluez.c3`): the default system bus is used only when
  `/run/dbus/system_bus_socket` (or the legacy path) exists. dmsd passes `DBUS_SYSTEM_BUS_ADDRESS`
  explicitly, so a bus elsewhere works; a host with neither is reported as absent.
* `bleu_bluetooth` `open` returns bare excuses (`error::UNAVAILABLE~`, `UNSUPPORTED~`) with no detail,
  so its reason cannot say which check failed. The module names the service it needs instead.
* `bleu_bluetooth` does not expose the BlueZ object path, the `Icon` string, `LegacyPairing`, or the
  service UUID of an `AuthorizeService` prompt (`bluez_agent.c3` `on_authorize_service` drops it).

## Adding a module

1. Create `apps/dmsd/src/mod_<name>.c3` with a module doc comment that cites the DMS files.
2. Copy `mod_brightness.c3`'s shape: a state struct, `start` (open the service, else `warn`
   and return false), `stop` (reverse of `start`), a `StatePump` for each topic, a
   `const contract::Module DESCRIPTOR` with `const` topic and capability arrays, and
   `fn contract::Module descriptor() => DESCRIPTOR;`.
3. Put DMS's wire shapes in the module, written with `wire::key_*` in the Go field order.
   Read the request parameters with `params::` so the error texts match dankgo.
4. Where DMS has a method Bleu cannot serve, answer `not supported: <why>` and list it in the
   coverage table. Never fake a success.
5. Add the module to `main.c3`'s `modules` array in the order DMS lists its capability.
6. Add its golden files and checks to `apps/dmsd/tests/`, and its Bleu library and the
   library's dependencies to `apps/dmsd/project.json`, then to the list in `run.sh`.
7. `c3fmt -i`, then `apps/dmsd/tests/run.sh` and `tools/check-apps.sh dmsd`.
