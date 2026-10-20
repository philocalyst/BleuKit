# DankMaterialShell (DMS) service surface

Research for the Bleu port. Read-only inventory. Sources are cited as `path:line`.

## 0. Provenance and limits (read first)

- **Fetch method.** Everything was read with `curl` from `raw.githubusercontent.com`. The GitHub MCP server refused `AvengeMedia/DankMaterialShell` ("not configured for this session"). I did not add the repo, because adding it needs the user's approval. Directory listings were therefore unavailable. File names were found by guessing and by pkg.go.dev.
- **Base URLs.**
  - DMS: `https://raw.githubusercontent.com/AvengeMedia/DankMaterialShell/master/` (paths below are relative to it).
  - dankgo (external IPC library): `https://raw.githubusercontent.com/AvengeMedia/dankgo/master/`.
- **Revision.** `core/go.mod:6` pins `dankgo v1.6.3-0.20261019192939-46e7a10c933f`. I checked `ipc/server.go` and `ipc/mux.go` at that commit against master (identical MD5). The pkg.go.dev `server` package is at DMS commit `806799614cd5`, and `server.go` and `router.go` match master. The other dankgo files were not checked against the pin.
- **Read in full:** `core/internal/server/router.go`, `subscription.go`, `files.go`, `server.go` lines 1-1240, and the `dankgo` `ipc` server, mux, client, writer, bus, models, `paths`.
- **Read as types or extracted by grep only:** all `types.go` and `models.go` state structs, all `handlers.go` case lists, and request parameter keys (grepped, not read per method).
- **Not fetched (named but not inspected):** `network/manager.go` (934 lines), `bluez/manager.go` (925), `wayland/manager.go` (2007), `clipboard/manager.go` (2373), `loginctl/manager.go`, the `dgop`, `lyrics`, `mime`, `apppicker`, `themes`, `plugins`, `registries`, `matugen` and `trayrecovery` handler bodies, and the dankgo `files` package. Also not fetched: `quickshell/Services/` files beyond the 21 listed in section 3, the QML tree outside `Services/`, the `PipewireAudioBackend.qml` and `MprisController` files, and the Quickshell built-in modules.
- **Result shapes.** These are the Go types and the `conn.Respond(...)` expressions. For methods whose handler body was not read, the result shape is inferred from the Respond call and is marked as such.
- Where a claim cannot be cited, it is marked **[unverified]**.

## 1. Architecture summary

**Processes.** The Go daemon `core` (`core/cmd/dms`, module `github.com/AvengeMedia/DankMaterialShell/core`, `core/go.mod:1`) runs as a separate process from the Quickshell (QML) shell. The shell reads the socket path from the environment variable `DMS_SOCKET` (`quickshell/Services/DMSService.qml:38`). The code that sets `DMS_SOCKET` is not in the fetched files **[unverified]**.

**Socket.** The Go server's socket path is `$XDG_RUNTIME_DIR/danklinux-<pid>.sock`:
- `dankgo/paths/paths.go:30-52` (`SocketDir` and `SocketPath`). `SocketDir` returns `$XDG_RUNTIME_DIR` (or `$XDG_RUNTIME_DIR/app/$FLATPAK_ID` under Flatpak). Without a runtime dir it falls back to `/run/<app>` or `/var/run/<app>` for root, and `os.TempDir()` otherwise.
- App name is `danklinux` (`core/internal/utils/paths.go:11`). The server is built with `AppName: appPaths.Name` (`core/internal/server/server.go:928`).
- Mode `0600` (`dankgo/ipc/server.go:78`). Stale sockets from dead PIDs are removed at startup (`dankgo/ipc/server.go:224-251`).
- Client helper `FindRunningSocket` scans the directory and dials each socket (`dankgo/ipc/client.go:58-84`).

**Handshake.** On accept the server immediately writes one JSON line, without an id:
`{"apiVersion":38,"capabilities":[...]}`. The writer is `dankgo/ipc/server.go:143-153`, the struct is `dankgo/ipc/models.go:7-10`, and the capability list is computed per connection by `CapabilitiesFunc` (`core/internal/server/server.go:930`, `getCapabilities` at `server.go:429-509`). `APIVersion = 38` is at `server.go:42`.

**Framing.** Newline-delimited JSON, one message per line (`dankgo/ipc/server.go:162-172`). The read buffer is 64 KiB, and the maximum line is 64 MiB in DMS (`server.go:931`). The dankgo default is 1 MiB (`dankgo/ipc/server.go:21`). Writes have a 30 s deadline, and a client that stalls is disconnected (`dankgo/ipc/writer.go:12-14`, `:47-59`).

**Request.** `{"id": <int>, "method": "<name>", "params": {...}}` (`dankgo/ipc/models.go:12-16`). `id` is a Go `int`, but the QML client sends `Date.now() + counter` (`quickshell/Services/DMSService.qml:386-387`). Each request is dispatched in its own goroutine (`dankgo/ipc/server.go:171`), so responses can arrive out of order and must be matched by `id`.

**Response.** `{"id": N, "result": <any>}` or `{"id": N, "error": "<string>"}`. Both fields are `omitempty` (`dankgo/ipc/models.go:18-22`). Errors are plain strings with no code field. Malformed JSON gets `{"id":0,"error":"invalid json: ..."}` (`dankgo/ipc/server.go:167-168`). Unknown methods get `unknown method: <name>` (`dankgo/ipc/mux.go:41`). The QML client matches that exact text (`DMSService.qml:258`).

**Dispatch order (important for a port).** `dankgo/ipc/server.go:175-198` handles these before any DMS handler:
- `ping` returns `{"pong":true}` (`server.go:177-178`). DMS's own `ping` handler, which returns the string `"pong"` (`router.go:52-54`), is therefore unreachable.
- `subscribe` and `unsubscribe` go to `Config.SubscribeHandler` if set (`server.go:179-190`).
- Everything else goes to the DMS mux.

DMS sets `SubscribeHandler: subscribeHandler` (`core/internal/server/server.go:932`). `subscribeHandler` only accepts `subscribe` and returns `unknown method` for `unsubscribe` (`server.go:409-416`). The client never sends `unsubscribe` **[unverified]**.

**Subscriptions.** Subscriptions are multiplexed on one connection by a single `subscribe` request with `params.services` (a string array) and `params.clientId` (`quickshell/Services/DMSService.qml:177-193`). The defaults are `"all"` when the list is empty (`core/internal/server/server.go:551-553`). `"all"` does not include `mpris.command` (`server.go:660`, `serviceSubscribed` at `:530-532`).
- The first frame is `{"id":N,"result":{"service":"server","data":ServerInfo}}` (`server.go:793-798`).
- Each later frame is `{"id":N,"result":{"service":"<name>","data":<value>}}`, with the **same id** as the subscribe request (`server.go:809-812`, `ServiceEvent` at `:56-59`).
- Every service publishes an initial snapshot when it has one (`core/internal/server/subscription.go:9-16`), then raw values from its channel (`subscription.go:18-32`). The data is the **state value itself** (for example `NetworkState`), not the typed `*Event` wrapper. The typed event structs such as `NetworkEvent` (`network/types.go:222`) and `BluetoothEvent` (`bluez/handlers.go:18`) are not on this path in the fetched code.
- The dankgo `Bus` / `WriteEvent` envelope `{"event":topic,"data":...}` (`dankgo/ipc/writer.go:34-45`, `bus.go:8-11`) is **not** used by the DMS subscription path in the fetched code **[unverified for the rest of core/]**.

