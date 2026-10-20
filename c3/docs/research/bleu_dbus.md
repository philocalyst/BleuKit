# bleu_dbus: research record

Library: `libs/bleu_dbus.c3l` (module root `bleu::dbus`). Recorded on 2026-10-20
against C3 0.8.5_1, dbus-daemon 1.14.10 (Debian), python-dbus-next 0.2.3 (PyPI),
zvariant 5.5.0, libc 0.2.191 (crates.io), and the Linux kernel headers of
`torvalds/linux` master.

## Sources and how each was used

| Source | Address | Used for |
| --- | --- | --- |
| D-Bus specification (primary) | https://dbus.freedesktop.org/doc/dbus-specification.html | every wire rule; cited below by section heading |
| systemd sd-bus | https://raw.githubusercontent.com/systemd/systemd/main/src/libsystemd/sd-bus/{bus-message.c,bus-message.h,bus-internal.h,bus-signature.c,bus-type.c} | second implementation of framing, padding, limits, alignment table. `bus-marshal.c` does not exist on `main` (404), marshalling lives in `bus-message.c` |
| zvariant 5.5.0 (Rust) | https://static.crates.io/crates/zvariant/zvariant-5.5.0.crate | third implementation: depth limits, alignments, array length backpatching |
| python-dbus-next 0.2.3 | `pip install dbus-next` | independent encoder and decoder: golden vectors, auth, address, signal and ObjectManager behaviour |
| libc 0.2.191 (Rust) | https://static.crates.io/crates/libc/libc-0.2.191.crate | the Apple and BSD layouts and constants (no Mac is available to run on) and a second source for Linux |
| Linux uapi headers | `include/net/scm.h`, `include/uapi/asm-generic/errno.h`, `include/uapi/asm-generic/fcntl.h`, `include/uapi/linux/socket.h`, `include/linux/socket.h` (torvalds/linux, raw.githubusercontent.com) | kernel values: SCM_MAX_FD, errno, O_NONBLOCK, FD_CLOEXEC, MSG_*, cmsghdr |
| C3 manual and std | `/opt/c3/c3/MANUAL.md`, `/opt/c3/c3/lib/std` | slice semantics, `@pool` return, `DString.delete_range` contract |

Line numbers below refer to the local copies fetched on the date above.

## Wire rules and the decision for each

Each row: the rule, the primary source, the second source(s), and the code.

1. **Alignments** (`signature::code_alignment`). y, g, v: 1. n, q: 2.
   b, i, u, h, s, o, a: 4. x, t, d, `(`, `{`: 8.
   Spec "Summary of D-Bus marshalling". sd-bus `bus-type.c:79-110` (1: BYTE, SIGNATURE,
   VARIANT; 2: INT16, UINT16; 4: BOOLEAN, INT32, UINT32, STRING, OBJECT_PATH, ARRAY,
   UNIX_FD; 8: INT64, UINT64, DOUBLE, STRUCT, DICT_ENTRY). zvariant `utils.rs:9,20,31`
   (ARRAY 4, STRUCT 8, DICT_ENTRY 8). Agrees on all three.
2. **Array length excludes the padding after it, and padding is present even for an
   empty array** (`writer::begin_array/end_array`, `reader::begin_array`). Spec
   "Marshalling containers". sd-bus `bus-message.c:1571-1592` (alignment added between
   size and first element; `*ret_array_size = a` taken after it). zvariant `ser.rs:274-281`
   (`start` is taken after `first_padding`) and `ser.rs:379-381` (`array_len =
   bytes_written - start`). Also golden: dbus-next `ax []` = `00..00` (8 bytes).
3. **STRUCT and DICT_ENTRY start on an 8-byte boundary** regardless of contents. Spec
   "Marshalling containers". zvariant `utils.rs:20,31`, sd-bus `bus-type.c:103-106`.
