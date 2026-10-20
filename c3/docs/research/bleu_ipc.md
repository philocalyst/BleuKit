# bleu_ipc: the DMS IPC protocol, server and client

Research and decision record for `libs/bleu_ipc.c3l`. Each wire fact below cites
its source; line numbers were checked against the raw files on 2026-10-20 from
`raw.githubusercontent.com` (master). Base URLs:

* dankgo: `https://raw.githubusercontent.com/AvengeMedia/dankgo/master/` (files `ipc/server.go`, `ipc/writer.go`, `ipc/models.go`, `ipc/mux.go`, `paths/paths.go`)
* DMS: `https://raw.githubusercontent.com/AvengeMedia/DankMaterialShell/master/core/internal/server/` (files `server.go`, `subscription.go`)

Read with `docs/research/dms_surface.md` sections 0-2 and 7, which this note
corrects in one place (section 2.4 below).

## 1. Scope

The `dmsd` daemon must speak this protocol so that the unmodified DMS QML shell
can talk to it. The library provides the server (socket, handshake, requests,
handler pool, topics, subscriptions, the write-stall rule) and a client for tests
and `bleuctl`. It does not provide any DMS method: those belong to the daemon's
modules.

## 2. Wire contract, verified

### 2.1 Socket

* Path: `$XDG_RUNTIME_DIR/<app>-<pid>.sock`, `dankgo/paths/paths.go:51` (`SocketPath`), from `SocketDir` at `:30-47`. Without `XDG_RUNTIME_DIR`, root gets `/run/<app>` (or `/var/run/<app>`), other users get the temp dir (`:44-47`).
* Mode 0600 after listen: `dankgo/ipc/server.go:78`. A file already at the path is removed first: `:72`.
* Stale sockets: at `Listen`, files `<app>-<digits>.sock` whose pid is dead are removed: `dankgo/ipc/server.go:224-252`. "Dead" means `os.FindProcess` + `Signal(0)` returns an error (`:254-263`).

### 2.2 Handshake

On accept, before anything is read, the server writes one line:
`{"apiVersion":N,"capabilities":[...]}` with a newline and no id.
`dankgo/ipc/server.go:140-153` (`json.NewEncoder(conn).Encode(caps)`).
The struct: `dankgo/ipc/models.go:7-10` (`Capabilities`). The DMS value is computed per
connection: `CapabilitiesFunc` at `core/internal/server/server.go:930`, `getCapabilities` at `:429-509`. `APIVersion = 38` at `server.go:42`.

### 2.3 Requests

One JSON object per line. `dankgo/ipc/server.go:162-172`: `bufio.Scanner` with a
64 KiB initial buffer (`:163`) and the configured maximum. A line longer than the
maximum ends the scan, and the connection closes (`:164-172`, the loop exits and
`handleConnection` returns, which closes the connection by `defer`, `:141`).
Default maximum 1 MiB (`:21`); DMS sets 64 MiB (`core/internal/server/server.go:931`).
`bufio.ScanLines` drops one trailing `\r`.

Request fields: `dankgo/ipc/models.go:12-16`. `id` is a Go `int` with `omitempty`
(`:13`): absent is 0. `method` is a string. `params` is `map[string]any`
(`:15`): it must be an object, or absent or null. A value of another JSON type is
an unmarshal error, which becomes `invalid json` (`server.go:167-168`).

Empty line: `json.Unmarshal` of empty input is an error, so an empty line gets
`invalid json` too (`server.go:167`). This library does the same.

Invalid UTF-8 is accepted by Go, which substitutes U+FFFD. This library refuses
the line instead (section 4).

### 2.4 Replies, and a correction

`dankgo/ipc/models.go:18-22` (`Response[T]`): `ID int` `json:"id,omitempty"`,
`Result *T` `omitempty`, `Error string` `omitempty`.

**Correction to `dms_surface.md` sections 0-2 and 7.** Those notes, and the brief
built from them, say malformed JSON gets `{"id":0,"error":"invalid json: ..."}`.
The Go source does not emit `"id":0`. `server.go:168` writes
`Response[any]{ID: 0, Error: ...}`, and `omitempty` drops a zero `int`, so the
wire line is `{"error":"invalid json: ..."}`. This library follows the source. A
zero id is left out of every frame, including subscription frames. The QML client
drops lines with no `id` and no `result` either way (`DMSService.qml:268-270`),
so the observable behaviour in the shell is the same.

The result is always present for `Respond`: `Result` is a pointer to the value,
so `omitempty` does not drop a `null` (`models.go:41-43`).

