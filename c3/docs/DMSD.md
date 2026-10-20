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
| Every other DMS module (network, bluetooth, audio-adjacent, clipboard, cups, ...) | not started: the method is `unknown method` until its module lands |

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
| `clipboard.getConfig`, `clipboard.setConfig` | open | clipboard module |

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

### Not started (DMS methods that dmsd does not serve yet)

Each of these modules will follow `apps/dmsd/tests`' pattern once written. Until then
the method answers `unknown method: <name>`. Names are from `dms_surface.md` section 2.3.

| Module | Methods | Bleu service(s) |
| --- | --- | --- |
| network | getState, wifi.* (scan, networks, connect, disconnect, forget, toggle, enable, disable, setAutoconnect), ethernet.*, cellular.*, preference.set, info, qrcode*, vpn.*, hotspot.*, credentials.submit, credentials.cancel | network |
| bluetooth | getState, startDiscovery, stopDiscovery, setPowered, togglePowered, pair, connect, disconnect, remove, trust, untrust, mpris.publish, pairing.submit, pairing.cancel | bluetooth |
| gamma (wayland) | gamma.getState, setTemperature, setLocation, setManualTimes, setUseIPLocation, setGamma, setEnabled, icc.* | color |
| theme.auto | getState, setEnabled, setMode, setSchedule, setLocation, setUseIPLocation, trigger | appearance |
| freedesktop | getState, accounts.* (setIconFile, setRealName, setEmail, setLanguage, setLocation, getUserIconFile), settings.getColorScheme, settings.setIconTheme | appearance, session |
| wallpaper | getState, setConfig, trigger | wallpaper (none yet) |
| cups | subscribe, getPrinters, getJobs, pausePrinter, resumePrinter, cancelJob, purgeJobs, getDevices, getPPDs, getClasses, createPrinter, deletePrinter, ... | printers (none yet) |
| evdev | getState | input |
| location | getState, subscribe | location |
| wlroutput | getState, applyConfiguration, testConfiguration, subscribe | display |
| tailscale | getStatus, refresh, connect, disconnect, setExitNode, setAllowLanAccess | network (VPN) |
| apppicker / browser | apppicker.open, browser.open | apps |
| clipboard | getState, getHistory, getEntry, deleteEntry, deleteEntries, clearHistory, copy, copyEntry, paste, sendPaste, pasteSupported, subscribe, search, getConfig, setConfig, store, pinEntry, unpinEntry, editEntry, getPinnedEntries, getPinnedCount, copyFile | clipboard |
| dbus | call, getProperty, setProperty, getAllProperties, introspect, listNames, subscribe, unsubscribe | out of scope for the shell (generic D-Bus proxy) |
| dgop | meta, gpu, hardware, modules | sysinfo (none yet) |
| notify | watchAction, send | notify |
| sysupdate | getState, refresh, upgrade, cancel, acquire, release, releases, setInterval | updates (none yet) |
| wellbeing | getState, setState, setLimits, summary, clear | out of scope or new |
| plugins, themes, registries, mime, lyrics, matugen | (see dms_surface.md 2.3) | apps / out of scope |

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

Not run: any macOS build; a real logind; a real `/sys` with a backlight; a DMS shell
connected to dmsd (the protocol was checked against the QML client's documented behaviour, not
against the QML code itself).

## Found in the libraries (not fixed here)

* `bleu_dbus` `marshal.decode` (reader.c3:350) allocates a string in `Proxy.get_all_properties`
  (proxy.c3:129), called by `bleu_power`'s `connect_bus` (linux_logind.c3:209). ASan reports 6
  bytes leaked after the power service is closed. dmsd is not at fault: the allocation is
  inside the library.
* Earlier in this work `bleu_power` (HEAD, Linux) did not type-check: `make_hold` and
  `make_inhibitor` were called unqualified in `linux_calls.c3`, and `err` was shadowed in
  `linux_logind.c3`. It type-checks now in the tree this was verified on.

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
