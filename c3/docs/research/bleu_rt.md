# bleu_rt research notes

Every native constant, layout and sequence in `libs/bleu_rt.c3l` is cited here
with a primary source, and where the library makes a design choice, with the
implementation it was checked against. Two sources per native fact unless the
line says otherwise. Versions: C3 0.8.5_1 (`/opt/c3/c3/lib/std`), libc crate
0.2.170, mio 1.0.3, libuv 1.48.0, XNU and Linux `main` at the time of writing.

Abbreviations used below:

* **XNU** = https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/ (the path shown)
* **Linux** = https://raw.githubusercontent.com/torvalds/linux/master/
* **libc** = libc 0.2.170, `https://static.crates.io/crates/libc/libc-0.2.170.crate`
* **man7** = https://man7.org/linux/man-pages/
* **MS** = https://learn.microsoft.com/en-us/windows/win32/

## 1. Wake-up (`wakeup.c3`, `wakeup_eventfd.c3`, `wakeup_pipe.c3`, `wakeup_win32.c3`)

| Claim | Primary source | Cross-check |
| --- | --- | --- |
| Linux uses one eventfd with `EFD_CLOEXEC \| EFD_NONBLOCK` (0x80000 \| 0x800). | man7 `man2/eventfd.2`; Linux `include/uapi/linux/eventfd.h` (`EFD_CLOEXEC O_CLOEXEC`, `EFD_NONBLOCK O_NONBLOCK`) | libc `src/unix/linux_like/linux/gnu/b64/x86_64/mod.rs:565, 616`; **mio** `src/sys/unix/waker/eventfd.rs:34`; **libuv** `src/unix/async.c:223` uses the same flags. |
| An eventfd read returns an 8-byte counter and resets it; `read` on a zero counter gives EAGAIN when nonblocking. Coalescing follows. | man7 `man2/eventfd.2` ("Each successful read(2) returns an 8-byte integer"; EAGAIN when nonblocking) | Used by `native_signal`/`native_drain`. |
| Non-Linux POSIX (macOS) has no `pipe2`, so the pipe is made with `pipe(2)` and then `F_SETFL O_NONBLOCK` and `F_SETFD FD_CLOEXEC`. | man7 `man2/pipe.2`, `man7/pipe.7` (PIPE_BUF; a full pipe makes write fail with EAGAIN when nonblocking); XNU `bsd/sys/fcntl.h` (F_SETFD 2, F_SETFL 4, FD_CLOEXEC 1, O_NONBLOCK 0x4, F_DUPFD_CLOEXEC 67) | **mio** `src/sys/unix/pipe.rs:50-51` does exactly this for platforms without `pipe2`; **mio** `src/sys/unix/waker/pipe.rs:49` treats a full pipe as success after emptying it. Our `signal` treats EAGAIN as success for the same reason. |
| A Windows wake-up is a manual-reset event. Signal is `SetEvent`, drain is `ResetEvent`. | MS `synchapi/nf-synchapi-createeventa` ("If this parameter is TRUE, the function creates a manual-reset event object"; "remains signaled until it is explicitly reset"); MS `synchapi/nf-synchapi-setevent`; MS `synchapi/nf-synchapi-resetevent` | An auto-reset event is consumed by the first wait that sees it, which would lose a signal raised between two waits. |
| `signal` is idempotent, never blocks and never allocates, so it is safe from foreign callbacks and signal handlers. | man7 `man2/eventfd.2` and `man7/pipe.7` (non-blocking write); the C3 `Wakeup.signal` body is one `write(2)` or `SetEvent`. | Matches ARCHITECTURE.md "native callbacks ... only enqueue". |

## 2. Poller (`poller.c3`, `poller_posix.c3`, `poller_win32.c3`)