4. **Strings**: UINT32 length (SIGNATURE: one byte), NUL-terminated, no padding between
   length and text. Spec "Marshalling basic types". Golden: dbus-next `sss` (writer test
   `writes_strings`).
5. **Fixed header is 16 bytes**: endianness, type, flags, version, body length (u32),
   serial (u32), field-array length (u32); the field array is padded to 8 and the body
   starts there. Spec "Message Format". sd-bus `bus-message.h:14-24` (packed struct of
   those 16 bytes), `bus-message.c:374-379` (`fields_size` excludes padding; body length
   check against `ALIGN8(fields_size)`), `bus-message.c:2443` (padding zeroed). dbus-next
   `message.py:237-243` (`header_block.align(8)` before the body). Golden: whole Hello,
   signal, error and return messages, byte-exact.
6. **Serial must be non-zero.** Spec "Message Format". sd-bus `bus-message.c:371-372`
   (`serial == 0` → EBADMSG). Our `Message.fill` and `Message.encode` both refuse 0.
7. **Message limit 2^27 = 134 217 728 bytes**, header plus padding plus body. Spec
   "Message Format". dbus-next `message.py:214` (`# TODO maximum message size is
   134217728 (128 MiB)`). We check it in `frame_length` (framing) and in `encode`.
8. **Array limit 2^26 = 67 108 864 bytes.** Spec "Marshalling containers". sd-bus
   `bus-internal.h:346` (`BUS_ARRAY_MAX_SIZE 67108864`).
9. **Signatures**: at most 255 bytes; at most 32 nested arrays and 32 nested
   structs (dict entries count as structs); VARIANT signatures are one complete
   type. Spec "Valid Signatures" and "Container types". sd-bus `bus-signature.c:30,44,71`
   (array depth check, struct depth checks for `(` and `{`). zvariant
   `container_depths.rs:10-12` (32, 32, total 64 including variants).
   **Difference**: sd-bus `bus-internal.h:343` has `BUS_CONTAINER_DEPTH 128`, a limit on
   its in-memory container state, not on the wire. We follow the specification (32/32,
   and 64 for the total including variants, enforced by our 65-frame stack).
10. **Dict entries** occur only as array elements, with a basic-type key and exactly two
    fields. Spec "Container types". sd-bus `bus-signature.c:71` (checked against the struct
    depth). Our `signature::scan` rejects `{` unless it is an array element
    (`element_end`).
11. **Booleans** are UINT32 and only 0 or 1 are valid. Spec "Basic types". Reader rejects
    other values (`marshal_reader_test::rejects_malformed_input`).
12. **Padding must be NUL and no more than necessary.** Spec "Byte order and alignment".
    Reader checks every padding byte (`reader::align`).
