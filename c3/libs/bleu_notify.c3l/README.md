# bleu_notify

The notification centre: a shell's notification server and a client that sends
notifications. Module root `bleu::notify`; the sender is `bleu::notify::sender`.
Linux is the only platform that can run the centre (the freedesktop server on the
session bus); every platform can send, with the caveats below. Sources and decisions:
`docs/research/media_notify_tray.md` (part B, notify) and `docs/research/notify_impl.md`.

## Public API

Centre (`bleu::notify`):

- `open(allocator, Options)` → `Notify*`: takes `org.freedesktop.Notifications` for this process;
  UNAVAILABLE names the owner when another daemon holds it. `Options.replace` takes the name
  over only from a daemon that allows replacement; a centre from this library never allows it.
- `latest()`, `wait_after(seen, timeout)`, `watch`, `unwatch`: `Snapshot{State}` (active, history, dnd, count).
- `subscribe()` → `Reader{Event}`: POSTED, CLOSED(reason), ACTION_INVOKED. Release it before `close()`.
- `close_notification(id, reason)`, `invoke_action(id, key)` → `Operation{bool}*` (completes true, or NOT_FOUND / INVALID_ARGUMENT).
  A command still queued when the centre closes completes with DISCONNECTED.
- `set_do_not_disturb(bool)`, `clear_history()`: queued, no result.
- `capability(Cap)` → `Availability`; `backend_name()`; `close()`.

Sender (`bleu::notify::sender`):

- `open(allocator)` → `Sender*`; `send(Request)` → `NoteId?` (synchronous, 5 s limit); `close()`.
- `new_request(summary)`: the defaults (normal urgency, server timeout); `capability(Feature)`.
- A request that uses a feature the backend does not send is refused with UNSUPPORTED.
- `Request.body` is plain text: the Linux sender escapes it, so the centre shows it as written.

## Trust model

The server faces every local app: any process on the session bus can call it. So the
centre treats each sender as untrusted, and records who sent each notification (the
D-Bus unique name of its connection).

- Replacement (`replaces_id`, or a stack tag) and CloseNotification act only on a
  notification the same sender posted. For anyone else a replacement is a new
  notification, and a close gets the same NotFound error as an unknown id.
- A replacement never lowers a CRITICAL notification's urgency and never gives it an expiry.
- `replaces_id` is never adopted as an id. An id that names no open notification of the
  sender gets a fresh one; an id that is open or in history is never issued again.
- A sender holds at most `Policy.max_per_sender` (10) open notifications. At the cap it
  gives up its own oldest one, so no sender fills the centre.
- The name cannot be taken from the centre: it does not allow replacement, so another
  client's `RequestName(REPLACE_EXISTING)` queues. `Options.replace` only takes a name
  from a daemon that allows it.
- Hints are bounded: at most 64 entries per notification are read, a repeated text key
  keeps its last value and is copied once, and image copies are budgeted (two images'
  worth). Links keep only http, https and mailto. The body is sanitised to the spec's markup subset.
- The shell's own calls (`close_notification`, `invoke_action`) are not restricted by
  sender: they come from the shell's own process.
- The shell must not trust what applications send: `image_path`, `sound_name`, `sound_file`,
  `Span.link` and the action keys are data, to be checked before a shell opens or plays them.

## Coverage

| Capability | Linux fdo | macOS UNUserNotificationCenter | Windows toast |
| --- | --- | --- | --- |
| Centre: Notify, Close, GetCapabilities, GetServerInformation, signals | Run (live D-Bus test) | Not done (no public centre API) | Not done (no public centre API) |
| Centre: replaces_id, stack tags, expiry, critical never expires, DND, eviction, history, sender ownership | Run | Not done | Not done |
| Centre: body markup, hints (all standard + value, stack tags, image-data) | Run (unit + live) | Not done | Not done |
| Centre: ActivationToken | Not done (UNSUPPORTED, never emitted) | Not done | Not done |
| Sender: summary, body | Run (C3 client through the bus) | Compiled only | Not done (UNSUPPORTED) |
| Sender: actions, image, replace, expiry, urgency, category, sound | Run | replace and body Compiled only; others UNSUPPORTED | Not done |
| Sender: close a sent notification | Not done (no sender API for it) | Not done | Not done |

## Not done

- Observing other daemons' notifications (BecomeMonitor), the history UI, the portal backend,
  the KDE extensions (NotificationReplied, Inhibit), inline reply.
- Windows toasts: the sender refuses with UNSUPPORTED; the reason is in `sender_toast.c3`.
- macOS: the centre is not available; the sender is compiled only and needs an app bundle.
  Its completion handlers hold a reference to their own answer, so a late answer is safe;
  this is a code-path argument only, since the code did not run.
- The centre renders nothing: it holds state and emits signals; sounds and images are recorded.
- Activation tokens; persistence across restarts.
- Notifications evicted by the open limit close with reason 4, the spec's reserved value.
- A sender that restarts is a new connection: it cannot replace what its previous process posted.

## Verified how

- Linux, C3 0.8.5 on glibc, python-dbus-next on a private dbus-daemon 1.14:
  - `libs/bleu_notify.c3l/tests/run.sh`: 49 live checks (every hint type including `image-data`,
    closing with reasons 1-3, replacement, stack tags, actions, DND, malformed hints, long bodies,
    eviction, the event subscription, name ownership and takeover refusal, sender ownership,
    fresh ids, body escaping, and the C3 sender sending, replacing, expiring and refusing a bad option).
  - Unit tests: 68 `@test` functions in this library (markup, the hint decoder with a 20 000-round
    corruption fuzz and random bytes, the hint budget with a 20 MiB flood, rules, wire decoding, store
    and ownership, sender refusals), run with

        c3c --libdir "$(tools/libdir.sh)" --lib bleu_core --lib bleu_rt --lib bleu_dbus \
            --lib bleu_service --lib bleu_objc --lib bleu_notify compile-test

    from a scratch directory.
- All six targets: `tools/check.sh bleu_core bleu_rt bleu_service bleu_dbus bleu_objc bleu_notify`.
  The macOS and Windows backends are type-checked only; nothing on those platforms was run.
