# bleu_registry

The table that makes every Bleu service reachable by name. Module root
`bleu::registry`. It holds one `Spec` per service (open, close, state,
capabilities, backend, watch, and the service's commands), a `Slot` for one opened
or refused service, and the `SERVICES` table. `bleud` serves the table over IPC;
`bleuctl --embedded` runs it in-process. Adding a service is one file
`src/svc_<name>.c3` (an open adapter, a command list and a `Spec`) plus one line in
`table.c3`.

**Linking this library links every service.** `SERVICES` names all twenty
`bleu::<service>` libraries, so a program that uses the registry pulls in every
service's dependencies, including the ones it never opens. A shell that wants one
service should link that service's library directly.

## Public API

```c3
registry::Slot slot;
slot.open(&svc_battery::BATTERY, mem, { .root = "" })!;   // refusal: the reason is kept
defer slot.close();
slot.write_state(&out)!;                // {"ok":true,"generation":n,"state":...}
slot.write_capabilities(&out)!;         // {"ok":true,"capabilities":[{"cap","reason","note"}]}
slot.backend()!;                        // "sysfs", "upower", ...
slot.watch(&sink, context)!;            // sink(context, text) for each state, from the worker thread
slot.call("brightness.set", params, &out)!;   // a command; params is a json::read::Params
slot.write_summary(&out)!;              // {"name","summary","open","backend" | "reason"}
registry::open_selected(slots[..], "battery,sysinfo", mem, options)!;
registry::index_of_service("battery")!;
registry::default_socket_path(mem)!;    // $XDG_RUNTIME_DIR/bleud.sock
registry::SERVICES[i];                  // Spec*, table order; registry::SERVICE_COUNT = 20
```

* `OpenOptions.root` is passed to every service; services without a fake-tree option ignore it.
* A command gets a `Request` (handle, params, writer, timeout) and writes `{"ok": true, ...}`.
  `registry::await` waits for its `Operation` and cancels it on timeout; the default
  timeout is `DEFAULT_TIMEOUT` (10 s) unless a `Command.timeout` is set.
* `registry::write_value(out, "key", value)` writes a reply with one value, enums as lower_snake.
* `registry::parse_enum{Enum}(text)` reads an enum from its lower_snake name.
* Secrets: the keyring has no change events in `bleu_secrets`, so its topic is refused
  with `UNSUPPORTED`. Secret values are returned only in the reply of `secrets.read`.

## How a service is added

1. `src/svc_<name>.c3`: `open(allocator, OpenOptions)` returning `void*?` (the handle);
   one function per command; a `Command[N]` table; a `const Spec` naming
   `live::close`, `live::state`, `live::capabilities`, `live::backend` and
   `tap::watch` instantiated with the service's handle, state and `Cap` types.
2. `src/table.c3`: import the file and add its `Spec` to `SERVICES`; bump `SERVICE_COUNT`.
3. `manifest.json`: add the service library to `dependencies`.

The generic adapters (`live.c3`, `tap.c3`, `state_json.c3`) are instantiated per service;
the service supplies only its types. `tap` is separate from `live` because a service
without a watch (the keyring) must not have it instantiated.

## Not done

* Lazy opening: services open when the registry is asked to open them at start.
* Transients (`Reader{Event}` streams) are not exposed; only the state.
* A service that fails to open reports its reason; its capabilities are not synthesised.
* The commands are a curated set (60 of the services' methods); several are not
  present: `display.apply` (needs a reader for the array of output changes),
  `power.inhibit` and `power.hold_profile` (they return a handle that must outlive
  the request, and IPC has no disconnect callback), `network.set_autoconnect`,
  `audio` stream and port commands, `bluetooth` trust, block and rename, `clipboard.set`
  with representations, `windows` minimise, toggle floating and fullscreen.
* The secrets topic is unsupported until `bleu_secrets` has change notifications.

## Verified how

* Linux, executed: `apps/bleud/tests/run.sh` builds `bleud` and `bleuctl` against this
  library and runs `check_bleud.py` (20 checks): the table, state and capability replies,
  commands and errors, a watch over a fake sysfs tree, 25 concurrent clients, a client
  that hangs up, SIGTERM, and sysinfo on the real system. Commands on the D-Bus services
  were exercised only for their error replies on this machine (no bus).
* Compile only: `tools/check.sh` over this library's closure is clean on linux-x64,
  linux-aarch64, macos-x64 and macos-aarch64. On windows-x64 and windows-aarch64 the
  closure fails in `bleu_media` (`smtc_backend.c3:528`), not in this library.
