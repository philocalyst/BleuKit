# bleu_display

The display service: the outputs (monitors, panels, virtual displays) as plain data, with their
layout, mode, scale and rotation; changes to the layout, checked before they are applied, with a
rollback for a change nobody confirms; and a stream of what changed. Module root `bleu::display`.
Depends on `bleu_core`, `bleu_rt`, `bleu_service`, `bleu_wl` (Linux), `bleu_ddc` (EDID identity),
`bleu_objc` and `bleu_win` (the macOS and Windows backends). Design and the v1 cut:
`docs/research/display.md`; what was verified and how: `docs/research/display_impl.md`.

## Public API (summary)

* `display::open(allocator, Options{backend, root})` returns `Display*`; `close`. `backend_name()`.
* `latest()` returns the newest `Snapshot{State}` (call `release()`); `wait_after(seen, timeout)`;
  `watch`/`unwatch` on the worker thread; `subscribe()` for `Event`s (`OUTPUT_ADDED`, `OUTPUT_REMOVED`,
  `OUTPUT_CHANGED`, `REVERTED`).
* `State { Output[] outputs; uint serial }`. `Output` has `id` (stable), `name`, `make`, `model`,
  `serial`, `description`, `width_mm`/`height_mm`, `enabled`, `primary`, `x`/`y`, `current`, `modes[]`
  (`width`, `height`, `refresh` in millihertz, `preferred`), `scale` (fractional), `transform`,
  `adaptive_sync`, `hdr`, `colour_depth`, `mirror_of`, `edid_fingerprint`. Unknown values are `Maybe` empties.
* `apply(Config, ApplyMode, revert_after)` returns `ApplyOp*` (`Operation{ApplyResult}`). `Config` is a
  full desired layout: one `OutputChange` per output (`enabled`, `mode`, `x`, `y`, `transform`, `scale`),
  plus `persistent`. `ApplyMode`: `TEST_ONLY`, `APPLY`, `APPLY_WITH_REVERT`.
* `confirm()` keeps a change made with `APPLY_WITH_REVERT`; `refresh()` re-reads the hardware.
* `capability(Cap)` returns an `Availability` (`YES`, `DEGRADED` with a note, or `no(reason, note)`).
* Pure rules (no platform code, tested): `validate_layout`, `validate_config`, `origin_offset`,
  `find_mode`, `refresh_matches`, `logical_extent`, `scale_from_logical_width`, `config_changes`,
  `delta_of`, `config_from_state`, `RevertGuard`, `after_cancel`, the Wayland and Windows conversions.

## Coverage

Run = executed on Linux against a scripted compositor or as a unit test. Compiled-only =
type-checked for the target (`tools/check.sh`-equivalent over the six targets), not executed.

| Capability | Linux, Wayland wlr-output-management | Linux, Wayland read-only (wl_output + xdg-output) | macOS, CoreGraphics | Windows, display configuration |
| --- | --- | --- | --- | --- |
| Enumerate outputs, modes, position, transform | Run (mock) | Run (mock) | Compiled-only | Compiled-only |
| Scale (read) | Run (mock) | Run (mock, from logical size) | Compiled-only | Not done |
| Physical size, EDID identity | Compiled-only (sysfs EDID lookup) | Compiled-only | Compiled-only (size) / Not done (EDID) | Not done |
| Hotplug events | Compiled-only (head finished / global removed) | Compiled-only | Compiled-only (CG callback) | Compiled-only (WM_DISPLAYCHANGE) |
| Test only (`TEST_ONLY`) | Run (mock) | Refused (UNSUPPORTED) | Compiled-only (DEGRADED) | Compiled-only |
| Apply: mode, position, transform | Run (mock) | Refused (UNSUPPORTED) | Compiled-only | Compiled-only |
| Apply: scale | Run (mock: the rollback restores the scale it read) | Refused | Compiled-only (mode-implied) | Refused |
| Apply with revert (rollback after deadline) | Run (mock) | Refused | Compiled-only (shared flow) | Compiled-only (shared flow) |
| Confirm before the deadline | Pure rule Run; wiring Compiled-only | Refused | Pure rule Run; wiring Compiled-only | Pure rule Run; wiring Compiled-only |
| Serial staleness (cancelled, retry) | Pure rule Run; wiring Compiled-only | Refused | n/a | n/a |
| Enable / disable an output | Compiled-only (the disable branch is not scripted) | Refused (UNSUPPORTED) | Refused (UNSUPPORTED) | Disable Compiled-only; enable Refused |
| Persistent change | Refused (UNSUPPORTED) | Refused | Compiled-only (kCGConfigurePermanently) | Compiled-only (SDC_SAVE_TO_DATABASE) |
| Mirror, HDR, colour depth, adaptive sync | Refused (UNSUPPORTED) | Refused | Refused (UNSUPPORTED) | Refused (UNSUPPORTED) |
| Layout rules, mode matching, transform maths, diff, guard | Run (unit tests, all hosts) | same | same | same |
| The Linux poller-driven loop (`run`) | Compiled-only (tests drive the session directly) | Compiled-only | not applicable | not applicable |

## Not done

* Mutter (`org.gnome.Mutter.DisplayConfig`) and KDE routes: the research v1 cut names Mutter as a second
  apply route; this version uses the Wayland protocols only, as the Linux brief asks.
* Linux: the readiness-driven loop in `run` is not exercised by a test (the tests drive the session on
  the test thread); the wl_output hotplug path and the wlr head removal are type-checked, not run; the
  EDID lookup is not run against a fake sysfs root; `Options.root` is only used for that lookup.
* Linux: no `wp_fractional_scale`; the fractional scale is derived from `xdg-output`'s logical size.
* macOS: rotation, switching an output on or off, mirroring, HDR, colour depth, names from IOKit, EDID,
  the mode's "preferred" flag, and a whole-layout test (CoreGraphics checks each call instead).
* Windows: scale (no public call is bound), switching an inactive output on, mirroring, advanced colour
  (HDR, colour depth), EDID, the physical size, and `ERROR_INSUFFICIENT_BUFFER` retries.
* No platform was run except Linux against the mock. macOS and Windows are type-checked only.

## Verified how

* Unit: `src/pure_test.c3` (17 `@test`s: transform, layout, origin, refresh tolerance, mode matching,
  config validation, diff, revert guard, conversions) and `src/win_convert_test.c3` (2). All pass
  (`compile-test`, Linux x86-64, c3c 0.8.5).
* Mock compositor: `src/linux_test.c3` (3 `@test`s) drives `attach`, `begin_apply`, `advance` and the
  rollback against `bleu::wl::testing::MockServer`, expecting each request by opcode: the read-only
  route (wl_output and xdg-output), the wlr test-only path, and the wlr apply with its rollback.
* Six-target type check of the whole library, with `tools/libdir.sh` (`c3c compile-only`).