13. **Header field codes and their types**: PATH=1 `o`, INTERFACE=2 `s`, MEMBER=3 `s`,
    ERROR_NAME=4 `s`, REPLY_SERIAL=5 `u`, DESTINATION=6 `s`, SENDER=7 `s`, SIGNATURE=8
    `g`, UNIX_FDS=9 `u`. Spec "Header Fields" (table). dbus-next `message.py:221-235`
    writes exactly these codes and variant types. Unknown codes are skipped; a known code
    with the wrong variant type, or appearing twice, is refused (spec: "must not accept
    known header fields with the wrong type").
14. **Message type codes** 1 METHOD_CALL, 2 METHOD_RETURN, 3 ERROR, 4 SIGNAL; unknown
    codes are ignored. Spec "Message Format". dbus-next `constants.py:12-17`.
15. **Flags**: NO_REPLY_EXPECTED 0x1, NO_AUTO_START 0x2, ALLOW_INTERACTIVE_AUTHORIZATION
    0x4. Spec "Message Format". dbus-next `constants.py:20-27`. Signals are sent with flags
    0, as dbus-next does (golden).
16. **Endianness flag**: `l` little, `B` big. Spec "Message Format". Big-endian Hello is
    decoded by dbus-next's unmarshaller in our generator run (see Verification).
17. **Protocol version 1**, checked at framing. Spec "Message Format"; dbus-next
    `message.py` `PROTOCOL_VERSION`.
18. **Object path grammar**: `/` or elements `[A-Za-z0-9_]+` separated by `/`, no trailing
    slash. Spec "Valid Object Paths". Interface, member, error and bus names: spec
    "Valid Names". Note: elements of a well-known bus name may not start with a digit;
    those of a unique name (`:1.42`) may.
19. **UTF-8** is strict: no NUL, no overlong forms, nothing above U+10FFFF; noncharacters
    are allowed. Spec "Basic types". Surrogates (U+D800..U+DFFF) are also refused, as
    standard UTF-8 does; the specification does not name them, so this is our reading.
20. **Descriptors**: a UNIX_FD value is an index; the descriptors travel with the message
    bytes, the message counts them in UNIX_FDS. Spec "Header Fields" (UNIX_FDS) and
    "Authentication Protocol" (NEGOTIATE_UNIX_FD). dbus-next `aio/message_bus.py:57-59` and
    `:78` send `unix_fds` with the message via `sendmsg` only when negotiated. We attach
    the descriptors to the `sendmsg` that carries the message's first byte
    (`transport::send_some` called with the descriptors only at the message start,
    `connection::flush`), and take them FIFO from the receive queue when parsing
    (`message::fill`). **Limit 253**: the kernel's `SCM_MAX_FD` (`include/net/scm.h:18`).
21. **SASL EXTERNAL**: `AUTH EXTERNAL <hex of the ASCII decimal uid>`. Spec "EXTERNAL"
    (example `AUTH EXTERNAL 31303030` for uid 1000). dbus-next `auth.py:55-63` (hex of
    `str(os.getuid())`). Our golden: `formats_external_with_hex_uid`.
22. **Handshake order**: NUL byte; AUTH; OK; NEGOTIATE_UNIX_FD; AGREE_UNIX_FD or ERROR;
    BEGIN; then messages. Spec "Authentication Protocol". dbus-next `auth.py:71-76`
    (BEGIN follows AGREE_UNIX_FD and also follows ERROR). Our `connection::open_endpoint`.
23. **Address syntax**: `transport:key=value,...`, entries separated by `;`, values
    escaped as `%xx` for bytes outside `[-0-9A-Za-z_/.*]`. Spec "Server Addresses".
    **Difference**: dbus-next `_private/address.py:8` escapes `*` (its regex admits only
    `[-0-9A-Za-z_/.%]`). We follow the specification, which includes `*`.
    `unix:runtime=yes` is listen-only in the spec; for clients we resolve it to
    `$XDG_RUNTIME_DIR/bus`. `dir` and `tmpdir` are listen-only, so they are not connectable.
24. **Reply codes** of the bus methods: RequestName 1 PRIMARY_OWNER, 2 IN_QUEUE, 3 EXISTS,
    4 ALREADY_OWNER; ReleaseName 1 RELEASED, 2 NON_EXISTENT, 3 NOT_OWNER; StartServiceByName
    1 SUCCESS, 2 ALREADY_RUNNING. Spec "Method: org.freedesktop.DBus.RequestName", "...
    ReleaseName", "... StartServiceByName". dbus-next `constants.py:38-51` (RequestNameReply
    PRIMARY_OWNER=1, IN_QUEUE=2; ReleaseNameReply RELEASED=1, NON_EXISTENT=2).
25. **Hello** is the first message; its reply carries the unique name. Spec "Method:
    org.freedesktop.DBus.Hello". The golden Hello is dbus-next's, byte for byte.
26. **Match rules**: `key='value'` pairs; an apostrophe inside a value is written as
    `'\''`. Spec "Match Rules" (the example `arg0=''\'''`). Our `match_test::quotes_apostrophes_inside_values`.