**Client side.** Two connections (`quickshell/Services/DMSService.qml:94-168`):
- A request socket. Responses are matched to callbacks by `id` (`DMSService.qml:126-131`, `handleResponse` at `:428-434`).
- A subscribe socket. Each line is dispatched on `response.result.service` (`DMSService.qml:256-361`). Lines without `result` are ignored (`:268-270`).

`sendRequest` takes an optional timeout and synthesizes `"Request timed out; operation completion is uncertain"` (`DMSService.qml:375-416`, `:368-371`). Lines with no `id` or `result` are dropped, including the handshake line.

**Version drift to fix.** The QML client has `expectedApiVersion: 1` (`DMSService.qml:19`), while the server reports `38`. The check is `apiVersion < expectedApiVersion` (`DMSService.qml:282`), so it never fires. A port should report at least 38 and keep the handshake line.

## 2. Server modules: methods, parameters, results, state, events

Method lines are `core/internal/server/<pkg>/handlers.go:<n>` unless marked otherwise. Router prefixes are `core/internal/server/router.go`. Param keys were grepped per package (`req.Get`, `params.*`) and are the union for that package, not per method. Results are the `Respond` expression at the handler.

### 2.1 Core and infrastructure

| Method | Handler | Params | Result |
| --- | --- | --- | --- |
| `ping` | dankgo intercepts (`dankgo/ipc/server.go:177`). DMS handler at `router.go:52` is unreachable. | none | `{"pong":true}` |
| `getServerInfo` | `router.go:55` → `server.go:511-517` | none | `ServerInfo{apiVersion, cliVersion, capabilities}` (`server.go:50-54`) |
| `subscribe` | `router.go:69` / `server.go:534` | `services: []string`, `clientId: string` | stream (section 2.2) |
| `shell.ready` | `router.go:58-67` | `pid: int` | `SuccessResult` |
| `matugen.queue`, `matugen.status` | `router.go:72-73` (`matugen_handler.go`) | not read | not read |
| `clipboard.getConfig` / `setConfig` | `router.go:74-77`, `handleClipboardSetConfig` at `router.go:260` | `maxHistory, maxEntrySize, autoClearDays, clearAtStartup, disabled, maxPinned` | `clipboard.Config` / `SuccessResult` |

Types: `ServerInfo` (`server.go:50-54`), `ServiceEvent{service, data}` (`server.go:56-59`), `Capabilities{capabilities}` (`server.go:46-48`), `SuccessResult{success, message, value}` (`core/internal/server/models/types.go:3-6`).

### 2.2 Subscription service names (the `services` values accepted by `subscribe`)

Each name is checked in `handleSubscribe` (`server.go:534-786`). The line is the `shouldSubscribe` check.

| Service name | Source | Data on the stream | Line |
| --- | --- | --- | --- |
| `server` | always sent first | `ServerInfo` (`server.go:50`) | `:571-573`, `:793` |
| `network` | `network.Manager.Subscribe` | `NetworkState` | `:579-586` |
| `network.credentials` | `SubscribeCredentials` | `CredentialPrompt` | `:588-595` |
| `loginctl` | `loginctl.Manager` | `SessionState` | `:597-604` |
| `freedesktop` | `freedesktop.Manager` | `FreedeskState` | `:606-613` |
| `freedesktop.screensaver` | `SubscribeScreensaver` | `ScreensaverState` | `:615-622` |
| `gamma` | `wayland.Manager` | `wayland.State` | `:624-631` |
| `theme.auto` | `thememode.Manager` | `thememode.State` | `:633-640` |
| `wallpaper` | `wallpaper.Manager` | `wallpaper.State` | `:642-649` |
| `bluetooth` | `bluez.Manager` | `BluetoothState` | `:651-658` |
| `mpris.command` | `SubscribePlayerCommands` (only when named explicitly) | `{lease}` or `{command}` | `:660-671` |
| `bluetooth.pairing` | `SubscribePairing` | `PairingPrompt` | `:673-680` |
| `browser` → `browser.open_requested` | `apppicker` | `OpenEvent` | `:682-689` |
| `cups` | `subscribeCups`, starts a CUPS manager on demand | `CUPSState` | `:691-693`, `:819-843` |
| `tailscale` | `tailscale.Manager` | `TailscaleState` | `:695-702` |
| `brightness` / `brightness.update` | `brightness.Manager` | `brightness.State` / `DeviceUpdate` | `:704-716` |
| `wlroutput` | `wlroutput.Manager` | `wlroutput.State` | `:718-725` |
| `evdev` | `evdev.Manager` | `evdev.State` | `:727-734` |
| `clipboard` | `clipboard.Manager` | `clipboard.State` | `:736-743` |
| `location` | `location.Manager` | `location.State` | `:745-752` |
| `wellbeing` | `wellbeing.Manager` | `wellbeing.State` | `:754-761` |
| `sysupdate` | `sysupdate.Manager` | `sysupdate.State` | `:763-770` |
| `files` | `filesEvents` bus, topics prefixed `files:` (`files.go:21-31`) | `files` event data (dankgo, not inspected) | `:772-778` |
| `dbus` | `dbus.Manager.SubscribeSignals` | `SignalEvent` | `:780-786` |

Notes:
- `"all"` expands to every service above except `mpris.command` (`server.go:530-532`, `:555`).
- Several `*.subscribe` methods also exist as handlers, for example `network.subscribe` (`network/handlers.go:65`), `wlroutput.subscribe` (`wlroutput/handlers.go:47`) and `clipboard.subscribe` (`clipboard/handlers.go:39`). The QML client does not call them. They are not on the fetched subscribe path **[unverified]**.
- Capability changes are pushed as `service: "server"` frames (`notifyCapabilityChange`, `server.go:519-528`).

### 2.3 Per-module inventory

