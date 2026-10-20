# bleu_dbus

A D-Bus client and server in pure C3: no libdbus, sd-bus or GLib. It is the
protocol layer under the NetworkManager, BlueZ, UPower, logind, MPRIS,
notification, portal and Secret Service backends. The client reads and calls
services; the server (`bleu::dbus::server`) exports objects that other programs
call, such as a NetworkManager secret agent, a BlueZ agent, or a notification
daemon.

Module root `bleu::dbus`. Depends on `bleu_core`. Socket I/O is local to
`transport_posix.c3` for now (`bleu_rt` is not in the tree yet); Windows compiles
with every socket operation raising `UNSUPPORTED`. The server itself does no I/O:
it talks through a `Connection` or through any sink, so it is transport-neutral.

## Public API

Client:

- `value`: `Value`, the dynamic tree. Constructors `u32`, `str`, `path`, `variant`,
  `array`, `structure`, `dict_entry`; accessors `as_string`, `as_u32`, `as_f64` ...
  (look through variants); `dict_get(key)`, `at(i)`, `count()`, `unwrap()`.
- `marshal`: `Writer` and `Reader`, checked against the signature.
- `message`: `method_call`, `signal`, `reply`, `reply_to`, `error_reply`,
  `error_reply_to`; `Message.body_writer`, `attach_fd`, `reader`, `encode`, `release`.
- `connection`: `Connection.init`, `open_session`, `open_system`, `open_address`,
  `send`, `call` (blocking; it answers incoming method calls while it waits),
  `call_async`, `process`, `fd`, `has_pending_output`, `close`, `free`,
  `set_incoming_handler`, `watch_close` / `forget_close` (run when the connection
  closes). `begin_operation` / `end_operation` bracket the library's own multi-call
  operations; applications do not need them.
- `bus`: `request_name`, `release_name`, `subscribe`/`unsubscribe`, `watch_name`,
  `list_names`, `name_has_owner`, `get_name_owner`, `start_service_by_name`.
- `ownership`: `Connection.own_name(name, flags, on_acquired, on_lost, context)`
  returns an `OwnedName`; `release()` gives the name up or withdraws the queued request.
- `match`, `proxy` (`for_object`, `get_property`, `set_property`, `introspect`,
  `get_managed_objects`, `watch_properties`, `watch_objects` ...), `errors`, `signature`,
  `names`, `auth`, `address`.

Server (`bleu::dbus::server`):

- `ObjectServer`: `init(alloc)`, `attach(&connection)` (answers the connection's
  method calls from `process()`), `use_sink(sink, ctx)` (other transports, tests),
  `handle(call)`, `free()`.
- Objects: `export(path, Interface[])`, `unexport(path)`, `make_object_manager(path)`
  (GetManagedObjects; InterfacesAdded/Removed for objects below it),
  `register_fallback("/prefix/", Interface[])` (one table for every path under a prefix).
- Signals: `emit_signal(path, iface, member, Value[])`,
  `emit_properties_changed(path, iface, names)`.
- Deferred replies: `Call.defer_reply()` returns a `ReplyToken`;
  `ObjectServer.reply(token, Value[], fds)` and `reply_error(token, name, text)` answer it.
- `Interface { name, Method[], Property[], Signal[] }`. `Method { name, in_signature,
  out_signature, in_names, out_names, handler, context }`. `Property { name, signature,
  access (READ, WRITE, READ_WRITE), changes (EMITS_CHANGED, INVALIDATES, CONST, NEVER),
  get, set, context }`. `Signal { name, signature, arg_names }`.
- Handlers: `fn void?(void* context, Call* call)`. `Call` has `reader()`,
  `reply(Value[], fds)`, `reply_error(name, text)`, `defer_reply()`, and `server`.
- `introspection(path, alloc)`, `has_node(path)`, `error_name_for(fault)`.

