# bleu_color

The colour service: night light (colour temperature), gamma ramps, and software dimming, on Linux
(wlroots compositors through `zwlr_gamma_control_manager_v1`), Windows (`SetDeviceGammaRamp`) and
macOS (`CGSetDisplayTransferByTable`). Module root `bleu::color`. The gamma ramp is the `GAMMA`
mechanism of `bleu::brightness`, which reports it and does not write it (see "Integration" below).
Spec: `docs/research/display.md` (colour part and the v1 cut). Implementation notes and the
verification record: `docs/research/color_impl.md`.

## Public API

- `open(allocator, Options) -> Color*?`. `Options`: `backend` (`AUTO`, `WLR_GAMMA`, `WIN32_RAMP`, `COREGRAPHICS`), `tick` (schedule evaluation, default 10 s), `connect`/`connect_context` (Linux test seam).
- `latest()`, `wait_after(seen, timeout)`, `watch`/`unwatch` (`unwatch` is `void?`): `Snapshot{State}`; `subscribe()`: `Event` (`CONTROL_CHANGED`, `TEMPERATURE_CHANGED`).
  An event is announced after the state that shows it is published. `CONTROL_CHANGED` is sent once when a display's refusal begins and once when it ends; retries of a refused display are silent. `TEMPERATURE_CHANGED` is sent when the schedule moves the temperature.
- `State` -> `Output[]` (`id`, `name`, `Control`) and `Schedule`. `Control`: `gamma_supported`, `availability`, `size`, `temperature` (`Maybe{Kelvin}`), `brightness` (`Level`), `active`, `refused`.
- `set_temperature(output | ALL_OUTPUTS, Kelvin)`: clamped to 1000..25000 K; stops the schedule for every output, not only the named one (the schedule is one setting of the service).
- `set_dim(output | ALL_OUTPUTS, Level)`: multiplies the ramp (the GAMMA mechanism); leaves the schedule alone. A NaN level is `INVALID_ARGUMENT`.
- `reset()`: schedule off, temperature and dimming to defaults, every gamma control released.
- `set_schedule(Schedule)`: `Mode.MANUAL`, `Mode.SCHEDULE` (latitude, longitude) or `Mode.TIMES` (sunrise, sunset as local times of day); `day`/`night` temperatures (1000..25000 K); `transition` (at most one hour). Two sunrise or sunset edges closer than one transition blend continuously: each edge is a smoothstep step of the daylight state, and the steps are summed.
- Every command returns `ApplyOperation*?` (`Operation{Applied}`): `wait()` gives `Applied` (outputs written, temperature and brightness now in force) or the failure.
- Pure helpers: `bleu::color::kelvin::rgb(Kelvin)`, `bleu::color::ramp::fill(...)`, `bleu::color::schedule::temperature_at(...)`, `schedule::validate(...)`.
- `backend_name()`, `capability(Cap)`, `close()`.

## Caller-side usage

    Color* color = color::open(mem)!;
    defer color.close();
    ApplyOperation* warm = color.set_temperature(color::ALL_OUTPUTS, (Kelvin)3500)!;
    defer warm.release();
    Applied applied = warm.wait(time::sec(5))!;            // applied.outputs, applied.temperature
    if (try snapshot = color.latest())                     // the state, once the worker has published
    {
        defer snapshot.release();
        // snapshot.value.outputs[i].control.refused, .active, .temperature ...
    }

## Coverage (capability x OS -> status)

Run = executed here: pure tests on Linux x86-64; the Linux protocol path against the in-process
mock compositor. Compiled-only = type-checked for the named target (`tools/check.sh`), never executed.
Not done = not built.