**network** (`core/internal/server/network/`, prefix `network.` at `router.go:79-85`)
- Methods (`handlers.go` lines): `getState` 15, `wifi.scan` 17, `wifi.networks` 19, `wifi.connect` 21, `wifi.disconnect` 23, `wifi.forget` 25, `wifi.toggle` 27, `wifi.enable` 29, `wifi.disable` 31, `wifi.setAutoconnect` 95, `ethernet.connect` 35, `ethernet.connect.config` 33, `ethernet.disconnect` 37, `ethernet.info` 63, `cellular.connect` 41, `cellular.connect.config` 39, `cellular.disconnect` 43, `cellular.toggle` 45, `cellular.enable` 47, `cellular.disable` 49, `preference.set` 51, `info` 53, `qrcode` 55, `qrcode-content` 57, `generate-qrcode` 59, `delete-qrcode` 61, `subscribe` 65, `credentials.submit` 67, `credentials.cancel` 69, `vpn.profiles` 71, `vpn.active` 73, `vpn.connect` 75, `vpn.disconnect` 77, `vpn.disconnectAll` 79, `vpn.clearCredentials` 81, `vpn.plugins` 83, `vpn.import` 85, `vpn.getConfig` 87, `vpn.updateConfig` 89, `vpn.delete` 91, `vpn.setCredentials` 93, `hotspot.configure` 97, `hotspot.start` 99, `hotspot.stop` (next case), `hotspot.getSecrets` (next case).
- Params: `ssid, password, username, device, eapMethod, phase2Auth, anonymousIdentity, domainSuffixMatch, caCertPath, clientCertPath, privateKeyPath, useSystemCACerts, interactive, autoconnect, preference, uuid, uuidOrName, name, file/path, singleActive, token, secrets (map), save, band`.
- Results: `GetState()` returns `NetworkState` (`handlers.go:153`). `wifi.networks` returns `[]WiFiNetwork` (`:172`). `wifi.scan` returns `SuccessResult` (`:168`). Enable, disable and toggle return `{"enabled": bool}` (`:265-281`).
- State types: `network/types.go`: `WiFiNetwork` 29, `WiFiDevice` 47, `EthernetDevice` 60, `CellularDevice` 70, `VPNProfile` 83, `VPNActive` 94, `VPNState` 109, **`NetworkState` 114** (about 60 fields, all `json` tagged; see section 5), `ConnectionRequest` 162, `HotspotRequest` 179, `WiredConnection` 186, `PromptRequest` 227, `PromptReply` 242, `FieldInfo` 248, `CredentialPrompt` 254, `NetworkInfoResponse` 269, `WiredNetworkInfoResponse` 274, `VPNPlugin` 290, `VPNConfig` 298, `VPNImportResult` 307.
- Event types declared: `EventType` 211, `NetworkEvent{type,data}` 222 (not on the subscribe path).

**bluetooth** (`bluez/`, prefix `bluetooth.` at `router.go:133`)
- Methods: `getState` 25, `startDiscovery` 27, `stopDiscovery` 29, `setPowered` 31, `togglePowered` 33, `pair` 35, `connect` 37, `disconnect` 39, `remove` 41, `trust` 43, `untrust` 45, `subscribe` 47, `mpris.publish` 49, `pairing.submit` 51, `pairing.cancel` 53.
- Params: `device, powered, adapter, token, accept, secrets, lease`.
- Results: `getState` → `BluetoothState` (`handlers.go:61`). `setPowered` → `PoweredResult{success, powered}` (`:13-16`, `:196`). Others → `SuccessResult`. `mpris.publish` → `SuccessResult` "MPRIS state published" (`:79`).
- Types: `bluez/types.go`: `BluetoothState{powered, discovering, adapters, devices, pairedDevices, connectedDevices}` 10-16; `AdapterInfo` 19; `Device` 27 (`path, address, name, alias, paired, trusted, blocked, connected, class, icon, rssi, legacyPairing`); `PromptRequest` 42; `PromptReply` 52; `PairingPrompt` 58.

**brightness** (`brightness/`, `router.go:182`)
- Methods: `getState` 12, `setBrightness` 14, `increment` 16, `decrement` 18, `rescan` 20, `subscribe` 22.
- Params: `device` (string), `percent` (int), `step` (int, optional), `exponential` (bool), `exponent` (float).
- Results: `m.GetState()` (`handlers.go:30`, `:54`, `:73`, `:92`, `:97`).
- Types: `brightness/types.go`: `DeviceClass` 12; `Device{class, id, name, current, max, currentPercent, backend}` 21-28; `State{devices}` 31-33; `DeviceUpdate{device}` 35-37. Subscribe streams `brightness` (`State`) and `brightness.update` (`DeviceUpdate`).

**loginctl** (`loginctl/`, `router.go:109`)
- Methods: `getState` 13, `lock` 15, `unlock` 17, `activate` 19, `setIdleHint` 21, `setLockedHint` 23, `setLockBeforeSuspend` 25, `setSleepInhibitorEnabled` 27, `lockerReady` 29, `terminate` 31, `subscribe` 33.
- Params: `idle` (bool), `locked` (bool), `enabled` (bool).
- Results: `getState` → `SessionState` (`handlers.go:41`). Others → `SuccessResult`.
- Types: `loginctl/types.go`: **`SessionState` 13-33** (`sessionId, sessionPath, locked, active, idleHint, idleSinceHint, lockedHint, sessionType, sessionClass, user, userName, remoteHost, service, tty, display, remote, seat, vtnr, preparingForSleep`), `SessionEvent` 41.

**wayland / gamma and ICC** (`wayland/`, `router.go:125`)
- Methods: `gamma.getState` 19, `gamma.setTemperature` 21 (`low, high`), `gamma.setLocation` 23 (`latitude, longitude`), `gamma.setManualTimes` 25 (`sunrise, sunset, durationMinutes`), `gamma.setUseIPLocation` 27 (`use`), `gamma.setGamma` 29 (`gamma, contrast`), `gamma.setEnabled` 31 (`enabled`), `gamma.subscribe` 33, `icc.getStatus` 35, `icc.apply` 37 (`path, output`), `icc.remove` 39, `icc.listOutputs` 41, `icc.setTemp` 43 (`output, temp`), `icc.getTemps` 45.
- Types: `wayland/types.go`: `Config` 31 (`iccProfiles`, `outputTemps`, `outputBrightness`, lines 46-48), **`State` 51-64** (`config, currentTemp, nextTransition, sunriseTime, sunsetTime, dawnTime, nightTime, isDay, sunPosition, iccProfiles, outputTemps, outputs, gammaRefused`), `ICCStatus` 68-74, ICC metadata fields 78-89.

**freedesktop** (`freedesktop/`, `router.go:117`)
- Methods: `getState` 13, `accounts.setIconFile` 15 (`path`), `accounts.setRealName` 17 (`name`), `accounts.setEmail` 19 (`email`), `accounts.setLanguage` 21 (`language`), `accounts.setLocation` 23 (`location`), `accounts.getUserIconFile` 25 (`username`), `settings.getColorScheme` 27, `settings.setIconTheme` 29 (`iconTheme`).
- Results: `getState` → `FreedeskState` (`handlers.go:37`). `getColorScheme` → `{"colorScheme": uint32}` (`:138`). `getUserIconFile` → `SuccessResult{value}` (`:128`).
- Types: `freedesktop/types.go`: `AccountsState` 16-30 (`available, userPath, iconFile, realName, userName, accountType, homeDirectory, shell, email, language, location, locked, passwordMode, uid`), `SettingsState` 33-36 (`available, colorScheme`), `ScreensaverInhibitor` 38-44, `ScreensaverState` 46-51, `FreedeskState` 53-57.

