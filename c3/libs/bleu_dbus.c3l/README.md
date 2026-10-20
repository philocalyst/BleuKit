# bleu_dbus

A D-Bus client in pure C3: no libdbus, sd-bus or GLib. It is the protocol layer
under the NetworkManager, BlueZ, UPower, logind, MPRIS, notification, portal and
Secret Service backends. Server-side object export is not built yet; the message,
signature and dispatch layers are designed for it (see `docs/research/bleu_dbus.md`).

Module root `bleu::dbus`. Depends on `bleu_core`. Socket I/O is local to
`transport_posix.c3` for now (`bleu_rt` is not in the tree yet); Windows compiles
with every socket operation raising `UNSUPPORTED`.

## Public API

- `value`: `Value`, the dynamic tree. Constructors `u32`, `str`, `path`, `variant`,
  `array`, `structure`, `dict_entry`; accessors `as_string`, `as_u32`, `as_f64` ...
  (look through variants); `dict_get(key)`, `at(i)`, `count()`, `unwrap()`.
- `marshal`: `Writer` (`init`, `append_*`, `begin_/end_` array, struct, dict entry,
  variant, `append_value`, `finish`, `bytes`) and `Reader` (`init`, `read_*`,
  `begin_/end_*`, `read_value`, `skip_value`, `has_more`, `finish`). Both are checked
  against the signature.
- `message`: `method_call`, `signal`, `reply`, `error_reply`; `Message.body_writer`,
  `attach_fd`, `reader`, `encode`, `release`; `parse`, `frame_length`.
- `connection`: `Connection.init`, `open_session`, `open_system`, `open_address`,
  `send`, `call` (blocking), `call_async`, `process`, `fd`, `has_pending_output`,
  `close`, `free`.
- `bus`: `request_name`, `release_name`, `subscribe`/`unsubscribe`, `watch_name`,
  `list_names`, `name_has_owner`, `get_name_owner`, `start_service_by_name`.
- `match`: `Match` builder (`with_type`, `with_sender`, `with_interface`, `with_member`,
  `with_path`, `with_path_namespace`, `with_destination`, `with_arg`).
- `proxy`: `for_object`; `Proxy.new_call`, `get_property`, `set_property`,
  `get_all_properties`, `get_managed_objects`, `introspect`, `get_string`, `get_u32`,
  `get_i32`, `get_bool`, `watch_properties`, `watch_objects`.
- `errors`: `for_name`, `from_reply` (D-Bus error names as `bleu::error` excuses).
- `signature`, `names`, `auth`, `address`: grammar and validation, SASL, bus addresses.

## Not done

- Server-side export: objects, method dispatch to handlers, `Properties.Set` on exported
  objects, `ObjectManager` export. Incoming calls other than Peer.Ping get `UnknownMethod`.
- Peer.GetMachineId (answered `UnknownMethod`).
- TCP, nonce-tcp, autolaunch, launchd, systemd and unixexec addresses: `UNSUPPORTED`.
- Windows and macOS sockets are compiled, not run. Windows has no D-Bus transport.
- `bleu_rt`: the transport does not use it yet; switching is one file (`transport_posix.c3`).
- Typed getters are methods for four types, not `get{T}` generics.
- Match rules: `arg0namespace`, `arg0path`, `eavesdrop` are not supported; `arg0`-`arg7` are.
- Monitoring (BecomeMonitor) and the Stats and Verbose interfaces.
- `docs/C3_GOTCHAS.md` is not appended (this library does not own it); the list is in the
  research record.

## Verified how

- **Run** (Linux x86-64): unit tests (`tests/unit`, 67 tests, `c3c compile-test`) including
  mutation fuzzing of the Reader (200 000 inputs) and of whole messages (100 000); golden
  vectors from python-dbus-next 0.2.3 and from the specification; `tests/integration.sh`
  against a private dbus-daemon 1.14.10 (abstract and filesystem sockets) with a
  python-dbus-next mock service, 49 checks per run, plus a disconnect test.
- **Compiled only**: all six targets through `tools/check.sh bleu_core bleu_dbus`.
- **Assertion**: a `Connection` used from another thread aborts in debug builds.

Run the tests:

    c3c --libdir libs --lib bleu_core --lib bleu_dbus compile-test libs/bleu_dbus.c3l/tests/unit/*.c3
    libs/bleu_dbus.c3l/tests/integration.sh