| Claim | Primary source | Cross-check |
| --- | --- | --- |
| POSIX waits use `poll(2)` with `struct pollfd { int fd; short events; short revents; }`. | man7 `man2/poll.2`; XNU `bsd/sys/poll.h` lines 96-100 | libc `src/unix/linux_like/mod.rs:1342-1347`; libc `src/unix/bsd/mod.rs:482-487`; **mio** `src/sys/unix/selector/poll.rs` uses the same `poll` loop. |
| POLLIN 0x1, POLLPRI 0x2, POLLOUT 0x4, POLLERR 0x8, POLLHUP 0x10, POLLNVAL 0x20 are the same on Linux and XNU. | XNU `bsd/sys/poll.h` lines 68-91 | libc `linux_like/mod.rs:1342-1347` and `bsd/mod.rs:482-487`. |
| `nfds_t` is `unsigned long` on glibc and `unsigned int` on XNU. | Linux: libc `src/unix/linux_like/linux/mod.rs:16`; XNU `bsd/sys/poll.h:102` (`typedef unsigned int nfds_t`) | libc `src/unix/bsd/mod.rs:9` (`c_uint`). |
| Timeouts are rounded up to whole milliseconds, so a sub-millisecond wait is not a busy loop. | man7 `man2/poll.2` gives the millisecond timeout. | **mio** `src/sys/unix/selector/poll.rs:513-521` ("`Duration::as_millis` truncates, so round up") and the same clamp to `c_int::MAX`. |
| `EINTR` is retried with the remaining time, not reported. | man7 `man2/poll.2` (EINTR is returned after a signal handler runs). | libuv `src/unix/linux.c:1198, 1282` retries on EINTR around the kernel wait. mio returns the error to its caller instead; we keep the retry because the brief asks for it. |
| Windows waits use `WaitForMultipleObjects` with at most `MAXIMUM_WAIT_OBJECTS` (64) handles. The wake-up counts as one, so 63 sources fit. | MS `synchapi/nf-synchapi-waitformultipleobjects` ("The maximum number of object handles is MAXIMUM_WAIT_OBJECTS"; "WAIT_OBJECT_0 ... index") | Stdlib `std::os::win32.waitForMultipleObjects` (`os/win32/process.c3:83`). |
| With window messages, `MsgWaitForMultipleObjects` takes at most `MAXIMUM_WAIT_OBJECTS - 1` handles and returns `WAIT_OBJECT_0 + nCount` when input is queued. | MS `winuser/nf-winuser-msgwaitformultipleobjects` ("maximum number of object handles is MAXIMUM_WAIT_OBJECTS minus one"; "WAIT_OBJECT_0 + nCount") | Stdlib `std::os::win32.msgWaitForMultipleObjects` (`os/win32/winuser.c3:737`). |
| `QS_ALLINPUT` is `QS_INPUT \| QS_POSTMESSAGE \| QS_TIMER \| QS_PAINT \| QS_HOTKEY \| QS_SENDMESSAGE`; with the QS_* values this is 0x1CFF on current SDKs. | MS `winuser/nf-winuser-getqueuestatus` (the formula) | Wine `include/winuser.h` lines 3014-3025 gives every QS_* value (`https://raw.githubusercontent.com/wine-mirror/wine/master/include/winuser.h`). |
| A signalled Windows object has no direction, so it is reported as readable; sockets need `WSAEventSelect`. | MS `winsock2/nf-winsock2-wsaeventselect` ("associates an event object with the specified set of FD_XXX network events") | The poller doc says so; no socket is waited on directly. |
| The poller drains the wake-up when it reports it. | Level-triggered semantics: man7 `man2/eventfd.2` (counter stays readable until read); MS `ResetEvent` for the event case. | Ordering argument is in `mailbox.c3`: enqueue and signal, and take and drain, happen under the same mutex, so no command is lost. |

## 3. Mailbox and worker (`mailbox.c3`, `worker.c3`)

* Mutex-protected ring that doubles up to a maximum; `post` refuses with BUSY at
  the maximum, so memory is bounded. The stdlib's `threads/buffered_channel.c3` is
  bounded too ("if channel is full -> wait"), but it blocks the producer; a
  service's `post` must never block a shell's UI thread, so the mailbox refuses
  instead and leaves the choice to the caller.
* **Lost wake-ups are impossible** because `post` enqueues and signals under the
  mailbox mutex, and `take_all` drains the wake-up under the same mutex only when
  the queue is empty. If `take_all` leaves commands behind (buffer too small), it
  re-signals. This is the same reasoning as the `Observable` listener ordering in
  `bleu_core/src/observe.c3`.
* `Worker.start` uses `std::thread`. The stdlib exposes no thread-naming call (no
  `pthread_setname_np` or `SetThreadDescription` in `threads/`, checked with grep),
  so the name is used only in error messages and is not set on the OS thread.
* `Worker.stop` sets the stop flag, closes the mailbox (which signals the wake-up),
  and joins. It holds the lifecycle mutex across the join; the worker thread never
  takes that mutex, so this cannot deadlock. `assert` catches a stop from the
  worker's own thread (joining oneself would deadlock).

## 4. Timers (`timers.c3`)

* `std::time::clock::now()` is the monotonic clock: `clock_gettime(CLOCK_MONOTONIC)`
  (man7 `man3/clock_gettime.3`). Stdlib `time/clock.c3` wraps it. Wall-clock jumps
  cannot fire or delay a timer.
* A binary min-heap keyed by due time. libuv keeps its timers in a min-heap too
  (`src/timer.c:38-44, 89-90`, `heap_insert`).
* Repeating timers re-arm from their due time, and if that is already past, from
  now, so a stalled worker does not get a burst of firings. libuv's `uv_timer`
  re-arms a repeating timer from the loop's current time (`src/timer.c:117-119`,
  `uv_timer_start(handle, cb, repeat, repeat)`), which has the same effect.

