# bleu_notify: implementation notes

Spec: `docs/research/media_notify_tray.md` part (B), v1 cut. Standard fetched on 2026-10-20 from
`https://gitlab.freedesktop.org/xdg/xdg-specs/-/raw/master/notification/notification-spec.xml`
(Desktop Notifications Specification 1.3, 18 August 2024; read as text).

## Verified against the spec text

| Claim | Where in the spec |
| --- | --- |
| Notify signature `susssasa{sv}i` returns `u`; id never 0; replace returns the same id | Notify, replaces_id |
| expire_timeout -1 server default, 0 never, >0 ms | Expiration Timeout; Notify parameters |
| Critical notifications must not expire automatically | Urgency Levels ("should not automatically expire") |
| NotificationClosed reasons 1 expired, 2 dismissed, 3 by CloseNotification, 4 reserved | NotificationClosed |
| Markup: `b`, `i`, `u`, `a href`, `img src alt`; unsupported tags are stripped | Markup |
| image-data `(iiibiiay)`, bits per sample 8, channels 3 or 4 by alpha, RGB order | Formats |
| Image precedence image-data > image-path > app_icon > icon_data | Priorities |
| Hints a server does not understand are ignored | Hints |
| ActivationToken may precede ActionInvoked; clients may not rely on it | ActivationToken |

Not in the spec text and taken from reference daemons (single source each, see the research note):
the stack tags (`x-canonical-private-synchronous` and friends, dunst), `value` (dunst), reason 3 after an
action on a non-resident notification (Astal). The XML entities `&amp; &lt; &gt; &quot; &apos;` are
decoded as XML requires; the spec text read does not list entity handling (assumption).

## Deviations from the research note

- **Sending is synchronous.** `Sender.send` returns the id when the platform has taken the request
  (the Notify reply on Linux). The brief asked for an Operation; a Notify round trip is bounded
  (25 s) and the caller is a shell's own thread, so an Operation adds a thread for nothing here.
- **Driver `create` takes the start-up Operation.** The bus connection must be made on the worker
  thread (`Connection` records its owner), so the bus name outcome is only known there. `open` waits
  for it (10 s) and copies the failure detail (the owner's identity) into the caller's `error::last()`.
- **Centre commands return `Operation{bool}*`** for close and invoke (the outcome is known on the
  worker); set_do_not_disturb and clear_history are void posts. The command is named
  `close_notification` because the service's lifecycle `close()` already has the name.
- **Policy is data, not hooks.** `Policy` holds the open limit, the history limit and the default
  timeouts per urgency (plain numbers suit the state model; a function hook would not serialise).
- **`count`** is the number of Notify calls accepted since start (a replacement counts too).
- **Eviction** closes the oldest non-critical open notification when the open limit is reached,
  with reason 4 (UNDEFINED). With only critical notifications open, the oldest one goes.
- **Replacing a closed id** (replaces_id not open) reuses that id, as the spec's "returned value is
  the same value as replaces_id" requires. A stack tag replacement takes the replaced id.
- **Do-not-disturb** records non-critical notifications in history without showing them (no
  POSTED event, no timer); a replacement of an open notification stays open.
- **History keeps no pixels.** An image leaves with its notification; `has_image` stays true.
- **Snapshots copy everything** (`Store.fill`); the store owns each notification's text in its own
  arena, so the wire-to-store path copies nothing.
- **Unknown CloseNotification ids** answer with the error `org.freedesktop.Notifications.Error.NotFound`
  and empty text (the spec asks for "an empty D-Bus error"; the name is ours).
- **Platforms without a centre** (macOS, Windows) make `open` UNSUPPORTED, from the empty driver list.
- **Owner name.** The centre requests the name with DO_NOT_QUEUE and ALLOW_REPLACEMENT, so a running
  centre can be taken over by a `replace` start. (Without DO_NOT_QUEUE a refused replacement is queued
  and reported as success: `OwnedName` with `held` false. Found by the live test.)
- **Sender features.** A request using a feature the backend does not send is refused with that
  feature's availability, never silently dropped.

## Costs

Every change publishes a complete snapshot: all open and history notifications are deep-copied
(pixels included for open ones) and compared with the previous one. With the default limits (20 open,
50 history) that is bounded but not free; a shell that streams many images should lower `max_open`.

## Limits chosen (`model.c3`)

Strings are truncated on a UTF-8 boundary: app name 256, icon 1024, summary 1024, body 8192 bytes
(then parsed into at most 256 runs), actions 16 pairs (keys 64 bytes, labels 256), category 64,
desktop entry 256, image path 1024, stack tag 128, sound 1024, link 2048. Images: each side at most
4096, 8 bits per sample, at most 512 KiB of pixels. Timeouts are clamped to one day.

## Verification record

- `tests/run.sh` (Linux): 44 of 44 live checks, against `tests/notify_server_test.py` and the two
  C3 programs `tests/server_main.c3` (the centre) and `tests/notify_send.c3` (the sender).
- Introspection of the live server validates against the D-Bus introspection DTD
  (`xmllint --dtdvalid https://dbus.freedesktop.org/doc/introspect.dtd`); a deliberately wrong
  document is rejected by the same DTD.
- `@test` unit tests (54 in this library, 82 with dependencies; command in `README.md`): markup,
  hints (with a 20 000-round corruption fuzz and 5 000 rounds of random bytes), rules, wire decoding,
  store, sender refusals. All pass.
- `tools/check.sh` on all six targets: clean.

## Not exercised by a test

- `watch` / `unwatch` / `wait_after` on the centre (compiled; they wrap bleu_core's observable).
- The worker's refusal of queued commands after the bus is lost (only the normal stop path is run).
- The macOS and Windows backends: compiled only (macOS) or refused (Windows). Nothing was run there.
