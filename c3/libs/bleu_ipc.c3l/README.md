# bleu_ipc

A server and a client for the DMS IPC protocol: newline-delimited JSON requests
and replies over a Unix socket, with subscriptions that stream state. It is what
the `dmsd` daemon uses to serve the unmodified DankMaterialShell QML shell, and
it is wire-compatible with dankgo's `ipc` package (`dankgo/ipc`) and DMS's
`server` service. Module root `bleu::ipc` (server), `bleu::ipc::client`
(client), `bleu::ipc::wire` (frame builders). POSIX only: the library compiles
empty on Windows and macOS builds alike. Depends on `bleu_core` and `bleu_rt`.

Sources, with line numbers, and every decision: `docs/research/bleu_ipc.md`.

## Public API

```c3
ipc::Server server;
server.init(mem, { .app_name = "dmsd", .api_version = 38, .capabilities = caps })!;
ipc::Topic* network = server.register_topic("network")!;          // before start
server.register_method("getState", &get_state, &ctx)!;              // before start
server.start()!;                                                    // binds, starts threads
network.publish("{\"wifiEnabled\":true}")!;                         // any thread, any time
server.notify_capabilities_changed();                               // a `server` frame to all
server.stop();  server.free();
```

* `Config` fields left at zero take their defaults: `workers` 4, `max_line` 64 MiB,
  `write_stall` 30 s, `max_queued_bytes` 32 MiB, `max_clients` 64. The socket is
  `$XDG_RUNTIME_DIR/<app_name>-<pid>.sock` unless `socket_path` is set.
* `Handler = fn void(void* context, Call* call)`; `Call` has `method`, `params`
  (`Object*`, never null), `id`. Answer with `call.respond_raw(json)` (a JSON
  value on one line) or `call.respond_error(text)`. Both are `void?` and
  `@maydiscard`: a second answer returns `INVALID_STATE` and sends nothing.
* `call.defer_reply()` returns a `Deferred` that completes the request later from
  any thread, with `respond_raw` or `respond_error`.
* `Topic.publish(json)` replaces the state (and the snapshot a new subscriber
  receives first). `Topic.publish_event(json)` sends one occurrence and keeps
  nothing. `TopicOptions{ .explicit_only = true }` leaves a topic out of `"all"`.
* `server.subscriber_count(topic)`: how many subscriptions want the topic.
* `ipc::client::Client`: `connect(alloc, path, timeout)`, `request(method,
  params_json, timeout)` (returns the reply line), `subscribe(services, timeout)`
  (returns the subscription id), `next_line(timeout)`, `free()`.

Example, a method that defers its answer to another thread:

```c3
fn void get_state(void* context, ipc::Call* call)
{
	ipc::Deferred later = call.defer_reply();   // return now; answer from a worker
	start_scan(later);                          // later.respond_raw("{...}") when done
}
```

## Threads

One I/O thread owns the listener, every connection, every outbox and every
subscription; nothing else touches them. It parses requests, answers `ping` and
`subscribe` itself, and sends other methods to `workers` handler threads, each
with its own mailbox. A blocking handler stalls only its own thread. Publishers
take the topic's mutex, store the snapshot and post the fan-out in the same
critical section, so the I/O thread sees publications in the order they were
made. `Server.stop` closes clients, then joins the handler threads, which means a
running handler must return first.

## DMS behaviours implemented

* Socket `$XDG_RUNTIME_DIR/<app>-<pid>.sock`, mode 0600; sockets of dead
  processes with the same app name are removed at start.
* Handshake line `{"apiVersion":N,"capabilities":[...]}` with no id, sent on accept.
* Requests `{"id":int,"method":"...","params":{...}}`, one per line; a trailing CR
  is dropped; an absent id is 0, an absent or null params is `{}`.
* Replies `{"id":N,"result":...}` or `{"id":N,"error":"text"}`; a zero id is left out.
* `ping` answers `{"pong":true}` before any handler.
* `unknown method: <name>` for an unregistered method; `unsubscribe` is unknown, as in DMS.
* Malformed JSON, a non-object request, or a field of the wrong type gets
  `invalid json: ...` with no id, and the connection stays open.
* `subscribe` with `params.services`: empty, absent or non-string means every
  topic not explicit-only; `"all"` means the same; a named explicit-only topic is
  included only when named; unknown names are ignored.