**cups** (`cups/`, `router.go:165`)
- Methods (lines): `subscribe` 24, `getPrinters` 26, `getJobs` 28 (`printerName`), `pausePrinter` 30, `resumePrinter` 32, `cancelJob` 34 (`printerName, jobID`), `purgeJobs` 36, `getDevices` 38, `getPPDs` 40, `getClasses` 42, `createPrinter` 44 (`name, deviceURI, ppd, info, location, shared, errorPolicy` at `handlers.go:237`), `deletePrinter` 46, `acceptJobs` 48, `rejectJobs` 50, `setPrinterShared` 52 (`shared`), `setPrinterLocation` 54, `setPrinterInfo` 56, `moveJob` 58, `printTestPage` 60 (`printerName`), `addPrinterToClass` 62, `removePrinterFromClass` 64, `deleteClass` 66 (`className`), `restartJob` 68, `holdJob` 70 (`holdUntil`), `testConnection` 72 (`host, port, protocol`).
- Results: `getPrinters` → `map[string]*Printer` (`handlers.go:85`), `getJobs` → `[]Job` (`:100`), `getDevices` / `getPPDs` / `getClasses` (`:196`, `:205`, `:214`), `printTestPage` → `TestPageResult{success, jobId, message}` (`:382`).
- Types: `cups/types.go`: `CUPSState{printers map[string]*Printer}` 13-15; `Printer` 17-27 (`name, uri, state, stateReason, location, info, makeModel, accepting, jobs`); `Job` 29-37 (`id, name, state, printer, user, size, timeCreated`); `Device` 39-47; `PPD` 49-57; `RemotePrinterInfo` 59-67; `PrinterClass` 69-76; `SubscriptionEvent` 130.
- Note: `CUPSState` uses a map of pointers, which the Bleu contract forbids (section 6).

**evdev** (`evdev/`, `router.go:198`)
- Methods: `getState` 9.
- Results: `GetState()` → `State{available, capsLock}` (`evdev/models.go:3-5`).

**location** (`location/`, `router.go:222`)
- Methods: `getState` 16, `subscribe` 18.
- Results: `GetState()` → `State{latitude, longitude}` (`location/types.go:10-12`). Event wrapper `LocationEvent` at `location/handlers.go:9-12` (not on the subscribe path).

**wlroutput** (`wlroutput/`, `router.go:190`)
- Methods: `getState` 41, `applyConfiguration` 43 (`heads`), `testConfiguration` 45 (`heads`), `subscribe` 47.
- Params (`ConfigurationRequest{heads, test}` at `handlers.go:29-31`): `HeadConfig` (`handlers.go:14-27`) with `name, enabled, modeId, customMode{width,height,refresh}, position{x,y}, transform, scale, adaptiveSync`.
- Types: `wlroutput/types.go`: `OutputMode` 11-17, `Output` 19-37 (`name, description, make, model, serialNumber, physicalWidth, physicalHeight, enabled, x, y, transform, scale, currentMode, modes, adaptiveSync, adaptiveSyncSupported, id`), `State{outputs, serial}` 39-42.

**tailscale** (`tailscale/`, `router.go:174`)
- Methods: `getStatus` 13, `refresh` 15, `connect` 17, `disconnect` 19, `setExitNode` 21, `setAllowLanAccess` 23.
- Types: `tailscale/types.go`: `TailscaleState` 4-13 (`connected, version, backendState, magicDnsSuffix, tailnetName, exitNodeAllowLanAccess, self, peers`), `Peer` 16-32 (`id, hostname, dnsName, tailscaleIp, tailscaleIpv6, os, online, lastSeen, exitNode, exitNodeOption, tags, owner, relay, active, rxBytes, txBytes`).

**apppicker / browser** (`apppicker/`, `router.go:162-163`)
- Methods: `apppicker.open` 11 and `browser.open` 11 (same handler). Params: `target, url, requestType, mimeType, categories`.
- Event: `browser.open_requested` with `OpenEvent{target, mimeType, categories, requestType}` (`apppicker/models.go:3-7`).

**clipboard** (`clipboard/`, `router.go:214`)
- Methods: `getState` 17, `getHistory` 19, `getEntry` 21 (`id`), `deleteEntry` 23 (`id`), `deleteEntries` 25 (`ids`), `clearHistory` 27, `copy` 29 (`text`), `copyEntry` 31 (`id`, `textOnly`), `paste` 33, `sendPaste` 35, `pasteSupported` 37 (returns `{"supported": bool}`), `subscribe` 39, `search` 41, `getConfig` 43, `setConfig` 45, `store` 47 (`data` or `filePath`, `mimeType`), `pinEntry` 49, `unpinEntry` 51, `editEntry` 53, `getPinnedEntries` 55, `getPinnedCount` 57, `copyFile` 59.
- Results: `getState` → `State` (`handlers.go:67`), `getHistory` → `[]Entry` (`:75`), `search` → `SearchResult{entries,total,hasMore}` (`:320`), `getEntry` → `Entry` (`:95`), `getPinnedCount` → `{"count": int}`.
- Types: `clipboard/types.go`: `Config` 19-26 (`maxHistory, maxEntrySize, autoClearDays, clearAtStartup, disabled, maxPinned`), `SearchParams` 83-90 (`query, mimeType, isImage, limit, offset, before, after`), `SearchResult` 93-97, `Entry` 99-111 (`id, data (base64), mimeType, preview, size, timestamp, isImage, hash, pinned, altData (base64), altMimeType`), `State{enabled, history, current}` 113-117.
- Note: Go `[]byte` JSON-encodes as base64, and `time.Time` as RFC 3339. Both are wire facts a port must match.

**dbus** (`dbus/`, `router.go:206`)
- Methods: `call` 48 (`bus, dest, path, interface, method, args`), `getProperty` 50 (`bus, dest, path, interface, property`), `setProperty` 52 (`value`), `getAllProperties` 54, `introspect` 56, `listNames` 58 (`bus`), `subscribe` 60 (`bus, sender, path, interface, member`, returns `{subscriptionId}`), `unsubscribe` 62 (`subscriptionId`).
- Types: `dbus/types.go`: `SignalEvent` 27-34 (`subscriptionId, sender, path, interface, member, body[]`), `CallResult{values}` 36, `PropertyResult{value}` 40, `IntrospectResult{xml}` 44, `ListNamesResult{names}` 48, `SubscribeResult{subscriptionId}` 52.
- Note: DMS exposes a generic D-Bus proxy to the shell. This is a large, unrestricted surface for the port to decide on.

**dgop** (`dgop/`, `router.go:151`) — external library `dgop`
- Methods: `meta` 23, `gpu` 25, `hardware` 27, `modules` 29.
- Params: `noCpu, mergeChildren, limit, cpuCursor, diskRateCursor, netRateCursor, procCursor, sort, gpuPciIds, modules`.
- Results: `meta`, `gpu`, `hardware`, `modules` (return values not read).
- Note: the process list, CPU, memory, disk and network rates come through here (`dgop.meta` with `procCursor`/`sort`). The external module was not inspected.