27. **A method call must be answered.** Spec "Method Calls". Until the server side exists,
    `connection::answer_unknown` replies `org.freedesktop.DBus.Error.UnknownMethod`
    (unless NO_REPLY_EXPECTED is set).
28. **Error names to excuses**: the bus's and polkit's names mapped as in `errors.c3`. The
    names are from the specification's "Standard Interfaces" and the bus daemon's
    `org.freedesktop.DBus.Error.*` set. The mapping is a policy of this library.
29. **Properties and ObjectManager**: Get/Set/GetAll; PropertiesChanged with the invalidated
    list; GetManagedObjects; InterfacesAdded/InterfacesRemoved. Spec "Standard Interfaces".
    Verified live against dbus-daemon with the mock service.
30. **Peer and Introspect**: Introspectable.Introspect returns XML (used by
    `Proxy.introspect`). Peer.Ping is answered with an empty METHOD_RETURN, which the spec
    requires of every peer (`connection::answer_unknown`; checked live by `peer_pings`).
    Peer.GetMachineId is not implemented: it is answered with UnknownMethod.

## Decision: bleu_rt was not adopted for the transport

`libs/bleu_rt.c3l` (module `bleu::rt::unix`: `connect`, `UnixSocket.send`/`recv` with
SCM_RIGHTS, `Fd`, errno mapping) appeared while this library was being written. It was
evaluated and not switched to, for three reasons:

* Its `Fd` type would replace the `int` descriptors in `Message` (received and outgoing
  lists), `Connection` and the transport, a change to the core types of a library that is
  already verified live.
* Its connect errors map ENOENT and ECONNREFUSED to `NOT_FOUND` and `BACKEND_FAILURE`;
  this library's contract is `UNAVAILABLE` for "no bus is listening", which the
  disconnect test checks.
* `bleu_rt` is still changing (its README lists open items), and the readiness wait would
  still need `poll`, since the `Poller` requires a `Wakeup` and a mailbox.

The switch is a follow-up: replace `transport_posix.c3` (connect, send, recv, close) with
`bleu::rt::unix`, change `Connection.socket_fd` to `Fd`, and map errors in one place. The
tests are the acceptance check: unit, integration (both socket kinds), and the disconnect test.

## Platform layouts and constants

The transport is the only place with operating-system structures (`transport_posix.c3`).

