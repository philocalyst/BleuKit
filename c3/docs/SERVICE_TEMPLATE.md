# Writing a service: follow `libs/bleu_battery.c3l`

`bleu_battery` is the reference implementation of the contract in
`ARCHITECTURE.md`. A new service copies its **shape**; read every file in it
(≈700 lines) before writing yours. File by file:

| File | Role | Rule |
| --- | --- | --- |
| `model.c3` | `State`, `Source`-style records, enums, `Cap`, `Event`, `Command`, `Backend` id enum | Plain data only. Unknown ≠ zero: use `Maybe{T}` (`std::collections::maybe`) for optional measurements. Units are `typedef`s from `bleu::unit`. No OS names. |
| `service.c3` | `Options`, `open()`, `close()`, `latest()`, `wait_after()`, `watch()`, `subscribe()`, commands | Thin: delegates to a `Hub{State, Command, Event}` (`bleu_service`). All methods thread-safe. Commands that can fail late return an `Operation{Value}*`. |
| `driver.c3` | `Driver` table entry: `info`, `id`, `probe`, `create`, `destroy`, `run`; `select_driver()` | Identical across services. `probe` is cheap and side-effect free. |
| `probe.c3` + `<os>.c3` | `platform_drivers()` → per-OS driver list, best first | `$if env::LINUX` etc. in `probe.c3`; the list itself lives in a file gated `@feat(LINUX)` / `@feat(DARWIN)` / `@feat(WIN32)`. |
| `<backend>_*.c3` | One backend: `Backend` struct, `DRIVER` constant, `run()` loop, native reads | Module `bleu::<svc>::<backend> @feat(<OS>)`. Pure conversion/parsing in a separate ungated file with its own `@test`s (`sysfs_convert.c3`). |
| `*_test.c3` | `@test`s | Parsers and converters always. A fake-root integration test (`battery_test.c3`) for anything file-based; a mock/peer for socket-based. |

Backend `run()` loop skeleton (see `linux_sysfs.c3`): create a
`bleu::rt::poller::Poller` on `host.wakeup()`; register native sources; loop
`while (!host.stopping())` { `poller.wait(timeout)`; handle ready sources;
`host.mailbox().take_all(buffer)` and execute commands (completing their
`Operation`s); build a `hub.begin()` snapshot, fill it from
`snapshot.allocator()`, `hub.publish_if_changed(snapshot)`; `hub.emit(...)` for
transients }.

Capabilities: `create()` fills `Capabilities` (an `EnumMap{Cap, Availability}`)
truthfully; start from `availability::YES` or a `no(reason, note)` default and
downgrade per feature the backend cannot do.

Testing hooks: `Options.root` (a prefix for pseudo-filesystems) and similar
fields are how tests substitute fakes. Never read the real system in tests.