Routing of an incoming call: Peer and Introspectable.Introspect on any path; then the
object (exact export, else the longest matching fallback); its standard interfaces
(Properties, ObjectManager); then its own interfaces. The body's signature must equal
the method's in-signature, or the call gets `org.freedesktop.DBus.Error.InvalidArgs`.
Unknown path, interface or method: `UnknownObject`, `UnknownInterface`, `UnknownMethod`.
A handler that returns a fault gets the D-Bus name `error_name_for` gives its class
(AccessDenied for PERMISSION_DENIED, InvalidArgs for INVALID_ARGUMENT, ServiceUnknown
for UNAVAILABLE, and so on; the mapping is the reverse of `errors.c3`). A handler that
has a name of its own calls `call.reply_error`. Calls sent with NO_REPLY_EXPECTED get
no reply at all. A reply whose body does not match its out-signature is replaced by
`org.freedesktop.DBus.Error.Failed`, so a handler cannot send a malformed message.

Properties: Get, Set and GetAll follow the access rules; Set on a read-only property is
`PropertyReadOnly`; Get on a write-only property is `UnknownProperty`. A successful Set
announces the property if its rule says so: the setter must not emit for a change that
came from D-Bus. `emit_properties_changed` reads the getters for the properties it names.

Introspection: the XML lists the standard interfaces (Peer, Introspectable, Properties,
as sd-bus does), the object's interfaces, ObjectManager for a root, and child nodes.
It validates against the introspection DTD (see Verified how). GetManagedObjects lists
each object's own interfaces only (sd-bus also lists the three standard ones there).

Ownership: `own_name` follows the bus's queueing rules. `DO_NOT_QUEUE` on a taken name
fails with `BUSY`. A queued request is granted later, and `on_acquired` runs when the
bus hands the name over. A name taken by a replacing request is reported through
`on_lost`. `on_acquired` runs once per grant, whether the grant is announced by the
reply to RequestName or by the NameAcquired signal. When the connection closes, a held
name is lost: `held` becomes false and `on_lost` runs once, with the connection already
closed. A queued request dies with the connection, and nothing is reported for it:
reopen the connection and request the name again. `release()` after a close does not
send ReleaseName, because the bus has already let the name go.

Threading and handler rules. Everything runs on the connection's thread. Handlers (for
replies, signals, incoming calls, names and closes) run in three places only:
* inside `Connection.process()`;
* at the end of the outermost public operation that read from the socket (`call`,
  `open_address`, the bus methods, `own_name`, `OwnedName.release`), once that
  operation's own steps are complete, never between two of its steps;
* for an incoming method call, inside the blocking `call` that received it, because the
  peer may be waiting for the answer. The answer is sent there and then.

While a handler runs, nothing else is dispatched. `process()` is refused from a handler
(`INVALID_STATE`); `close()` from a handler ends the connection at once and drops the
rest of the queue. Signals and other replies read during a blocking call run when it
returns (or at the next `process()`). A reply to an outer blocking call that is read
while an inner one waits is kept for the outer call.

`process()` makes at most 16 socket reads per call, so a poller must be level-triggered
(poll(2), as `bleu_rt` uses; with epoll, the level-triggered mode): the descriptor stays
readable while data is left. A read never spans two messages, so a descriptor attaches to
the message whose first byte it arrived with. A message's UNIX_FDS field must equal the
number of descriptors that arrived with it, or the connection is closed with PROTOCOL.

The descriptors of a reply must stay open until the reply is sent (until
`has_pending_output()` is false).

## Not done

- Authorization. The server hands every caller to the handler, with `call.sender`;
  deciding who may call is the handler's job (or the bus policy's).
- Reconnection. A reconnect keeps the exports and the incoming handler, but does not
  request names again or re-subscribe the ownership handlers. Deferred replies are not
  discarded when the connection drops: a reply made later is addressed to the caller's
  old unique name, which the bus no longer has. Answer deferred calls before the
  connection closes.