| Item | Linux | Apple / BSD | Sources |
| --- | --- | --- | --- |
| `struct msghdr` | `void* name; uint namelen; iov; size_t iovlen; control; size_t controllen; int flags` (56 bytes) | `socklen_t namelen`, `int iovlen`, `socklen_t controllen` at the same offsets (56 bytes) | libc `unix/linux_like/linux/gnu/mod.rs:68-76`; libc `unix/bsd/mod.rs:89-101` |
| `struct cmsghdr` | `size_t len; int level; int type` (16 bytes), data aligned to 8 | `socklen_t len; int level; int type` (12 bytes), data aligned to 4 (`__DARWIN_ALIGN32`) | kernel `include/uapi/linux/socket.h:119-123`; libc `unix/bsd/mod.rs:103-107`, `unix/bsd/apple/mod.rs:4480-4483,4603-4613` |
| `struct sockaddr_un` | `u16 family; char path[108]` | `u8 len; u8 family; char path[104]` | libc `unix/linux_like/mod.rs:209-212`; libc `unix/bsd/mod.rs:146-150` |
| `SOL_SOCKET` | 1 | 0xffff | libc `new/linux_uapi/asm/socket.rs:5`; libc `unix/bsd/apple/mod.rs:3187` |
| `SCM_RIGHTS` | 1 | 1 | libc `unix/linux_like/mod.rs:591`; libc `unix/bsd/mod.rs:261` |
| `O_NONBLOCK` | 0x800 (2048) | 0x4 | kernel `include/uapi/asm-generic/fcntl.h:42` (`1 << 11`); libc `unix/bsd/mod.rs:275` |
| `FD_CLOEXEC` | 1 | 1 | kernel `include/uapi/asm-generic/fcntl.h:172` |
| `MSG_CTRUNC` | 0x8 | 0x20 | kernel `include/linux/socket.h:322`; libc `unix/bsd/apple/mod.rs:3230` |
| `MSG_NOSIGNAL` | 0x4000 | 0x80000 | kernel `include/linux/socket.h:333`; libc `unix/bsd/apple/mod.rs:3240` |
| `SO_NOSIGPIPE` | (not used) | 0x1022 | libc `unix/bsd/apple/mod.rs:3216` |
| `nfds_t` | `unsigned long` | `unsigned int` | libc `unix/linux_like/linux/mod.rs:26`; libc `unix/bsd/mod.rs:9`. We declare `usz`: correct on both ABIs (a 32-bit callee reads the low half of the register) |
| `POLLIN/POLLOUT/POLLERR/POLLHUP/POLLNVAL` | 1, 4, 8, 0x10, 0x20 | same | libc `unix/linux_like/mod.rs:1299-1303`; libc `unix/bsd/mod.rs:412-416` |
| `ENOENT`, `ECONNREFUSED`, `EAGAIN`, `EINTR`, `EPIPE`, `ECONNRESET` | 2, 111, 11, 4, 32, 104 | 2, 61, 35, 4, 32, 54 | kernel `include/uapi/asm-generic/errno.h:95` (ECONNREFUSED 111); libc `unix/bsd/apple/mod.rs:2516,2576,2549,2518`. We use the std `libc` names for the errno values, and our own constants for ENOENT and ECONNREFUSED |
| `SCM_MAX_FD` (our `MAX_DESCRIPTORS`) | 253 | (same bound used everywhere) | kernel `include/net/scm.h:18` |

**Not verified on hardware**: the Apple and BSD rows (libc crate only), so the macOS
targets are compile-checked, not run. The Linux rows were exercised by the live tests.

## Verification record

Commands and their results are in the task report. In short:

* **Golden vectors, little-endian**: produced by python-dbus-next 0.2.3's
  `Marshaller` (values and signatures listed in `tests/golden/gen_message_vectors.py`
  and the writer tests). Our `Writer` must reproduce them exactly, and our `Reader`
  must decode them. Round trip: `marshal_reader_test::round_trips_golden_values_back_to_the_same_bytes`.
* **Golden vectors, big-endian**: the specification's own example
  (`marshal_golden_test::writes_array_of_int64_big_endian_as_in_the_specification`), a
  hand-computed set of scalars (`writes_big_endian_scalars`), and a big-endian Hello
  written by the generator's `BigEndianBuffer`. The generator checked it with
  dbus-next's unmarshaller, which decoded `member=Hello`, `path=/org/freedesktop/DBus`,
  `destination=org.freedesktop.DBus`, `serial=1`.
* **Whole messages**: the four types encode byte-for-byte as dbus-next encodes them
  (`encodes_*_like_dbus_next`), and parse back (`parses_*`).
* **Fuzzing**: `marshal_fuzz_test` (200 000 mutated inputs, read as values, skipped, and
  read under the wrong signature) and `message_fuzz_test` (100 000 mutated messages
  through framing, parsing, body reading and `error_text`). Both run in safe builds, where
  out-of-range slices and indices trap; a trap fails the run. No trap occurred.
* **Live bus**: `tests/integration.sh` starts dbus-daemon 1.14.10 twice (abstract and
  filesystem listen addresses) with the python mock service, and runs 49 checks each time
  (names, calls, errors, properties, PropertiesChanged, subscriptions, ObjectManager,
  NameOwnerChanged, timeouts, async calls, a Peer.Ping answered during `process()`,
  descriptor passing). A third run stops the bus
  under a connected client: `process()` reports DISCONNECTED, and reopening reports
  UNAVAILABLE.