**notify** (`notifyactions/`, `router.go:238`)
- Methods: `watchAction` 13 (`id, path`), `send` 15 (`summary, body, icon, actionLabel`).
- Types: `watched` 24, `Manager` 29 (`notifyactions/manager.go`). No JSON result types.

**sysupdate** (`sysupdate/`, `router.go:246`)
- Methods: `getState` 13, `refresh` 15 (`force, background`), `upgrade` 20 (`dry, interactive, includeAUR, includeFlatpak, terminal, customCommand`), `cancel` 22, `acquire` 25, `release` 28, `releases` 31, `setInterval` 34 (`seconds`).
- Results: `getState` → `State` (`handlers.go:13`).
- Types: `sysupdate/types.go`: `Package` 32-40, `BackendInfo` 43-49, `ErrorInfo` 51-55, `ShellInfo` 76-86, **`State` 88-105** (`phase, distro, distroPretty, backends, packages, count, intervalSeconds, lastCheckUnix, lastSuccessUnix, nextCheckUnix, operationId, operationStartedUnix, recentLog, error, shell, reboot`), `ReleaseCounts` 107, `Release` 114-125, `MasterInfo` 127-131, `ReleasesFeed` 134-140, `UpgradeOptions` 142, `RefreshOptions` 156.

**thememode / theme.auto** (`thememode/`, `router.go:93-99`)
- Methods: `getState` 18, `setEnabled` 20 (`enabled`), `setMode` 22 (`mode`: `time` or `location`), `setSchedule` 24 (`startHour, startMinute, endHour, endMinute`), `setLocation` 26 (`latitude, longitude`), `setUseIPLocation` 28 (`use`), `trigger` 30, `subscribe` 32.
- Types: `thememode/types.go`: `Config` 5-17 (`enabled, mode, startHour, startMinute, endHour, endMinute, latitude, longitude, useIPLocation, elevationTwilight, elevationDaylight`), `State{config, isLight, nextTransition}` 19-23.

**wallpaper** (`wallpaper/`, `router.go:101`)
- Methods: `getState` 19, `setConfig` 21 (`config`), `trigger` 23 (`target`), `subscribe` 25.
- Types: `wallpaper/types.go`: `ScheduleConfig` 5-10 (`enabled, mode, intervalSec, time`), `Config` 12-16 (`perMonitor, global, monitors`), `State` 18-23 (`config, nextRotation, cycleSeq, target`).

**wellbeing** (`wellbeing/`, `router.go:230`)
- Methods: `getState` 13, `setState` 15 (`appId, active, seq`), `setLimits` 17 (`daily, apps`), `summary` 19 (`days`), `clear` 22.
- Types: `wellbeing/types.go`: `DayUsage` 19-23 (`date, active, apps`), `Limits` 25-28, `LimitEvent` 30-35, `State` 37-41 (`today, limit, resync`).

**plugins / themes / registries / mime / lyrics** (no state streams)
- `plugins.*` (`plugins/handlers.go:11-21`): `list`, `listInstalled`, `install`, `uninstall`, `update`, `search`. Result type `PluginInfo` (`plugins/types.go:3-31`, 22 fields including `requires_dms`, `diffUrl`, `hasUpdate`).
- `themes.*` (`themes/handlers.go:11-21`): `list`, `listInstalled`, `install`, `uninstall`, `update`, `search`. Result types were not read.
- `registries.*` (`registries/handlers.go:24-28`): `list`, `add` (`name, url`), `remove` (`name`).
- `mime.*` (`mime/handlers.go:39-51`): `getDefault` (`path`), `setDefault`, `setDefaults`, `appsForMime`, `handlersForMime`, `queryDefaults`, `invalidate`. Params: `path` (string), `desktopId`. Results are `defaultResult`, `appsResult`, `handlersResult`, `queryResult` (`mime/handlers.go:65`, `:117`, `:138`, `:150`).
- `lyrics.get` (`lyrics/handlers.go:20`): params `title, artist, album, duration, fileUrl, providers[], allowNetwork`. Result not read.

**files** (external `dankgo/files`) — dispatched through `router.go:143-149` → `filesService.Handle`. Subscribed topic `files` (`server.go:772-778`). Not inspected.

**trayrecovery** (`core/internal/server/trayrecovery/`): not a request prefix. `InitializeTrayRecoveryManager` calls `WatchWatcherOwner()` (`server.go:344-355`). Not inspected.

**wellbeing / other managers initialised in `Serve`** are at `server.go:1137-1240` and beyond.

### 2.4 Printed API reference

The printDocs block (`server.go:976-1135`) is a human-readable method list that matches the handler names above. Use the handler tables as the source of truth.

## 3. QML services (`quickshell/Services/`)

Fetched: 21 files, 14,795 lines. Not fetched: the rest of the `quickshell/` tree (for example the Pipewire, Mpris and SystemTray backends).

| QML file | Consumes (DMS socket) | Consumes (Quickshell built-in / process) | Bleu service to replace it |
| --- | --- | --- | --- |
| `DMSService.qml` (826) | transport for everything; `plugins.*`, `themes.*`, `registries.*`, `matugen.status`, `subscribe` | none | none. This is the transport. A port must speak the protocol or rewrite the shell's client. |
| `DMSNetworkService.qml` (1374) | `network.*` (lines 354-1333) | none | `network` |
| `NetworkService.qml` (401) | not inspected | not inspected | `network` **[unverified]** |
| `BluetoothService.qml` (1035) | `bluetooth.setPowered`, `togglePowered` (`:99`, `:115`) | `Process` running `wpexec` for card profiles (`:932-1004`) | `bluetooth`; the `wpexec` card-profile step belongs to `audio` |
| `AudioService.qml` (1971) | none | `Process` running `pactl` and `wpctl` (`:293`, `:315`, `:403`, `:598`, `:1698`, `:1710`, `:1743`, `:1750`), `PipewireAudioBackend.qml` (`:54`, not fetched), `MprisController` (`:1130`, not fetched) | `audio`, `media` |
| `BrightnessService.qml` (733) | `brightness.setBrightness` (`:289`), `brightness.rescan` (`:477`), `brightness.getState` (`:489`), stream `brightness` | none | `brightness` |
| `BatteryService.qml` (878) | none | `Quickshell.Services.UPower` (`:6`, `:194-360`) | `battery` (QML would have to switch from UPower to a socket, or keep UPower) |
| `NotificationService.qml` (1554) | none found | `Quickshell.Services.Notifications` (`:7`), test sends via `notify-send` (`:1098`) | `notify` (decision needed: the shell hosts the notification daemon in-process) |
| `ClipboardService.qml` (483) | `clipboard.*` (`:79-398`) | `Process` (`:52`) | `clipboard` |
| `CupsService.qml` (746) | `cups.*` (`:237-627`) | none | `printers` (new) |
| `DgopService.qml` (742) | `dgop.meta` (`:294`, `:324`, `:342`), `dgop.gpu` (`:312`) | `Quickshell.Services.UPower` import (`:6`) | `sysinfo`, `process list` |
| `IdleService.qml` (201) | not inspected | not inspected | `session` **[unverified]** |
| `LocationService.qml` (85) | `location.getState` (`:80`) | none | `weather/location` |
| `WeatherService.qml` (1130) | none | `Process` fetches `http://ip-api.com/json/` (`:818`) and other fetches (`:702-902`) | `weather` (new). The IP lookup is a plain HTTP call from the shell, not via the core. |
| `SessionService.qml` (1058) | `loginctl.terminate` (`:469`), `loginctl.getState` (`:993`), `loginctl.setLockBeforeSuspend` (`:1003`), `loginctl.setSleepInhibitorEnabled` (`:1019`), `mime.getDefault` (`:310`) | `Process` running `uwsm`, `systemctl --user` (`:105-176`, `:353-413`) | `session`, `apps` |
| `SystemUpdateService.qml` (451) | consumes stream `sysupdate` (`DMSService.qml:352-353`); no `sendRequest` found in the fetched text | none found | `updates` (new) |
| `TailscaleService.qml` (239) | `tailscale.getStatus` (`:141`), `tailscale.refresh` (`:164`), `tailscale.*` (`:175`) | none | `network` (VPN) or out of scope |
| `WellbeingService.qml` (264) | `wellbeing.setState` (`:119`), `setLimits` (`:129`), `summary` (`:161`), `clear` (`:169`) | `Process` (not inspected) | out of scope or new (`wellbeing`) |
| `WlrOutputService.qml` (232) | `wlroutput.getState` (`:75`), `applyConfiguration` (`:120`), `testConfiguration` (`:149`) | none | `display` |
| `CalendarService.qml` (392) | none found | `Quickshell.Io` import only (`:6`) | out of scope **[unverified]** |