Unknown method: `w.RespondError(req.ID, "unknown method: "+req.Method)`,
`dankgo/ipc/mux.go:41`. DMS's own `subscribeHandler` uses the same text for
`unsubscribe` (`core/internal/server/server.go:409-416`).

### 2.5 Dispatch order

`dankgo/ipc/server.go:175-198`. Built in, before any handler:
* `ping` answers `{"pong":true}` (`:177-178`). DMS's `ping` handler is unreachable.
* `subscribe` goes to `Config.SubscribeHandler`, which DMS sets (`server.go:932`).
* `unsubscribe` goes to the same handler, which rejects it (`server.go:409-416`).
  dankgo's own `unsubscribe` handling is replaced.
* everything else goes to the mux, which answers unknown methods (`mux.go:41`).

Every request runs in its own goroutine (`server.go:171`). Replies can arrive out
of order and are matched by `id`.

### 2.6 Subscriptions

`subscribe` params (DMS, `server.go:534-555`): `services` (a list of strings, read
at `:542-549`, non-strings skipped), `clientId` (a string; used only as the D-Bus
client key, `:537-540`). An empty list means `["all"]` (`:551-553`).
`"all"` expands to every service that is not explicit-only, through
`serviceSubscribed` (`:530-532`). `mpris.command` is explicit only (`:660`).

Frames, all `{"id":<subscribe id>,"result":{"service":S,"data":D}}`:
1. First, synchronously, `service = "server"`, `data = ServerInfo` (`server.go:794-798`; `ServerInfo` at `:50-54`).
2. Then, per service, its snapshot if it has one, then each publication (`subscription.go:9-32`, `forwardSubscription`). The data is the state value, not a typed event wrapper.
3. Capability changes: `notifyCapabilityChange` (`server.go:519-528`) sends `ServerInfo` to every subscribed connection, with the subscribe id (`:809-812`).

The service order of steps 2 is goroutine-scheduled in DMS, so it is not
deterministic across services. This library sends snapshots in topic registration
order.

Whether the QML client ever sends `unsubscribe` is not verified: `dms_surface.md` marks it unverified, and this note does not fetch the client.

### 2.7 Timeouts

`dankgo/ipc/writer.go:14`: `writeTimeout = 30 * time.Second`. A write blocked for
that long closes the connection (`:50` sets the deadline, `:57` closes on error).
Reads have no timeout.

### 2.8 DMS publication path

`subscription.go:5-34`: each service forwards from a channel, with an initial
snapshot when the service has one (`:9-16`), then every value (`:18-32`). Sends
block on the shared `events` channel (`server.go:558`, buffered 256), and a
`stop` channel ends the forwarders. Nothing is dropped and nothing is coalesced:
a slow client makes the channel fill, and the 30 s write timeout is the only limit.

## 3. Decisions

| Area | Decision | Why |
| --- | --- | --- |
| I/O model | One I/O thread (poll(2) via `bleu::rt::poller`), N handler threads (default 4), a mailbox per thread | A blocking handler must not stall `ping` or other clients. poll(2) has no fd limit beyond the capacity given. |
| Handoff | Publishers post to the I/O mailbox under the topic mutex | Keeps publication order and snapshot consistent. |
| Frame building | Own `wire::Writer` (no dependency on `bleu_json`) | The brief forbids the dependency. Escapes quotes, backslashes and controls; other bytes pass through (valid UTF-8 is checked first). |
| Parsing | `std::encoding::json` (strict), on the I/O thread | The brief's choice. Parsing on the I/O thread lets `ping` and `subscribe` answer without a handler thread. |
| Exactly-once | `Atomic{bool} answered`, compare-and-swap; `Pending` refcount (dispatch + Deferred) | A second answer is refused with `INVALID_STATE`. A handler that returns unanswered gets an error. |
| Deferred | `Deferred` holds one reference, cleared by CAS, so a copy cannot double-release | Completion from any thread, and no use-after-free for a late completion while the server lives. |
| Outbox | Per-client queue, coalescing for state frames only, byte bound, in-flight frame never replaced | Latest-wins for state (bounded memory); events and replies never lost silently. |
| Overflow | Disconnect | The wire has no overflow message. The client re-subscribes and gets the snapshot. |
| Stall | Deadline set on first BUSY, cleared on progress; disconnect at deadline | dankgo's rule (`writer.go:14`), with the duration configurable for tests. |
| Subscriber counts | `Atomic{int}` per topic, incremented on subscribe, decremented on close | Readable from any thread without a lock. |
| Stale sockets | ESRCH only counts as dead | `EPERM` means another user's live process. DMS treats any error as dead (`server.go:254-263`). |
| Socket dir | `XDG_RUNTIME_DIR` or an explicit path; no fallback | A silent fallback puts the socket where clients do not look. |

