# bleu_wl: research and binding decisions

Scope: a pure-C3 Wayland client (`libs/bleu_wl.c3l`) with generated protocol bindings
(`tools/wlscan`). Each fact below was checked against two independent sources unless
the line says otherwise. Line numbers refer to the files as fetched on 2026-10-20.

## 1. Wire format

| Claim | Source 1 | Source 2 | Used in |
| --- | --- | --- | --- |
| Messages are 32-bit words; values in host byte order | Wayland book, "Wire Protocol" (https://wayland.freedesktop.org/docs/book/Protocol.html) | wayland-backend 0.3.11 `src/rs/wire.rs` line 138 uses `to_ne_bytes` | `wire.c3` (explicit little-endian, all targets LE) |
| Header: sender object id (u32), then `size << 16 \| opcode` | Wayland book, "Wire Protocol" (header has 2 words: object id, then 16-bit size and 16-bit opcode) | `wire.rs` lines 136-138 (write), 173-174 (parse: opcode low 16 bits, length high 16 bits) | `wire.c3` `read_frame`, `Writer.finish` |
| A string is a length (including the NUL), the bytes, the NUL, and padding to 32 bits | Wayland book, "Wire Protocol" (string description) | `wire.rs` `write_array_to_payload` on `as_bytes_with_nul()` (line 121 region, `Str(Some)`) | `Writer.put_string`, `Reader.get_string` |
| A null string or array has length 0; interior NUL bytes are not permitted | Wayland book, "Wire Protocol" (quoted: "A null value is represented with a length of 0. Interior null bytes are not permitted.") | `wire.rs` line 121 (`Str(None)` writes an empty array) and line 216 (length 0 parses to `Str(None)`) | `Reader.get_string` rejects interior NUL |
| `new_id` without a fixed interface is preceded on the wire by the interface name and the version | Wayland book, "Wire Protocol" ("a new_id is preceded by a string specifying the interface name and a uint specifying the version") | `wayland.xml`, `wl_registry.bind` declares only `name` and `id`: the scanner adds the two | `wlscan.py` `request_params`, `wl_registry.bind` |
| `fixed` is signed 24.8 | wayland.xml, `fixed` argument description | `wire.rs` `Argument::Fixed(f) => write_buf(f as u32)` | `wire.Fixed`, `fixed_from_double` rounds to nearest |
| The header's length must be at least 8 | `wire.rs` `parse_message` lines 176-177 (`len < 2 * 4` is Malformed) | Every argument is 32-bit aligned, so a valid length is a multiple of 4 (the crate does not check this; the check is ours) | `read_frame` rejects a size below 8, above 4096, or not a multiple of 4 |
| Message limit 4096 bytes; at most 28 descriptors per message | wayland-backend 0.3.11 `src/rs/socket.rs` line 23 (`MAX_BYTES_OUT = 4096`) and line 21 (`MAX_FDS_OUT = 28`) | Only the Rust crate was checked for these two numbers; a libwayland cross-check is still open (see section 6) | `MAX_MESSAGE_SIZE`, `MAX_FDS_PER_MESSAGE` |
| Descriptors travel out of band, FIFO, in the order the messages name them | `wire.rs` line 153 (`fds: &mut VecDeque<OwnedFd>`) and line 195 (`pop_front` for each `Fd` argument) | Wayland book, "Wire Protocol" (descriptors are not in the byte stream) | `wire.FdQueue`, `Reader.get_fd` |

Golden bytes in `wire_test.c3` were computed separately with Python's `struct`
module. Example: `wl_display.get_registry(new_id 2)` from object 1 is
`01000000 01000c00 02000000` (size 12 = `0x0c` in the upper half of the second word).

## 2. Object ids and the display

| Claim | Source |
| --- | --- |
| Ids from `0xFF000000` up belong to the server | wayland-backend 0.3.11 `src/rs/map.rs` line 8 (`SERVER_ID_LIMIT = 0xFF00_0000`); used at lines 41-55 |
| Client ids start at 2 (1 is `wl_display`) and can be reused after `wl_display.delete_id` | wayland.xml `wl_display` (`delete_id` event, line 101: "When the client receives this event, it knows that it can reuse the object ID"); wayland-backend `map.rs` for the ranges |
| A destroyed object keeps its id, as a zombie, until the server's `delete_id`; its events are decoded but not delivered | wayland.xml `wl_display.delete_id` description (the server "will no longer send any events" only after this event) |
| `wl_display.error`: codes 0 invalid_object, 1 invalid_method, 2 no_memory, 3 implementation | wayland.xml lines 86-97 (`enum error`) |

Decision: a destructor event (`wl_callback.done`) retires the proxy at once, as the
protocol says the object is then gone; the id is released by the later `delete_id`.

## 3. Protocol XML

Fetched from the URLs in `tools/wlscan/protocols.tsv` (all returned HTTP 200 on
gitlab.freedesktop.org, raw paths). Core `wayland.xml` from the wayland repository,
`main` branch. The wayland-protocols (`staging/`, `unstable/`) and wlr-protocols
(`unstable/`) XML are the versions on the default branch at fetch time. The generated
files record their module, so a later refresh shows up as a reviewed diff.

Not generated, on purpose: xdg-shell and the compositor-side surface protocols (a
client of this library does not draw), `kde-*` and `org_kde_*`, `ext-image-capture-source`.

## 4. Generator

* `wlscan.py` is stdlib only. It emits one module per protocol. Object arguments are
  typed when the target interface is known (in any generated module), and `Proxy*`
  otherwise. Enums are `constset : uint`; an `int` enum argument is cast through `uint`.
* Output is deterministic and formatted with `c3fmt`; `regen.sh` run twice leaves the
  tree unchanged (checked).
* `wl_display.error` and `wl_display.delete_id` also call the runtime through `HOOKS`
  in `wlscan.py`. This is the only protocol knowledge the runtime is given by hand.

## 5. Verification log

* `c3c` 0.8.5 compile-test of `wire_test.c3` and `client_test.c3` (with
  `mock_server_test.c3`) against bleu_core, bleu_rt and bleu_wl: 21 `bleu_wl` tests (13 wire,
  8 end-to-end), all passing.
* `tools/check.sh bleu_core bleu_rt bleu_wl`: all six targets.
* Real compositor: the Ubuntu package `weston` 13.0.0-4build3 with its dependency
  closure (333 `.deb` files, fetched with `apt-get download` into a scratch directory,
  unpacked with `dpkg -x`, not installed). Run headless with the fullscreen shell, its
  modules made visible in a private mount namespace (`unshare -m`, an overlay on
  `/usr/lib/x86_64-linux-gnu`). The probe connected by `WAYLAND_DISPLAY`, listed the
  globals, bound `wl_output` at version 4 and received mode and done events.
  Not tried: sway, cage, labwc, a wlroots headless build (not in the apt index used
  here; weston was the one that was).

## 6. Open items

* Cross-check the 4096 and 28 limits against libwayland's `wayland-private.h` (not fetched).
* Test the poller path (`Display.native` in `bleu::rt::poller`) with the real compositor.
* Check the wlr protocols (gamma, output management, data control) against a
  compositor that advertises them (sway or labwc), not only the mock.