## 4. Gap analysis (DMS capability → Bleu service)

Status values: **covered** (a Bleu service exists in the plan), **needs new service**, **out of scope**. Entries marked [verify] depend on an unfetched file.

| DMS capability (where) | Bleu service | Status | Reason |
| --- | --- | --- | --- |
| Battery, UPower (`BatteryService.qml`, `DgopService.qml`) | battery | covered | Bleu battery provides the data. The QML side currently uses the UPower built-in, so the port must choose. |
| Power, session, lock, terminate, sleep inhibit (`loginctl.*`) | power, session | covered | Bleu session covers lock, unlock, idle hint, lock-before-suspend and the sleep inhibitor. |
| Network: Wi-Fi, Ethernet, cellular, VPN, hotspot, credentials prompts (`network.*`) | network | covered | Large surface (section 2.3). The credentials prompt flow (`network.credentials`) must be a stream plus submit/cancel. |
| Bluetooth: adapters, pairing, MPRIS publish (`bluetooth.*`, `bluetooth.pairing`) | bluetooth | covered | Pairing prompts go through a stream with submit/cancel tokens. |
| Audio: sinks, sources, card profiles, mono (`AudioService.qml`, `pactl`, `wpctl`) | audio | covered | Currently shells out to pactl/wpctl and uses the Pipewire built-in. No socket API exists for it in the core. |
| Brightness and DDC monitors (`brightness.*`) | brightness | covered | Includes the per-device `brightness.update` stream. |
| Display outputs: modes, position, scale, transform (`wlroutput.*`) | display | covered | Requires `wlr-output-management`. The Bleu `display` service must cover this. |
| Night light, gamma, ICC profiles (`wayland.gamma.*`, `wayland.icc.*`) | color | covered | Color transforms should go through the `color` service. |
| Theme auto (light/dark schedule and location) (`theme.auto.*`) | appearance | covered | Needs a `color`/`appearance` split. |
| Accent palette generation (`matugen.queue`, `matugen.status`) | appearance | covered (partial) | Depends on an external matugen binary. The handler was not read. |
| Color scheme and icon theme (`freedesktop.settings.*`) | appearance | covered | Via the freedesktop settings portal. |
| Wallpaper, rotation schedule (`wallpaper.*`) | wallpaper | needs new service | No Bleu service. Covers `setConfig`, `trigger`, and the schedule state. |
| Media: MPRIS players (`AudioService` → `MprisController`, `bluetooth.mpris.publish`, `mpris.command`) | media | covered | The `mpris.command` lease protocol must be ported. |
| Notifications: server, actions, `notify-send` (`NotificationService.qml`, `notify.*`) | notify | covered (decision) | The shell hosts the notification daemon in-process via the Quickshell built-in. A port must decide who owns `org.freedesktop.Notifications`. |
| Tray, StatusNotifierWatcher recovery (`trayrecovery`, SystemTray built-in) | tray | covered | The tray built-in was not fetched **[verify]**. |
| Apps: MIME defaults, browser/app picker (`mime.*`, `apppicker.open`, `browser.open_requested`) | apps | covered | Via xdg. |
| System info: CPU, memory, GPU, disks, processes, modules (`dgop.*`) | sysinfo | covered | The process list is part of `dgop.meta` (`procCursor`, `sort`). The disks API was not identified **[verify]**. |
| Process list (`dgop.meta` with `procCursor`) | sysinfo (process list) | needs new service | Process list is only a cursor-paged view in dgop. A dedicated `processes` API is needed. |
| Disks and mounts | sysinfo (disks) | needs new service | Not confirmed in the fetched DMS code. Shell widgets **[verify]**. |
| Clipboard history, pins, search, paste (`clipboard.*`) | clipboard | covered | History persistence and the search API are substantial. |
| Windows, workspaces, compositor integration (dwl/mango/niri/hyprland/sway) | windows | needs new service | No compositor-specific server module appears in the imports at `server.go:12-37`. Window state is likely in the shell's QML built-ins **[verify]**. |
| Secrets: Wi-Fi and VPN passwords, hotspot secrets (`network.hotspot.getSecrets`, `network.credentials.*`) | secrets | covered (prompt flow only) | No keyring service in the core. Secrets pass through the socket in cleartext JSON. |
| Hotkeys, global shortcuts | hotkey | out of scope **[verify]** | No hotkey module in the server imports. |
| Input: caps lock (`evdev.*`), keyboard layout | input | covered (partial) | Caps lock only. The keyboard layout API was not found. |
| Printers: queues, jobs, devices, PPDs, classes (`cups.*`) | printers | needs new service | Substantial surface (section 2.3). |
| Updates: distro and shell updates, releases (`sysupdate.*`) | updates | needs new service | Distinct from `sysinfo`. Includes a shell-self-update path. |
| Weather and location (`location.*`, `WeatherService.qml` → ip-api.com) | weather, location | needs new service (weather) | Location is covered by `location.getState`. Weather is QML-only and calls an external HTTP service. |
| Files, trash, previews (`files.*`, dankgo `files`) | files | needs new service | Not inspected. |
| Lock screen (`loginctl.lock`, `lockerReady`, the locker UI) | lock | covered (session) | The locker UI itself is QML **[verify]**. |
| Greeter and PAM | greeter | out of scope **[verify]** | No greeter code was found in the fetched server files. |
| Screen time and wellbeing (`wellbeing.*`) | wellbeing | out of scope or new | Not in the Bleu catalogue. |
| Tailscale (`tailscale.*`) | network (VPN) | out of scope or new | Requires `tailscaled` local API. |
| Lyrics (`lyrics.get`) | media | out of scope or new | Network provider lookups. |
| Generic D-Bus proxy (`dbus.*`) | dbus (bleu_dbus) | out of scope for the shell | The shell's raw D-Bus access. Decide whether the port exposes it at all. |
| Plugin and theme registry (`plugins.*`, `themes.*`, `registries.*`) | (none) | out of scope | DMS-specific ecosystem. |
| Screensaver inhibit (`freedesktop.screensaver`) | session | covered | Via the freedesktop ScreenSaver interface. |