## 4. Deviations (each also in the README)

1. `Call.defer()` is `defer_reply()` (keyword).
2. Zero ids are omitted, following the source (section 2.4).
3. Invalid UTF-8 in a request is refused. Go substitutes U+FFFD and continues.
4. Nesting depth above 64 is refused (std parser limit). Go allows about 10,000.
5. Coalescing of state frames (latest wins). DMS queues everything.
6. Overflow disconnects. DMS has no overflow frame and does not disconnect on a full queue, only on the 30 s write stall.
7. Limits DMS does not have: 64 clients, 32 MiB queued per client, 256 queued requests per handler.
8. No `XDG_RUNTIME_DIR` fallback (section 3).
9. `EPERM` counts as alive (section 3).
10. `clientId` ignored; `cliVersion` never sent.
11. Escaping differs in `<`, `>`, `&`, U+2028, U+2029 (JSON-equivalent).
12. Capability function evaluated on each handshake, subscribe, and notify. DMS evaluates it per handshake (`CapabilitiesFunc`, `server.go:930`) and globally for subscribe and notify (`getServerInfo`, `:511-517`). The same result when the function is pure.
13. Snapshot order across topics is registration order (DMS: goroutine order).

## 5. Socket and thread facts relied on (bleu_rt)

* `unix::listen` binds and listens, and the listener is made non-blocking. accept(2) is called until BUSY, so a blocking listener would hang the I/O thread (found by testing, section 7).
* `UnixSocket.send` returns BUSY when the non-blocking socket is full, and sends with `MSG_NOSIGNAL` (so a closed peer is not SIGPIPE).
* `Poller` removes by tag, keeps order, and reports `WAKEUP_TAG` already drained.
* `Mailbox.close` wakes the consumer, so `Worker.stop` interrupts an idle poll.

## 6. C3 gotchas found while writing this library

Appended here, not to `docs/C3_GOTCHAS.md` (owned by the lead):

* `defer` is a keyword: a method cannot be named `defer`. Use `defer_reply`.
* `any` is a keyword as a local name. Use `applied`.
* `TIMEOUT` is the std built-in excuse: write it bare, not `error::TIMEOUT`. `BUSY` is a Bleu excuse: write `error::BUSY`.
* `@private` on a method declaration is rejected or ignored. Use free functions with `@private`.
* `@require` takes a boolean expression. A prose condition is a parse error.
* `io::path::delete` needs `(io::path::Path)` on a `String`: an explicit cast between distinct types.
* `json::parse(arena, text, json::JsonFlavor.JSON)`: the flavour is an enum member, not `json::JSON`.
* `Duration` needs `import std::time` in every file that names it, even where only `time::FOREVER` is used.
* `mem::copy` takes `sz` lengths: casting `usz` lengths needs `(sz)`.
* `bind` on an existing path fails with `EADDRINUSE`, reported as `BACKEND_FAILURE`: a crashed run leaves its socket file behind. Tests delete their path first.
* ASan: the C3 test binary needs `LD_PRELOAD=<libasan.so>` (the message is "ASan runtime does not come first"). With it, the run works.
* A test that panics inside a server test leaves the I/O thread alive, so the process does not exit. Keep `!!` out of paths that a test is meant to observe.

## 7. Verification, and what it found

* **Unit tests** (`wire_test`, `line_test`, `outbox_test`): frames, escaping, ids up to 2^53, UTF-8 table, partial reads, many lines per read, CRLF, oversize, coalescing, in-flight frames, byte bounds.
* **In-process integration** (`integration_test.c3`): 15 tests. Two failed on first run; both were test errors (a wrong id expectation, and a "last publisher" assumption). One real bug: the listener was blocking, so the first accept hung the I/O thread. Fixed by making the listener non-blocking in `bind_socket`.
* **Raw-socket Python** (`tests/raw_protocol.py`, driven by `tests/protocol_driver.c3`): 8 checks, all passing.
* **AddressSanitizer:** one use-after-free found and fixed. `handle_line` released the request arena before the `subscribe` handler and the unknown-method reply read `params` and `method` from it. Fixed by releasing the arena last. Final run, on the final code: all 63 tests pass under AddressSanitizer with no sanitizer or leak report.
* **Cross-target:** `tools/check.sh bleu_core bleu_rt bleu_ipc`, all six targets OK.

## 8. Open items

* `dmsd` itself: its method modules (network, bluetooth, ...) are out of scope here.
* A DMS QML run against this server has not been done (no shell is available in this environment).
* `bleuctl` is not written. The `Client` API is what it would use.
