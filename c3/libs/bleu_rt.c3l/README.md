# bleu_rt

The runtime every service worker thread is built on: wake-ups, a readiness
poller, a command mailbox, monotonic timers, the worker thread itself, the
foreign-thread entry macro, and Unix sockets with file-descriptor passing.
Module root `bleu::rt`. Depends on `bleu_core`. Design: ARCHITECTURE.md "Threads".
Sources and decisions: `docs/research/bleu_rt.md`.

## Public API (summary)

* `bleu::rt::wakeup` - `Wakeup`: `init`, `signal`, `drain`, `native`, `close`.
  eventfd on Linux, pipe elsewhere on POSIX, manual-reset event on Windows.
* `bleu::rt::poller` - `Poller`: `init(alloc, wakeup, capacity, window_messages)`,
  `add(Source)`, `remove(tag)`, `wait(timeout) -> Ready[]` (TIMEOUT when nothing).
  `Source{handle, interest, tag}`, `Interest{readable, writable, hangup, failed}`.
* `bleu::rt::mailbox <Command>` - `Mailbox{Command}`: `init(alloc, max)`, `post`
  (UNAVAILABLE after close, BUSY when full; no temporary memory used), `take_all(buffer)`,
  `close` (idempotent, frees nothing), `free` (after close and after the last post).
* `bleu::rt::timers` - `TimerQueue`: `schedule`, `schedule_repeating` (refuses a
  zero period), `cancel(id)`, `next_timeout`, `pop_expired(buffer)` (non-empty buffer).
  Monotonic clock.
* `bleu::rt::worker <Command>` - `Worker{Command}`: `init(alloc, max_queue)`,
  `start(name, RunFn, context)`, `stop()` (idempotent, joins). `Host{Command}`:
  `stopping()`, `mailbox()`, `wakeup()`.
* `bleu::rt::foreign` - `@foreign_entry(; @body)`: temp allocator for any thread; safe to nest
  and to use on a thread that already has one (`has_temp_allocator()`).
* `bleu::rt::unix` (POSIX) - `Fd`, `UnixSocket`, `SocketPair`, `connect`, `listen`,
  `socket_pair`, `send`/`send_all`/`recv` with SCM_RIGHTS, `peer_credentials`,
  `errno_to_fault`. Zero bytes from `recv` mean end of file on a stream, and on a
  sequenced-packet socket only once the peer has hung up; a zero-length SEQPACKET
  message is a message. Descriptors need at least one byte of data to travel with.
* `bleu::rt::fs` - `read_file`, `read_trimmed`, `read_integer`, `write_text`, `list_dir`.

## Not done

* `Mailbox.drain(callback)`: only `take_all(buffer)` exists.
* Windows sockets in the poller: a socket is waited on through a `WSAEventSelect`
  event that the caller creates; the poller does not do that association.
* Thread names are not set on the OS thread: the stdlib has no call for it.
* BSD is not built. The Unix layer has Linux and macOS layouts only.
* macOS close-on-exec is set after creation, so a concurrent fork can race (research notes, section 6).
* Abstract socket names are Linux-only (UNSUPPORTED elsewhere).
* A `Worker` runs once: after `stop` it cannot be started again.

## Verified how

* Run on Linux x86-64 (glibc 2.39 in this container), C3 0.8.5: 25 `@test`
  functions in `src/*_test.c3`, all passing (`c3c compile-test` with
  `--lib bleu_core --lib bleu_rt`). They cover the mailbox, timers, the poller
  with a wake-up from another thread, the worker lifecycle, the foreign-thread
  entry (a pthread), Unix socketpairs with a pipe descriptor passed through,
  listen/connect/accept, peer credentials, abstract names, fs helpers.
* Compiled only (no run): the macOS files (`unix_darwin.c3`, `wakeup_pipe.c3`),
  the Windows files (`wakeup_win32.c3`, `poller_win32.c3`). Type-checked for all
  six targets with `tools/check.sh bleu_core bleu_rt`.