## 5. Wire contract: state types (quoted)

These are the compatibility contract. Field names and `json` tags are exact.

```go
// core/internal/server/network/types.go:114-160 (abridged; all fields listed in the file)
type NetworkState struct {
	Backend                 string               `json:"backend"`
	NetworkStatus           NetworkStatus        `json:"networkStatus"`      // disconnected|ethernet|wifi|cellular|vpn
	Preference              ConnectionPreference `json:"preference"`         // auto|wifi|ethernet|cellular
	EthernetIP              string               `json:"ethernetIP"`
	WiFiEnabled             bool                 `json:"wifiEnabled"`
	WiFiSSID                string               `json:"wifiSSID"`
	WiFiSignal              uint8                `json:"wifiSignal"`
	WiFiNetworks            []WiFiNetwork        `json:"wifiNetworks"`
	SavedWiFiNetworks       []WiFiNetwork        `json:"savedWifiNetworks"`
	HotspotEnabled          bool                 `json:"hotspotEnabled"`
	VPNProfiles             []VPNProfile         `json:"vpnProfiles"`
	VPNActive               []VPNActive          `json:"vpnActive"`
	IsConnecting            bool                 `json:"isConnecting"`
	LastError               string               `json:"lastError"`
	VPNError                string               `json:"vpnError"`
	// ... cellular*, ethernet*, hotspot*, wiredConnections, connectingSSID, etc.
}
```

```go
// core/internal/server/loginctl/types.go:13-33
type SessionState struct {
	SessionID         string `json:"sessionId"`
	SessionPath       string `json:"sessionPath"`
	Locked            bool   `json:"locked"`
	Active            bool   `json:"active"`
	IdleHint          bool   `json:"idleHint"`
	IdleSinceHint     uint64 `json:"idleSinceHint"`
	LockedHint        bool   `json:"lockedHint"`
	SessionType       string `json:"sessionType"`
	SessionClass      string `json:"sessionClass"`
	User              uint32 `json:"user"`
	UserName          string `json:"userName"`
	RemoteHost        string `json:"remoteHost"`
	Service           string `json:"service"`
	TTY               string `json:"tty"`
	Display           string `json:"display"`
	Remote            bool   `json:"remote"`
	Seat              string `json:"seat"`
	VTNr              uint32 `json:"vtnr"`
	PreparingForSleep bool   `json:"preparingForSleep"`
}
```

```go
// core/internal/server/bluez/types.go:10-16
type BluetoothState struct {
	Powered          bool          `json:"powered"`
	Discovering      bool          `json:"discovering"`
	Adapters         []AdapterInfo `json:"adapters"`
	Devices          []Device      `json:"devices"`
	PairedDevices    []Device      `json:"pairedDevices"`
	ConnectedDevices []Device      `json:"connectedDevices"`
}
```

```go
// core/internal/server/brightness/types.go:21-37
type Device struct {
	Class          DeviceClass `json:"class"`
	ID             string      `json:"id"`
	Name           string      `json:"name"`
	Current        int         `json:"current"`
	Max            int         `json:"max"`
	CurrentPercent int         `json:"currentPercent"`
	Backend        string      `json:"backend"`
}
type State struct{ Devices []Device `json:"devices"` }
type DeviceUpdate struct{ Device Device `json:"device"` }
```

```go
// core/internal/server/wayland/types.go:51-64 (State)
type State struct {
	Config         Config                `json:"config"`
	CurrentTemp    int                   `json:"currentTemp"`
	NextTransition time.Time             `json:"nextTransition"`
	SunriseTime    time.Time             `json:"sunriseTime"`
	SunsetTime     time.Time             `json:"sunsetTime"`
	DawnTime       time.Time             `json:"dawnTime"`
	NightTime      time.Time             `json:"nightTime"`
	IsDay          bool                  `json:"isDay"`
	SunPosition    float64               `json:"sunPosition"`
	ICCProfiles    map[string]*ICCStatus `json:"iccProfiles"`
	OutputTemps    map[string]int        `json:"outputTemps"`
	Outputs        []string              `json:"outputs"`
	GammaRefused   []string              `json:"gammaRefused,omitempty"`
}
```

```go
// core/internal/server/clipboard/types.go:99-117
type Entry struct {
	ID          uint64    `json:"id"`
	Data        []byte    `json:"data,omitempty"`      // base64 on the wire
	MimeType    string    `json:"mimeType"`
	Preview     string    `json:"preview"`
	Size        int       `json:"size"`
	Timestamp   time.Time `json:"timestamp"`
	IsImage     bool      `json:"isImage"`
	Hash        uint64    `json:"hash,omitempty"`
	Pinned      bool      `json:"pinned"`
	AltData     []byte    `json:"altData,omitempty"`
	AltMimeType string    `json:"altMimeType,omitempty"`
}
type State struct {
	Enabled bool    `json:"enabled"`
	History []Entry `json:"history"`
	Current *Entry  `json:"current,omitempty"`
}
```

```go
// core/internal/server/sysupdate/types.go:88-104 (State, abridged)
type State struct {
	Phase            Phase         `json:"phase"`
	Backends         []BackendInfo `json:"backends"`
	Packages         []Package     `json:"packages"`
	Count            int           `json:"count"`
	IntervalSeconds  int           `json:"intervalSeconds"`
	LastCheckUnix    int64         `json:"lastCheckUnix,omitempty"`
	OperationID      string        `json:"operationId,omitempty"`
	RecentLog        []string      `json:"recentLog,omitempty"`
	Error            *ErrorInfo    `json:"error,omitempty"`
	Shell            ShellInfo     `json:"shell"`
	Reboot           RebootInfo    `json:"reboot"`
}
```

Other state types, abbreviated from section 2.3: `freedesktop.FreedeskState{accounts,settings,screensaver}` (`freedesktop/types.go:53-57`), `thememode.State{config,isLight,nextTransition}` (`thememode/types.go:19-23`), `wallpaper.State{config,nextRotation,cycleSeq,target}` (`wallpaper/types.go:18-23`), `wellbeing.State{today,limit,resync}` (`wellbeing/types.go:37-41`), `cups.CUPSState{printers map[string]*Printer}` (`cups/types.go:13-15`), `wlroutput.State{outputs,serial}` (`wlroutput/types.go:39-42`), `evdev.State{available,capsLock}` (`evdev/models.go:3-5`), `location.State{latitude,longitude}` (`location/types.go:10-12`), `tailscale.TailscaleState` (`tailscale/types.go:4-13`).