## 5. Foreign-thread entry (`foreign.c3`, `foreign_test.c3`)

Finding (verified on C3 0.8.5, glibc): a thread that does not have a temporary
allocator aborts on any `tmem`, `@pool` or `string::tformat` call:

```
ERROR: 'Use '@pool_init()' to enable the temp allocator on a new thread.
       A temp allocator is only implicitly created on the main thread.'
```

Run from `pthread_create` (exit 132, SIGILL), **and from `std::thread.create`**
(same abort). The cause is `std/core/private/allocators_temp.c3:44-49`
(`create_temp_allocator_on_demand`), reached from `LazyTempAllocator.acquire`.
The fix is `@pool_init(mem, size)` (`std/core/mem.c3:764`), which the macro
wraps. Every worker trampoline and native-callback trampoline therefore runs its
body in `foreign::@foreign_entry`. `foreign_test.c3` proves it with a real
`pthread_create` thread.

## 6. Unix sockets (`unix_socket.c3`, `unix_linux.c3`, `unix_darwin.c3`, `unix_fd.c3`, `unix_errno.c3`)

### Layouts

| Item | Linux value | macOS value | Sources |
| --- | --- | --- | --- |
| `struct msghdr` | `void*, socklen_t, iovec*, size_t iovlen, void*, size_t controllen, int flags` | `void*, socklen_t, iovec*, int iovlen, void*, socklen_t controllen, int flags` | Linux: libc `linux_like/linux/gnu/mod.rs:63-71`, man7 `man2/sendmsg.2`. XNU `bsd/sys/socket.h:603-611`; libc `bsd/mod.rs:85-95`. |
| `struct cmsghdr` | `size_t len, int level, int type` (16 bytes) | `socklen_t len, int level, int type` (12 bytes) | Linux: man7 `man3/cmsg.3`, libc `linux_like/mod.rs:1627-1650`. XNU `socket.h:652-656`. |
| CMSG alignment | `sizeof(size_t) - 1` = 7 | `sizeof(__uint32_t) - 1` = 3 (`__DARWIN_ALIGN32`) | Linux: libc `linux_like/mod.rs:1627`. XNU `socket.h:688, 717-718`; libc `bsd/apple/mod.rs:5615-5617`. |
| `struct sockaddr_un` | `sa_family_t sun_family` (2 bytes), `char sun_path[108]` | `unsigned char sun_len, sa_family_t sun_family, char sun_path[104]` | Linux: `include/uapi/linux/un.h`. XNU `bsd/sys/un.h:77-79`; libc `bsd/mod.rs:137-141`. |
| `AF_UNIX` = 1 | 1 | 1 | Linux `include/linux/socket.h:205`; XNU `bsd/sys/socket.h:387`. |
| `SOCK_STREAM` = 1, `SOCK_SEQPACKET` = 5 | same | same | Linux `include/linux/net.h:108, 112`; XNU `bsd/sys/socket.h:113, 119`. |
| `SCM_RIGHTS` = 1 | 1 | 1 | Linux `include/linux/socket.h:192`; XNU `bsd/sys/socket.h:726`. |
| `SOL_SOCKET` | 1 | 0xffff | Linux `asm-generic/socket.h`; XNU `socket.h`; libc `bsd/apple/mod.rs:4353`. |
| `SO_PEERCRED` = 17 (`struct ucred {pid, uid, gid}`) | 17 | n/a | Linux `include/uapi/asm-generic/socket.h:30`, `include/linux/socket.h:197`; libc `linux/arch/generic/mod.rs:40`; socket(7). |
| Peer credentials on macOS: `LOCAL_PEERCRED` (uid, groups) and `LOCAL_PEERPID` (pid) at `SOL_LOCAL` = 0 | n/a | `LOCAL_PEERCRED` 0x001, `LOCAL_PEERPID` 0x002 | XNU `bsd/sys/un.h:85-89`; libc `bsd/apple/mod.rs:4338-4343`. `struct xucred` with `XUCRED_VERSION` 0: XNU `bsd/sys/ucred.h:203-209`; `NGROUPS_MAX` 16: XNU `bsd/sys/syslimits.h:104`. |
| `SO_NOSIGPIPE` 0x1022 (no per-send flag on Darwin) | n/a | 0x1022 | XNU `bsd/sys/socket.h:174`; libc `bsd/apple/mod.rs:4382`; **libuv** `src/unix/core.c:520-523` sets it the same way. |
| `MSG_NOSIGNAL` 0x4000 (send without SIGPIPE) | 0x4000 | not used | man7 `man2/send.2` ("SIGPIPE unless MSG_NOSIGNAL is set"); libc `linux_like/mod.rs:844`. |
| `MSG_CMSG_CLOEXEC` 0x40000000 | 0x40000000 | not available | man7 `man2/recvmsg.2` (MSG_CMSG_CLOEXEC, since Linux 2.6.23); libc `linux_like/mod.rs:848`. |
| `MSG_CTRUNC`, `MSG_TRUNC` | 0x08, 0x20 | 0x20, 0x10 | Linux: libc `linux_like/mod.rs:834-835`. XNU `bsd/sys/socket.h:617-618`; libc `bsd/apple/mod.rs:4395-4396`. The values differ (CTRUNC and TRUNC are not in the same order); each platform file has its own. |
| `F_DUPFD_CLOEXEC` | 1030 | 67 | Linux libc `linux_like/mod.rs:509`; XNU `bsd/sys/fcntl.h:397`; libc `bsd/apple/mod.rs:3736`. |
| `F_GETFL` 3, `F_SETFL` 4 | 3, 4 | 3, 4 | Linux `include/uapi/asm-generic/fcntl.h`; XNU `bsd/sys/fcntl.h:281-282`. |
| `O_NONBLOCK` / `O_CLOEXEC` | 0o4000 / 0o2000000 | 0x4 / 0x1000000 | Linux `asm-generic/fcntl.h:42, 66`; libc `linux gnu b64 mod.rs:432, 592`; XNU `bsd/sys/fcntl.h:115, 171`. |

