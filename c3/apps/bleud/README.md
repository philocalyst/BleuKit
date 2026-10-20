# bleud

Bleu's daemon. It opens Bleu's services and serves each one over the line-JSON IPC
protocol of `bleu_ipc` (the same wire as `dmsd`), with a uniform set of methods and a
state topic per service. The service table and the command set are in
`libs/bleu_registry.c3l`. Its client is `apps/bleuctl`.

```
bleud [--services a,b,c] [--fake-root DIR] [--socket PATH]
bleud --list [--services a,b,c] [--fake-root DIR]
```

* `--list` opens the selected services (default: all) and prints each one with its
  backend, or with the reason it could not open, then exits.
* `--services` names the services to open. The rest are reported as `not selected`.
* `--fake-root` gives every service with a fake-tree option (battery, brightness,
  sysinfo, apps, display, network, bluetooth) a prefix instead of `/`. Tests use it.
* `--socket` replaces `$XDG_RUNTIME_DIR/bleud.sock`.
* SIGINT or SIGTERM stops it cleanly: the server stops, then each service closes.

## Protocol

One request per line: `{"id": N, "method": "...", "params": {...}}`. The handshake on
connect is `{"apiVersion":1,"capabilities":["services","topics","commands"]}`. Replies:

* a result: `{"id":N,"result":{"ok":true, ...}}`;
* an error: `{"id":N,"error":"<STATUS>: <message>"}`, where STATUS is the Bleu status
  name (`UNAVAILABLE`, `NOT_FOUND`, `INVALID_ARGUMENT`, `TIMEOUT`, ...).

Methods, for every service `<svc>`:

* `<svc>.state` → `{"ok":true,"generation":n,"state":{...}}`: the whole state, as bleu_json writes it.
* `<svc>.capabilities` → `{"ok":true,"capabilities":[{"cap","reason","note"}, ...]}`.
* `<svc>.backend` → `{"ok":true,"backend":"sysfs"}`.
* Topic `<svc>`: subscribe to it (`subscribe` with `services`) and receive one frame per
  state, `{"id":N,"result":{"service":"<svc>","data":{"generation":n,"state":{...}}}}`,
  starting with the current state. A new state replaces an unread one.
* `services` → `{"ok":true,"services":[{"name","summary","open","backend" | "reason"}]}`.

Commands are `<svc>.<verb>` with the parameters in `{...}`:

| Service | Commands |
| --- | --- |
| battery | `refresh` |
| power | `set_profile {profile}`, `perform {action}` |
| network | `scan`, `connect {ssid, passphrase?, autoconnect?}`, `disconnect`, `forget {ssid}`, `set_radio {enabled}`, `credentials.submit {request, secret}`, `credentials.cancel {request}` |
| bluetooth | `power {adapter, on}`, `discovery {adapter, on}`, `pair`, `connect`, `disconnect`, `remove` (each `{device}`), `pairing.reply {request, accept, secret?}`, `refresh` |
| audio | `set_volume {flow, id, volume}` (every channel to one value), `set_mute {flow, id, muted}`, `set_default {flow, id}` |
| brightness | `set {device, level, policy?, mechanism?}`, `refresh` |
| display | `refresh` |
| color | `set_temperature {output?, kelvin}`, `set_dim {output?, level}`, `reset` |
| media | `play`, `pause`, `play_pause`, `next`, `previous` (each `{player}`), `seek {player, offset_us}` |
| notify | `close {id, reason?}`, `invoke {id, key}`, `dnd {on}`, `clear_history` |
| tray | `activate`, `secondary_activate`, `context_menu` (`{item, x?, y?}`), `scroll {item, delta, horizontal?}` |
| session | `lock`, `unlock` |
| apps | `launch {app_id, action?}`, `search {query, limit?}` |
| sysinfo | `kill {pid, mode?}` (`terminate` or `force`) |
| clipboard | `set_text {slot?, text}`, `fetch {id, mime}` (base64) |
| windows | `focus`, `close` (each `{window}`), `switch_workspace {workspace}` |
| secrets | `store {service, account, value}`, `read {service, account}` (the value, base64, in the reply only), `delete {service, account}` |
| appearance | `set_color_scheme {scheme}`, `set_wallpaper {path}` |
| hotkey | `register {id, description?, chord}`, `unregister {id}` |
| input | `switch {layout}`, `next` |

A command waits for its operation up to 10 s, then cancels it and reports `TIMEOUT`.
Parameters of the wrong type or missing are `INVALID_ARGUMENT`.

## Not done

* Lazy opening: every selected service opens at start; a service that fails stays closed
  and its requests say why.
* Client disconnect does not cancel an operation: the IPC server has no disconnect
  callback. Operations are cancelled on their own timeout.
* Transient events (`Reader{Event}`) are not streamed; the state topic is the interface.
* The secrets topic is `UNSUPPORTED` (see `bleu_registry`).
* Windows: `serve` raises `UNSUPPORTED` because the IPC protocol needs Unix sockets. The
  Windows build is compile-checked only (see below); `--list` is not run there.
* The command set is curated (see `bleu_registry`'s "Not done").

## Verified how

* Linux, executed: `apps/bleud/tests/run.sh` (20 checks against a fake sysfs tree, a fake
  backlight, the real procfs and this machine's D-Bus-less state). Also run by hand:
  `sysinfo.kill` against a real `sleep` process; `apps.search`; `appearance.set_color_scheme`
  through gsettings; error replies from the D-Bus services.
* Compile only: `tools/check-app.sh bleud` is clean on linux-x64, linux-aarch64, macos-x64 and
  macos-aarch64. windows-x64 and windows-aarch64 fail in `bleu_media`.
