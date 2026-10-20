# display: implementation notes (bleu_display)

Spec: `docs/research/display.md`, sections 2.4 (Linux), 2.5 (macOS), 2.6 (Windows), 5 (model), 6 (v1 cut).
Library: `libs/bleu_display.c3l`, README there (API, coverage matrix, Not done).

## Deviations from the research

* **Mutter route not built.** The v1 cut lists Mutter's `GetCurrentState`/`ApplyMonitorsConfig` as a
  second apply route. The Linux brief asks for `bleu_wl`, so Linux is wl_output + xdg-output (read) and
  wlr-output-management (apply). A Mutter backend would need `bleu_dbus`; it is a follow-up.
* **Model changed from the draft (section 5):** `ScaleFactor` and the refresh are `alias`es (exact double and
  millihertz `uint`); `Mode` has no `current` flag (the output's `current` is a `Maybe{Mode}`); `primary`,
  `scale`, `transform`-independent fields, `mirror_of`, `adaptive_sync`, `hdr`, `colour_depth`,
  `edid_fingerprint` are `Maybe`; `Config` carries `persistent`; `Command` holds its `Config` in the
  operation's arena (no fixed buffers). `Cap` names the operations, not the research's list (see README).
* **Revert is the service's job on every platform** (the research's cut says so for Windows; wlr's `failed`
  reverts only a failed apply). `RevertGuard` (pure) decides; `revert_sync` (macOS, Windows) or `start_revert`
  (Linux) applies the previous layout. The previous layout is the state read just before the change, so it
  includes the scale the platform reported (the rollback sets it on wlr).
* **A plain `APPLY` disarms a pending rollback**; a second `APPLY_WITH_REVERT` replaces the first's rollback
  point. Documented on `Display.apply` in `service.c3`.
* **Shutdown with a rollback armed** sends the rollback and does not wait for it (macOS and Windows apply it
  synchronously; Linux sends it and releases the request). The shell is going away, so the change must not
  stay unconfirmed.
* **An unchanged config completes at once** without asking the platform (no compositor request, no CG
  transaction). A test of an unchanged layout therefore reports `live = false` and succeeds locally.
* **Wayland serial rule:** a `cancelled` attempt is retried once with the newest serial when the serial has
  already moved (`RETRY_NOW`), waits for the next `done` otherwise (`WAIT_FOR_SERIAL`), and fails with
  `INVALID_STATE` the second time (`GIVE_UP`). The rule is `wayland_convert::after_cancel`, tested.
* **Windows scale is refused, not approximated.** Scale is read by the research route (`GetDpiForMonitor`),
  which this version does not bind; a config with a scale is refused as UNSUPPORTED.
* **Output ids:** wlr connector name; wl_output name (else xdg name, else `wl-<global>`); CoreGraphics display
  number; Windows monitor device path (the target's identity, as opposed to the GDI name `\\.\DISPLAYn`,
  which changes with the topology).

## What was verified, and against what

* **wlr-output-management opcodes and events** (`src/proto/wlr_output_management.c3`, generated from the
  protocol XML by `tools/wlscan`; the research's WL-OM citations): event and request numbers used in the mock
  tests (`linux_test.c3`) are read from the generated code, not written from memory. Verified by running the
  mock scenarios.
* **CoreGraphics configuration and mode calls** (`macos_native.c3`): signatures, `CGConfigureOption`
  values (ForAppOnly 0, ForSession 1, Permanently 2), `CGDisplayChangeSummaryFlags` (BeginConfigurationFlag
  = 1<<0), `CGDisplayCopyAllDisplayModes`, `kCGDisplayShowDuplicateLowResolutionModes`,
  `CGDisplayMirrorsDisplay`, `CGDisplayRotation` (double) are taken from the objc2-core-graphics 0.3.1 generated
  bindings (`src/generated/CGDisplayConfiguration.rs`, `CGDirectDisplay.rs`), which are generated from the
  Apple SDK headers. **Single source**: the research's UNVERIFIED items for these are now checked against
  that one generated source only. The CFDictionary callback tables (`kCFTypeDictionaryKeyCallBacks`, the
  value variant) are **not** verified against a second source; their field lists are the CoreFoundation
  headers as remembered. Check on a Mac before relying on the duplicate-mode option.
* **Windows display-config structures and constants** (`win_native.c3`): taken from the mingw-w64 `wingdi.h`
  copy in the research scratch directory (`hdr/wingdi.h`): DISPLAYCONFIG_PATH_INFO (72 bytes), path source (20),
  path target (48), mode info (64), the index halves of `modeInfoIdx`, rotation values, device-info types,
  `SDC_*` flags, `QDC_ALL_PATHS`. **Single source** (the research cites the same header via MGW). Sizes are not
  checked at run time (no Windows machine).
* **Windows SetDisplayConfig semantics not verified:** whether unreferenced mode entries are accepted (the
  apply drops a disabled output's path but leaves its mode entries); whether an apply without
  `SDC_SAVE_TO_DATABASE` is session-only (research: UNVERIFIED).
* **EDID identity** (Linux): `/sys/class/drm/cardN-<connector>/edid` read through `bleu_ddc::edid`; the path
  layout is the kernel's DRM connector naming, from memory of `Documentation/gpu/drm-uapi.rst`, not re-fetched.
  Single source.
* **Linux run behaviour:** the mock scenarios run the real `Client`, the real session and listeners, and the
  real state machine. They do not run the worker loop (`run`), so readiness-driven dispatch is unexercised.
* **Pure rules** are unit-tested on Linux; the code is platform-free, so they hold on every host.

## Open for the lead

* Windows `EnumDisplaySettingsExW` reports integer Hz: a 59.94 Hz mode is listed as 60 Hz. The current mode's
  rate is exact (from the path's rational). Full fidelity for the mode list needs the `DEVMODE` frequency
  path the research did not cover.
* `bleu_objc` is a dependency for `bleu::cf` only (the `kCFBooleanTrue` used by the duplicate-mode option);
  CoreGraphics itself is bound directly in `macos_native.c3`. `bleu_win` is used for the message loop and the
  UTF-16 text helpers.
* The `Options.root` field is only for the EDID lookup. It may move to a neutral test hook if other services
  want the same.