Go-side `json` quirks for a port:
- `[]byte` as base64 (clipboard `data`, `altData`).
- `time.Time` as RFC 3339 (wayland, clipboard, cups `timeCreated`).
- `omitempty` on pointer and optional fields. `null` appears for `currentMode`, `current`, `error`, and `map[string]*` values.
- `Result` is `*T` and written with `omitempty`, so a nil result is absent, not `null`.

## 6. Bleu contract mismatches (the port must resolve these)

From `docs/ARCHITECTURE.md:35-38` and `:62-63`:
1. **No pointers, unions, or optionals in state.** DMS uses `*OutputMode` (`wlroutput/types.go:32`), `*Entry` (`clipboard/types.go:115`), `*ICCStatus` in a map (`wayland/types.go:61`), `*Printer` in a map (`cups/types.go:14`), `*ErrorInfo` (`sysupdate/types.go:102`), and `*Package` (`sysupdate/types.go:84`). These need a nullable or `omitempty` representation in Bleu's JSON layer.
2. **Maps.** Several DMS states are keyed maps (`map[string]...`). Bleu's rule lists `String`s and slices only.
3. **Snapshot model matches.** DMS streams whole state values on every change (`forwardSubscription`, `subscription.go:18-32`), which matches Bleu rule 2 ("state is published, never mutated"). The DMS event wrappers are unused on the subscribe path.
4. **Transient streams.** DMS has no bounded broadcast with overflow reporting. Slow clients are disconnected after 30 s (`dankgo/ipc/writer.go:12-14`). Bleu rule 3 requires overflow reporting, so the port should keep this as a documented deviation or change it.
5. **Errors are strings.** DMS has no stable status number. Bleu rule 6 wants stable `Status` numbers for IPC. The QML client matches error text (`DMSService.qml:258`).

## 7. Priority list: the first 40 methods and events

Ordered by how much of the shell fails without them. Each row gives the source location.

1. `ping`: dankgo answers `{"pong":true}` (`dankgo/ipc/server.go:177-178`).
2. `getServerInfo`: `router.go:55`, `server.go:511-517`.
3. Handshake line with `apiVersion` and `capabilities` (`dankgo/ipc/server.go:143-153`).
4. `subscribe` with `services` and `clientId`: `server.go:534-817`, `DMSService.qml:177-193`.
5. Stream `server` with `ServerInfo`: `server.go:793-798`.
6. Stream `network` with `NetworkState`: `server.go:579-586`.
7. `network.getState`: `network/handlers.go:15`, `:153`.
8. `network.wifi.scan`: `handlers.go:17`, `:168`.
9. `network.wifi.networks`: `handlers.go:19`, `:172`.
10. `network.wifi.connect`: `handlers.go:21`, `:225`.
11. `network.wifi.disconnect`: `handlers.go:23`, `:240`.
12. `network.wifi.enable` and `disable`: `handlers.go:29`, `:31`, `:273`, `:281`.
13. `network.preference.set`: `handlers.go:51`.
14. Stream `network.credentials` with `CredentialPrompt`: `server.go:588-595`, `network/types.go:254`.
15. `network.credentials.submit`: `handlers.go:67`, `:134`.
16. `network.credentials.cancel`: `handlers.go:69`, `:149`.
17. Stream `loginctl` with `SessionState`: `server.go:597-604`.
18. `loginctl.getState`: `loginctl/handlers.go:13`, `:41`.
19. `loginctl.lock` and `unlock`: `handlers.go:15`, `:17`.
20. `loginctl.lockerReady`: `handlers.go:29`.
21. `loginctl.setLockBeforeSuspend`: `handlers.go:25`.
22. Stream `bluetooth` with `BluetoothState`: `server.go:651-658`, `bluez/types.go:10`.
23. `bluetooth.getState`: `bluez/handlers.go:25`, `:61`.
24. `bluetooth.setPowered`: `handlers.go:31`, `:196`.
25. `bluetooth.startDiscovery` and `stopDiscovery`: `handlers.go:27`, `:29`.
26. `bluetooth.connect` and `disconnect`: `handlers.go:37`, `:39`.
27. `bluetooth.pair`: `handlers.go:35`.
28. Stream `bluetooth.pairing` and `bluetooth.pairing.submit` / `cancel`: `server.go:673-680`, `handlers.go:51`, `:53`.
29. Stream `brightness` and `brightness.update`: `server.go:704-716`.
30. `brightness.getState` and `setBrightness`: `brightness/handlers.go:12`, `:14`.
31. Stream `freedesktop` and `freedesktop.screensaver`: `server.go:606-622`.
32. Stream `gamma` with `wayland.State`, plus `wayland.gamma.getState` and `setTemperature`: `server.go:624-631`, `wayland/handlers.go:19`, `:21`.
33. `wlroutput.getState`, `applyConfiguration`: `wlroutput/handlers.go:41`, `:43`.
34. Stream `clipboard`, `clipboard.getState`, `getHistory`, `copyEntry`, `deleteEntry`: `server.go:736-743`, `clipboard/handlers.go:17`, `:19`, `:31`, `:23`.
35. `clipboard.search`: `clipboard/handlers.go:41`, `:320`.
36. `evdev.getState` and stream `evdev`: `evdev/handlers.go:9`, `server.go:727-734`.
37. Stream `theme.auto` and `theme.auto.getState`: `server.go:633-640`, `thememode/handlers.go:18`.
38. `dgop.meta` (process list, CPU, memory): `dgop/handlers.go:23`, `:64`.
39. `sysupdate.getState` and stream `sysupdate`: `sysupdate/handlers.go:13`, `server.go:763-770`.
40. `mime.getDefault` and `mime.appsForMime`: `mime/handlers.go:39`, `:45`.

Next tier, if time allows: `cups.getPrinters` (`cups/handlers.go:26`), `wallpaper.getState` and `setConfig` (`wallpaper/handlers.go:19`, `:21`), `location.getState` (`location/handlers.go:16`), `notify.send` (`notifyactions/handlers.go:15`), `tailscale.getStatus` (`tailscale/handlers.go:13`), `wellbeing.getState` (`wellbeing/handlers.go:13`).

## 8. Open items

- Not fetched: `network/manager.go`, `bluez/manager.go`, `wayland/manager.go`, `clipboard/manager.go` (only types and handler lists were read). Method-level result semantics and event timing are unverified for these.
- Not fetched: the dankgo `files` package, the `dgop` external library, `matugen_handler.go` bodies (only routes at `router.go:72-73`), and `runtime.go` (38 lines, not read).
- The QML tree: only 21 `Services/` files. The Pipewire, Mpris, SystemTray and Quickshell built-in wiring is unverified.
- `DMS_SOCKET` (`DMSService.qml:38`) is set by code not fetched **[unverified]**.
- `dbusClientId` (`DMSService.qml:181`) is defined outside the fetched files **[unverified]**.