- Fallbacks are not listed by Introspect or GetManagedObjects (their members are not known).
- Method calls with no interface name are routed to the first interface that has the member.
- Incoming method calls that arrive while a blocking call waits are answered through the
  incoming handler, or with UnknownMethod when there is none. A handler that makes its own
  blocking call is supported; the nesting is bounded by the stack.
- A reply's error text is made valid UTF-8 (invalid bytes become U+FFFD, NUL included) and
  cut at 1024 bytes; the specification sets no limit, so long texts lose their tail.
- `Writer.end_array` that refuses an array longer than 2^26 bytes leaves the writer
  unfinishable: discard it.
- `Connection.free` does not release `OwnedName`s: release them before the connection.
- Server-side Monitoring (BecomeMonitor), the Stats and Verbose interfaces.
- TCP, nonce-tcp, autolaunch, launchd, systemd and unixexec addresses: `UNSUPPORTED`.
- Windows and macOS sockets are compiled, not run. Windows has no D-Bus transport.
- `bleu_rt`: the transport does not use it yet; switching is one file (`transport_posix.c3`).
- Typed getters are methods for four types, not `get{T}` generics.
- Match rules: `arg0namespace`, `arg0path`, `eavesdrop` are not supported; `arg0`-`arg7` are.

## Verified how

- **Run** (Linux x86-64, C3 0.8.5_1, dbus-daemon 1.14.10, python-dbus-next 0.2.3):
  - Unit tests (`tests/unit`, 92 tests, `compile-test`): the client tests, mutation
    fuzzing of the Reader (200 000 inputs) and of whole messages (100 000), golden vectors
    from python-dbus-next and the specification, and the server tests (Introspect XML,
    argument checks, routing errors, Properties Get/Set/GetAll, NO_REPLY_EXPECTED,
    deferred replies, Peer, validation of descriptions, fallbacks, ObjectManager,
    signal emission, error-name round trip, a failure after deferring, error texts that
    are not UTF-8, trailing bytes). The server tests drive the server through a recording
    sink. The connection tests (`connection_test.c3`) play the bus through one end of a
    socketpair: a failed read, a failed send, descriptor attribution, the read budget,
    answers to incoming calls during a blocking call, and re-entry from a handler. They
    need no bus.
  - `tests/integration.sh` against a private dbus-daemon, on an abstract and a filesystem
    socket: the client suite (56 checks per socket, including name ownership across a
    close: one grant announced once, `held` cleared and `on_lost` run on close, the queued
    request granted); the **object server** suite (41 checks
    per socket): `server_main.c3` exports `org.bleu.Test`, `server_client.py` (dbus-next)
    calls every method, reads and writes properties, receives PropertiesChanged, the custom
    Notice signal, InterfacesAdded and InterfacesRemoved, sends and receives descriptors,
    checks the standard errors and a deferred reply, and parses the introspection XML
    through dbus-next's proxies; then `server_client.c3` (the existing C3 client) calls the
    same server, checks that a second owner is refused with BUSY, queues for the name, sees it
    granted when the server exits, and sees NameLost when a replacing request takes it.
  - `tests/integration.sh`, notifications example: `examples/notifications_server_sketch.c3`
    exports `org.freedesktop.Notifications` (GetServerInformation, GetCapabilities, Notify,
    CloseNotification, NotificationClosed, ActionInvoked), checked by `notifications_client.py`
    (8 checks).
  - Introspection DTD: the XML from the live server and the notification example validates
    with `xmllint --dtdvalid` against `https://dbus.freedesktop.org/doc/introspect.dtd`; a
    deliberately wrong document is rejected by the same DTD.
- **Compiled only**: all six targets through `tools/check.sh bleu_core bleu_dbus` (the
  server and ownership code is transport-neutral and compiles for the Windows and macOS
  targets too, but is not run there).

Run the tests (from a scratch directory, since c3c writes `out/` in its working directory):

    c3c --libdir "$(tools/libdir.sh)" --lib bleu_core --lib bleu_dbus compile-test libs/bleu_dbus.c3l/tests/unit/*.c3
    libs/bleu_dbus.c3l/tests/integration.sh