| Capability / path | Linux | Windows | macOS |
| --- | --- | --- | --- |
| Kelvin to RGB (redshift table, clamp, interpolation) | Run (tests) | Run on Linux (shared pure code) | Run on Linux (shared pure code) |
| Ramp generation: gamma, brightness, size, 16-bit encode | Run (tests) | Run on Linux (shared pure code) | Run on Linux (shared pure code) |
| Schedule: sunrise/sunset (NOAA), transitions, polar, TIMES | Run (tests) | Run on Linux (shared pure code) | Run on Linux (shared pure code) |
| Gamma ramp written and read back by the compositor (wlr) | Run (mock compositor) | Compiled-only | Compiled-only |
| set_temperature / set_dim / reset through the service | Run (mock) | Compiled-only | Compiled-only |
| Control released on reset and on close (the compositor restores) | Run (mock) | Compiled-only | Compiled-only |
| Refusal (`failed`) at open: BUSY, control destroyed | Run (mock) | - | - |
| Control lost later (`failed` event): released, reported, retried | Run (mock) | - | - |
| Read-back of the applied ramp (`SetDeviceGammaRamp` may refuse silently) | - | Compiled-only | - |
| CGSetDisplayTransferByTable with captured table restore | - | - | Compiled-only |
| set_schedule through the service (the engine path on a running clock) | Compiled-only | Compiled-only | Compiled-only |
| Real wlroots compositor | Not done (no compositor run) | - | - |
| Night Shift, Windows night-light blob, ICC | Not done | Not done | Not done |
| Output hotplug; re-applying after display changes | Not done | Not done | Not done |

## Integration with bleu::brightness (not written: `bleu_brightness` is not edited)

`bleu::brightness` has a `GAMMA` mechanism with no backend (its README lists it under "Not done").
Its backend would take a dim provider of this shape, which `bleu::color` already satisfies:

    // The ColorService.dim_provider shape (this library's service type is `Color`): set a software dim
    // on one output, or on every output with `color::ALL_OUTPUTS`. The caller releases the operation.
    fn ApplyOperation*? (Color* color, String output_id, Level level)
    {
        return color.set_dim(output_id, level);
    }

Semantics a caller of this must know:
- The level multiplies the display's ramp after the colour temperature. It darkens the picture, not
  the backlight. The reading `brightness` reports for GAMMA is the multiplier this service applied,
  not a measurement of the screen.
- Gamma control is exclusive per output on Wayland. While another client holds it, the command
  returns `BUSY` and the output's `refused` flag is set; the next command tries again.
- The dim and the colour temperature share one ramp. A `reset()` or a neutral setting releases it.
- `set_dim` does not stop the schedule; `set_temperature` does.

## Not done

- A real wlroots (or other) compositor was not run. The Linux protocol path is verified against the
  in-process mock of `bleu_wl`, which is the protocol as the client sees it, not a compositor's behaviour.
- Windows and macOS are compiled only. Their ramp writes and restores have never reached a display.
- Night Shift (private CoreBrightness), the Windows night-light registry blob, and ICC profiles: deferred by the v1 cut.
- Output hotplug on every platform: outputs are those present when the worker starts.
- Windows: the ramp is reset by most display events, and this service does not re-apply it after one.
- macOS: the table is reset when a display's configuration changes; this service does not re-apply it.
- `set_schedule` is verified by the schedule maths (tests) but not through the service on a running clock.
- A command queued when the worker's `run` returns (for example after a failed connect) fails `DISCONNECTED` through the Hub's abandon hook.
- Windows and macOS error codes are the native `GetLastError`/`errno` values, but the mapping is compiled only.
- A compositor that disappears before the worker starts leaves the service without a state
  (`latest()` says UNAVAILABLE); no retry.
- Gamma exponent is always 1.0 from the service; the pure `ramp::fill` takes any exponent.

## Verified how

- `c3c compile-test` (Linux x86-64, c3 0.8.5): 26 `@test` functions in `bleu::color` pass
  (`--test-filter bleu::color`). The new ones cover the schedule's continuity over overlapping edges, the
  validation of day/night and equal sun times, a queued command whose worker returns early, a NaN dimming
  level, and the refusal events (each refusal change announced once). Each new test fails against the
  session-start `schedule.c3` or `service.c3` (checked, then restored). The full suite includes
  `bleu_wl`'s tests, which are not stable (see `docs/research/color_impl.md`, section 6).
- Mock compositor: `src/linux_wlr_test.c3` drives the full exchange (acquire, write, dim, reset, reacquire,
  release on close), a refusal at open, and a `failed` event after a successful write, including the retry.
  A deliberately wrong expected word fails the run (checked, then restored).
- `tools/check.sh bleu_core bleu_rt bleu_service bleu_wl bleu_color`: clean on all six targets.
- `c3fmt --check` clean on every source file.
