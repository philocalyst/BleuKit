# bleu_notify

The notification centre: a shell's notification server and a client that sends
notifications. Module root `bleu::notify`; the sender is `bleu::notify::sender`.
Linux is the only platform that can run the centre (the freedesktop server on the
session bus); every platform can send, with the caveats below. Sources and decisions:
`docs/research/media_notify_tray.md` (part B, notify) and `docs/research/notify_impl.md`.

## Public API

Centre (`bleu::notify`):

- `open(allocator, Options)` → `Notify*`: takes `org.freedesktop.Notifications` for this process;
  UNAVAILABLE names the owner when another daemon holds it; `Options.replace` takes it over.
- `latest()`, `wait_after(seen, timeout)`, `watch`, `unwatch`: `Snapshot{State}` (active, history, dnd, count).
- `subscribe()` → `Reader{Event}`: POSTED, CLOSED(reason), ACTION_INVOKED.
- `close_notification(id, reason)`, `invoke_action(id, key)` → `Operation{bool}*` (completes true, or NOT_FOUND / INVALID_ARGUMENT).
- `set_do_not_disturb(bool)`, `clear_history()`: queued, no result.
- `capability(Cap)` → `Availability`; `backend_name()`; `close()`.

Sender (`bleu::notify::sender`):

- `open(allocator)` → `Sender*`; `send(Request)` → `NoteId?` (synchronous); `close()`.
- `new_request(summary)`: the defaults (normal urgency, server timeout); `capability(Feature)`.
- A request that uses a feature the backend does not send is refused with UNSUPPORTED.

## Coverage

| Capability | Linux fdo | macOS UNUserNotificationCenter | Windows toast |
| --- | --- | --- | --- |
| Centre: Notify, Close, GetCapabilities, GetServerInformation, signals | Run (live D-Bus test) | Not done (no public centre API) | Not done (no public centre API) |
| Centre: replaces_id, stack tags, expiry, critical never expires, DND, eviction, history | Run | Not done | Not done |
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
- The centre renders nothing: it holds state and emits signals; sounds and images are recorded.
- Activation tokens; persistence across restarts.
- Notifications evicted by the open limit close with reason 4, the spec's reserved value.

## Verified how

- Linux, C3 0.8.5 on glibc, python-dbus-next 0.2.3 on a private dbus-daemon 1.14:
  - `libs/bleu_notify.c3l/tests/run.sh`: 44 live checks (every hint type including `image-data`,
    closing with reasons 1-3, replacement, stack tags, actions, DND, malformed hints, long bodies,
    eviction, the event subscription, name ownership and takeover, the C3 sender sending, replacing,
    expiring and refusing a bad option).
  - Unit tests: 54 `@test` functions in this library (markup, the hint decoder with a 20 000-round
    corruption fuzz and random bytes, rules, wire decoding, store, sender refusals), run with

        c3c --libdir "$(tools/libdir.sh)" --lib bleu_core --lib bleu_rt --lib bleu_dbus \
            --lib bleu_service --lib bleu_objc --lib bleu_notify compile-test

    from a scratch directory (82 pass in all, the rest belong to the dependencies).
- All six targets: `tools/check.sh bleu_core bleu_rt bleu_service bleu_dbus bleu_objc bleu_notify`.
  The macOS and Windows backends are type-checked only; nothing on those platforms was run.
