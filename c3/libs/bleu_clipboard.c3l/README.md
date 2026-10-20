# bleu_clipboard

The clipboard and the primary selection as a Bleu service: read and own them, watch them
change, keep the text copied recently in a bounded history (so it outlives the application that
copied it), fetch any offered type on demand with a size cap, and keep content marked as secret
out of the history. Module root `bleu::clipboard`. Depends on `bleu_core`, `bleu_rt`,
`bleu_service`, `bleu_wl` (Linux), `bleu_objc` (macOS), `bleu_win` (Windows).
Design and every decision with its source: `docs/research/clipboard_impl.md` and
`docs/research/session_windows_input.md` (the spec, clipboard part).

## Public API (summary)

* `Clipboard* open(Allocator, Options)`: the first working backend, or the one in `options.backend`.
  `close()`, `backend_name()`, `capability(Cap)` (an `Availability` with the reason when unavailable).
* `latest()`, `wait_after(seen, timeout)`, `watch(listener)` / `unwatch`, `subscribe()`: the state
  (`State{current, primary, history}`) and the transient `Event{kind, slot}`.
* `set_text(Slot, String) -> Operation{ulong}*`: own a selection with UTF-8 text. The operation
  completes with the new selection's sequence number.
* `set(Slot, Representation[]) -> Operation{ulong}*`: own a selection with one MIME type each.
* `clear(Slot) -> Operation{bool}*`: release a selection this service owns.
* `fetch(Entry, String mime) -> Operation{Bytes}*`: bytes of one type, from the history or from the
  live owner of the current selection, capped by `Options.payload_limit`.
* `delete(Entry) -> Operation{bool}*`: remove one history entry.
* `Options{backend, history_items, history_bytes, payload_limit, transfer_timeout}`: zero means the default.
* `Selection{present, owned, seq, mime_types, privacy, preview, size}`; `Entry{id, time, mime_types, preview, size}`.

## Coverage

Run = executed in this environment. Compiled = type-checked for the target (`tools/check.sh`), never run.
Not done = absent in v1.

| Capability | Linux, Wayland (`wayland`) | macOS (`pasteboard`) | Windows (`win32`) |
| --- | --- | --- | --- |
| READ_TEXT | Run (mock compositor) | Compiled | Compiled |
| WRITE_TEXT | Run (mock compositor) | Compiled | Compiled |
| WRITE_TYPES | Run (mock compositor, one text type) | Compiled (any type) | Not done (text only, UNSUPPORTED) |
| FETCH_TYPE | Run (live offer, image type; history text) | Compiled | Compiled (text only, DEGRADED) |
| WATCH | Run for events from the session; worker loop Compiled | Compiled (polling `changeCount`) | Compiled (`WM_CLIPBOARDUPDATE` listener, 30 s backstop poll) |
| PRIMARY_SELECTION | Compiled only, not exercised by any test | Not done (no such selection) | Not done (no such selection) |
| HISTORY | Run (mock) and pure tests | Compiled; pure tests run | Compiled; pure tests run |
| PRIVACY_MARKERS | Run (mock: KDE hint, nothing read); pure tests | Compiled; pure tests run | Compiled; pure tests run |
| MIME sanitising, preview, board | Pure tests run (every host) | same | same |

The `Clipboard` command handlers and the worker loops of the three backends are Compiled; the
Linux handlers are reached through the session the tests drive, but `run` itself is not run.

## Not done

* Linux: no run against a real compositor with data-control (the headless weston in this
  environment has none). Primary selection is written as data-control code but not exercised.
  The globals are read once at startup; a removed manager is noticed only when the compositor retires
  the device, which ends the session. The source application is not known.
* Linux: a served `send` and the pipe reads are bounded by `transfer_timeout` on the worker thread.
* macOS: the pasteboard privacy control of macOS 15.4 (`accessBehavior`) is not used; its names are
  UNVERIFIED. Types are pasteboard identifiers, mapped only for UTF-8 text.
* Windows: change notification is `WM_CLIPBOARDUPDATE` on a `bleu::win::message_loop` window. The sequence
  number is read on each notification and every 30 s as a backstop. Not run: a change the listener misses
  waits up to 30 s.
  Only text is written and fetched live; `CanIncludeInClipboardHistory` counts only when its DWORD is 0.
* Image and file-list history, rich-text round trips and the WinRT clipboard history are out of v1.
* `Entry` has no source application and no `sensitive` flag: content with a marker is never stored,
  so the flag would always be false; the selection carries the privacy state instead.