* A subscription's first frame is the `server` service with `ServerInfo`, carrying
  the subscribe id. Then one snapshot per wanted topic that has one, in topic
  order. Then one frame per publication. Every frame carries the subscribe id.
* `notify_capabilities_changed` sends a `server` frame on every subscription.
* A request line longer than `max_line` closes the connection, as dankgo does.
* A client that leaves its output unread for `write_stall` is disconnected.

## Not reproduced, and why

* **`defer` is `defer_reply`.** `defer` is a C3 keyword.
* **Zero ids are omitted, not `"id":0`.** The brief's example showed `"id":0` for
  a malformed line. dankgo declares `ID int` with `omitempty`
  (`ipc/models.go:13` and `:19`), so Go drops a zero id. The wire follows the source.
  Both forms are dropped by the DMS QML client, which keys on `id` and `result`.
* **Invalid UTF-8 is refused.** Go replaces bad bytes with U+FFFD and carries on,
  which changes data silently. Here the line gets `invalid json: input is not UTF-8`.
* **Nesting deeper than 64 levels is refused.** The std JSON parser's limit.
  dankgo has no such limit. Request params are never that deep in practice.
* **Overflow disconnects; it is not reported in-band.** A publication that does
  not fit the client's queue (`max_queued_bytes`), or an event the client cannot
  take, closes the connection. The DMS wire has no overflow message. The client
  reconnects and re-reads the snapshot, which is the cure Bleu's rules name.
* **State frames coalesce (latest wins).** A slow client receives only the newest
  value of each state, so memory stays bounded. DMS queues every value in a
  256-entry channel per service. This is the deviation the brief asked for.
* **At most 64 clients, and at most 256 queued requests per handler thread.**
  DMS has neither limit. Past them a client is refused, or gets `server is busy`.
* **`XDG_RUNTIME_DIR` must be set, or a socket path given.** DMS falls back to
  `/run/<app>` or `/var/run/<app>` for root and to the temp directory otherwise
  (dankgo `paths/paths.go:30-47`).
  A silent fallback would put the socket where clients do not look, so this fails
  with `UNAVAILABLE`.
* **A process that exists but belongs to someone else keeps its socket.**
  `EPERM` counts as alive. DMS treats any signal error as dead (`ipc/server.go:254-263`).
* **`clientId` is accepted and not used.** DMS uses it only to key its D-Bus
  signal subscriptions, which this server does not provide.
* **`cliVersion` is never sent.** It is `omitempty` in DMS, and there is no CLI version here.
* **Escaping is not byte-identical to Go's.** `<`, `>`, `&`, U+2028 and U+2029 are
  written as they are. Every JSON parser reads both forms the same way.
* **Domain methods are not here.** Only `ping` and `subscribe` are built in; every
  other method is registered by the daemon.
* **The `dankgo` bus envelope `{"event":...}` is not produced.** The DMS subscription path does not use it (research notes section 1).

## Verified how

* **Run on Linux x86-64, C3 0.8.5, glibc:** `c3c compile-test` of every
  `src/*.c3` file, 63 in-process tests: wire, line buffer, outbox (coalescing,
  bounds, in-flight frames), the handshake and ping, errors and bad lines,
  subscriptions (ordering, snapshots, `all` and explicit topics, events), subscriber
  counts, deferred replies from another thread, the exactly-once rule, the
  write-stall disconnect (a client that never reads, 512 KiB states), oversize
  lines, lifecycle refusals, and 1200 concurrent publications from three threads
  with a check that every subscriber's final frame is the last value published.
  The rt suites run in the same binary and pass.
* **Run, raw sockets:** `libs/bleu_ipc.c3l/tests/run.sh` runs
  `tests/raw_protocol.py` (Python 3, stdlib only) against the in-process server
  from `tests/protocol_driver.c3`. Eight checks: handshake, ping, error lines,
  ids up to 2^53, partial and pipelined writes, CRLF, `unsubscribe`, params,
  over-long lines, subscription ordering with two clients, and capability frames.
* **Sanitiser:** `--sanitize=address` with `LD_PRELOAD` of libasan (the C3 test
  binary needs the runtime first). See `docs/research/bleu_ipc.md` section 9 for
  the result and the bug it found.
* **Compiled only:** all six targets with `tools/check.sh bleu_core bleu_rt bleu_ipc`.
  On the non-POSIX targets every file is gated out and the library is empty.