* **Thread ownership**: a `Connection` used from another thread aborts in a debug build
  with "a Connection may only be used by the thread that created it" (checked by a
  scratch program that calls `close` from a second thread).

## Discrepancies found while cross-checking (and what we did)

* dbus-next's address escaping does not admit `*` (`address.py:8`); the specification does.
  We follow the specification.
* sd-bus's `BUS_CONTAINER_DEPTH` is 128; the specification's wire limit is 32 structs and
  32 arrays (64 total). We follow the specification.
* dbus-next emits InterfacesAdded and InterfacesRemoved by itself whenever an object is
  exported or unexported under an ObjectManager (`message_bus.py:209-262`). A mock that
  also emits them doubles every signal; our first run of the integration test found this.
  The mock no longer emits them.
* zvariant counts VARIANT in the total depth of 64. We count it too (65 frames including
  the top level).

## C3 facts found while building this (for docs/C3_GOTCHAS.md)

These were not appended to `docs/C3_GOTCHAS.md`, which this task does not own.

* `$if` at top level of a file is a parse error; inside function bodies `$if ... $else`
  works, but `$else` takes no colon there.
* `@private` is ignored on methods (warning, fatal under check.sh). Make helpers free
  functions taking the receiver pointer.
* `Connection *self` inside a method is already a pointer: passing `&self` to a helper
  gives `T**`.
* A parameter cannot be optional (`void? r` is rejected). Use a macro with a `#` parameter
  (`macro @expect_fault(#result, expected)`) and the `@` prefix rule.
* Slices: `a[start:length]` takes a length; `a[i..j]` is inclusive. `s[start:end]` with an
  exclusive end is a runtime trap.
* `DString.delete_range(start, end)` has an inclusive end and requires `end < len`; use
  `delete(start, count)` for byte counts.
* `String` and `char[]` do not convert implicitly; cast.
* Struct and slice literals: `keep ? { a, b } : {}` builds the slice on the stack; it
  dangles once the function returns. Allocate the items.
* `return` and `!` inside `@pool() { ... }` work (the pool closes on the way out).
* errno names are bare members of `libc`'s `Errno` after `import libc` (`EAGAIN`, not
  `libc::EAGAIN`).
* `sz` (signed) is what `.len` and `DString.len()` return; comparing with a `usz` cursor
  needs a cast.
* `if (try x = opt)` and `if (catch err = opt)` each need the optional itself; after the
  `catch` branch returns, the variable is unwrapped and `!!` is no longer allowed.
* Cross-module methods work (declare the method in another module of the same library),
  and so do module-qualified constants (`connection::BUS_NAME`); enum values need the
  enum prefix (`MessageType.SIGNAL`).
* `Thread.create(&fn, arg)` and `Thread.join()` are macros on `Thread`, not functions.
* `Message` uses `DynamicArenaAllocator` inside a heap struct: pass `&self.storage` as an
  `Allocator` at the call, never store the pointer.

## Server-side export: what is already in place

The design leaves room for exporting objects later without changing the wire layer:

* `Writer` and `Reader` are signature-directed and work for any body, so a service can
  build replies with `message::reply` and `message::error_reply`.
* `Message` can be built and encoded independently of a connection
  (`message::signal`, `message::reply`, `message::error_reply`).
* `Connection.dispatch_one` routes METHOD_CALL to `answer_unknown`. The export layer will
  replace that single call with a lookup in an object table keyed by path and interface.
* `Match` already matches method calls (`type='method_call'`), so the same subscription
  machinery can route incoming calls.
* Descriptor passing in both directions is implemented, so exported methods can take and
  return `h` arguments.

Not built: the object table, `Introspect` for exported objects, `Properties.Set` on
exported objects, `ObjectManager` export, and Peer.GetMachineId.
