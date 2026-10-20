<*
 Runtime primitives every service worker thread is built on: wake-ups, a
 readiness poller, a command mailbox, timers, the worker thread itself, and the
 Unix socket plumbing the Linux and macOS backends need.

 The design rule is the one in ARCHITECTURE.md "Threads": a service owns one
 worker thread; native callbacks on foreign threads only enqueue; the worker
 blocks in a poller on its native sources plus a wake-up.

 This file is the POSIX half of the root module. It defines `Native`, the type
 of a waitable native object: a file descriptor here, a HANDLE on Windows.
*>
module bleu::rt @feat(POSIX);
import libc;

<*
 A waitable native object: a file descriptor on POSIX systems. The poller and
 the wake-up use it; it is not owned by them unless the owning type says so.
*>
alias Native = CInt;

<*
 fcntl(2) with an integer argument: the commands used by Bleu (F_SETFD,
 F_SETFL, F_GETFL, F_DUPFD_CLOEXEC) all take one int. Declared here because the
 standard library binds it only for some systems. Returns -1 on error, with
 errno set.
*>
extern fn CInt fcntl(CInt fd, CInt cmd, ...) @cname("fcntl");