### Behaviour

* **Descriptor passing:** `sendmsg(2)` with one `SCM_RIGHTS` control message per
  send, and `recvmsg(2)` with `MSG_CMSG_CLOEXEC` on Linux (man7 `man2/recvmsg.2`).
  The shape matches **libuv** `src/unix/stream.c:800-808` (`CMSG_SPACE`/`CMSG_LEN`,
  `SCM_RIGHTS`, `sendmsg`) and its receive walk at `stream.c:987`.
* **Truncation:** `MSG_CTRUNC` means descriptors were dropped by the kernel, so the
  received ones are closed and the call fails with PROTOCOL, rather than returning
  a partial set. The same for `MSG_TRUNC` on sequenced-packet sockets.
* **Partial writes:** a stream `sendmsg` may accept fewer bytes than offered; the
  descriptors go with the first byte accepted (unix(7), sendmsg(2)). `send_all` sends
  the descriptors with the first piece only.
* **EAGAIN** maps to BUSY via `errno_to_fault` (non-blocking socket is full or empty);
  **EINTR** is retried for `accept`, `send`, `recv`, and `poll`. `connect` is not
  retried: a connect interrupted by a signal is reported as BACKEND_FAILURE.
* **Abstract names** (leading `@` or NUL) are a Linux extension (unix(7),
  "The abstract socket namespace is a nonportable Linux extension"). They are
  UNSUPPORTED on macOS.
* **Close-on-exec:** Linux creates sockets with `SOCK_CLOEXEC` and accepts with
  `accept4(2)` (man7 `man2/accept4.2`), so the flag is set atomically. Darwin has
  neither, so `FD_CLOEXEC` is set with `fcntl(2)` after creation, accept and receive.
  That leaves a window in which a concurrent fork could inherit a descriptor. This
  is a real, documented gap on macOS; it is not closed here.
* **Errno mapping** (`errno_to_fault`) is the table the brief asks for. Values not
  listed (EBADF, EINTR, EADDRINUSE, ...) are BACKEND_FAILURE and keep the errno in
  `error::last()`.

## 7. Filesystem helpers (`fs.c3`)

* Sysfs and procfs report size 0 or 4096 whatever they hold, so `std::io::file::load`
  and `load_buffer` (which size the read from `stat`) return nothing for such files.
  `fs.c3` reads to end-of-file into a bounded buffer and refuses longer files.
  Checked in the shipped stdlib: `io/file.c3:194-203` and `:209-217`.
* `io::path::ls` gives directory listings (`io/path.c3:96`).
* Writing a sysfs knob cannot be atomic (no rename into place on sysfs), so
  `write_text` is one open, one write and one close, and a short write is reported.
* **Stdlib defect found:** `std::io::path::rmdir(String)` does not compile from
  another module: its macro body calls `temp(path)` without the module prefix
  (`io/path.c3:140`). The test passes a `Path` instead. Reported to the lead.

## 8. Things the stdlib does not give us, and what we did instead

* `sendmsg`, `recvmsg`, `eventfd`, `accept4`, `getpeereid` (not used), `msghdr`,
  `cmsghdr`, `sockaddr_un`: not in `std::net::os`, so declared here per platform.
* Thread naming: absent (see section 3).
* `std::os::posix` has `pipe(2)`; `std::net::os` has `poll`, `socket`, `bind`, `listen`,
  `accept`, `connect`, `socketpair` but with `NativeSocket` typed as `inline Fd`, and
  it does not bind `sendmsg`/`recvmsg`. Our own `extern fn ... @cname` declarations
  avoid the name clashes with those.
