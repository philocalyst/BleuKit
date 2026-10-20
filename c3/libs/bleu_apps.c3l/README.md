# bleu_apps

The application catalogue for launchers and docks: which apps exist, what they
are called and what they run; search over them; start them; hear when they
change. Module root `bleu::apps`. Depends on `bleu_core`, `bleu_rt`,
`bleu_service`, `bleu_xdg`, `bleu_plist`, `bleu_dbus` (Linux D-Bus activation),
`bleu_objc` (macOS) and `bleu_win` (Windows). Design: `docs/ARCHITECTURE.md`;
spec: `docs/research/apps_sysinfo_secrets_appearance.md`, part (A).

## Public API

- `open(allocator, Options)` → `Apps*`; `close()`; `backend_name()`; `capability(Cap)`.
- `latest()` → `CatalogueSnapshot*` (`State{App[] apps}`, sorted by name, then id).
- `wait_after(generation, timeout)`, `watch(listener, ctx)`, `unwatch(id)`.
- `subscribe()` → `Reader{Event}*`: `APP_ADDED`, `APP_REMOVED`, `APP_CHANGED` with `app_id`.
- `refresh()`: rescan now.
- `launch(app_id, LaunchOptions)` → `LaunchOperation*` (`Operation{Launched}`): `Launched{route, pid}`.
- `launch_action(app_id, action_id, LaunchOptions)`: a desktop entry's `[Desktop Action]`.
- `icon_file(icon, size, scale, allocator)` → path of the icon file (Linux).
- `search(query, Ranker, ctx, allocator)` → `Ranking{snapshot, hits}`; `Ranking.release()`.
- Pure functions: `rank(State*, query, ranker, ctx, allocator)`, `sort_catalogue`, `diff_catalogue`.
- Types: `App`, `AppAction`, `AppLaunchKind`, `Cap`, `Backend`, `LaunchOptions`, `LaunchRoute`.

Caller side:

```c3
Apps* apps = apps::open(mem, { })!;
defer apps.close();
CatalogueSnapshot* snap = apps.wait_after(0, time::sec(5))!;
defer snap.release();
Ranking r = apps.search("fire", null, null, mem)!;
defer r.release();
App* top = &r.snapshot.value.apps[r.hits[0].index];
LaunchOperation* op = apps.launch(top.id, { .uris = { "https://example.org" } })!;
defer op.release();
Launched started = op.wait(time::sec(5))!;   // started.route, started.pid (0 when unknown)
```

`LaunchOptions`: `args` (appended to every command line), `files`/`uris` (fill
`%f %F %u %U`), `activation_token` and `startup_id` (passed as
`XDG_ACTIVATION_TOKEN` / `DESKTOP_STARTUP_ID`, or the D-Bus platform data).

## Coverage

Run = executed on Linux x86-64 here. Compiled = type-checked for all six targets
(`compile-only`), never executed. Not done = not implemented.

| Capability | Linux (`xdg-desktop`) | macOS (`app-bundles`) | Windows (`start-menu`) |
| --- | --- | --- | --- |
| Catalogue (scan, precedence, Hidden, NoDisplay, OnlyShowIn/NotShowIn, TryExec) | Run | Compiled | Compiled |
| Sort, diff, events | Run | Compiled | Compiled |
| Search and ranking (`rank`) | Run (pure, all OS) | Run (pure) | Run (pure) |
| Change detection | Run (inotify, debounced) | Compiled (poll of folder names) | Compiled (poll) |
| Launch: spawn `Exec` with `%U` and args, env tokens | Run | n/a | n/a |
| Launch: `%f %F %i %c %k` expansion | Compiled (expansion is unit-tested in `bleu_xdg`, not here) | n/a | n/a |
| Launch: `Terminal=true` | Compiled (not run: no terminal in the test host) | n/a | n/a |
| Launch: D-Bus `Activate` / `Open` / `ActivateAction`; an unanswered activation is not retried through Exec | Run (private dbus-daemon + dbus-next mock) | n/a | n/a |
| Launch: fallback to `Exec` when the bus refuses | Run | n/a | n/a |
| Launch: bundle via `NSWorkspace` | n/a | Compiled | n/a |
| Launch: shortcut via `ShellExecuteW` | n/a | n/a | Compiled |
| Secondary actions (`launch_action`) | Run (Exec and D-Bus) | Not done (UNSUPPORTED) | Not done (UNSUPPORTED) |
| `icon_file` for absolute paths and missing names | Run | Not done | Not done |
| `icon_file` theme lookup | Compiled (uses `bleu_xdg` icon finder; not exercised here) | Not done | Not done |
| Child reaping (zombies) | Compiled (not observed) | n/a | n/a |

Run scripts: `tests/run.sh` (D-Bus; needs `dbus-daemon` and python3 with `dbus-next`,
set `BLEU_APPS_PYTHON`). Unit tests: `c3c compile-test libs/bleu_apps.c3l/src/*.c3`
with the dependencies on `--lib`: the search, change-detection and file-URI tests, the
Linux catalogue, launch, watch and icon tests all pass. `tests/run.sh` passes in about 4 s.

Behaviour changed by the review (see `docs/reviews/bleu_apps_sysinfo_display.md`):
* D-Bus activation: a launch waits at most 2 s (`ACTIVATION_TIMEOUT`). Only "no owner" falls back to
  the Exec line; a timeout or other error is returned, so the app cannot start twice. A call that
  cannot be built (not a bus name) also falls back.
* `DBUS_ACTIVATE` reports `YES` (it used to report "not implemented").
* File URIs are percent-encoded (RFC 3986), so a path with a space, `%`, `#` or `?` names the right file.
* A change is rescanned after the quiet period, or 2 s after its first change at the latest.
* A directory's fingerprint is independent of the order the system lists its entries in.
* `TryExec` of an absolute path is looked up under `Options.root` when a root is set.
* Launches still queued when the worker stops fail with `DISCONNECTED` (the hub's `abandon` hook).

## Not done

- macOS and Windows have no test of their own; their code is type-checked only.
- Windows packaged apps (`shell:AppsFolder`, `IApplicationActivationManager`): not bound, the vtable was not cross-checked.
- Windows `.lnk` targets, arguments and icons are not resolved (`IShellLinkW` not bound); the shortcut itself is the target.
- Windows change detection is polling, not `ReadDirectoryChangesW`; macOS is polling, not FSEvents. Renames inside a bundle or a sub-folder are seen only when the top folder changes or on REFRESH.
- Recently used, running-instance detection, `StartupWMClass` matching: not in this library (the research places them in the shell).
- A multi-file launch (`%f` with several files) spawns each invocation in turn; if a later spawn fails, the
  error is returned although the first child runs, so a retry starts duplicates. Partial success needs a
  result that reports several pids.
- The D-Bus connection is opened once at worker start and not reopened if the bus goes away.
- `TryExec` of a bare name is searched in the host's `$PATH` even with a fake root.
- Closing the bus happens at the end of the worker run; no test covers it (it needs a live bus in a unit test).
- The child environment is this process's environment with the activation variables replaced, not an allow-list.
- Icon themes: `Options.icon_theme` defaults to `hicolor`; the user's theme is not read from GTK or KDE settings.
- Flatpak and Snap export directories are scanned only as XDG data directories (not verified separately).
- `Terminal=true` tries `x-terminal-emulator`, `xterm`, `konsole`, `gnome-terminal` in order, each with `-e` (deprecated for gnome-terminal).
- macOS launch waits up to 10 s for the NSWorkspace completion handler on the worker; if the handler is never delivered (no main run loop), the launch returns `TIMEOUT`. Not verified on a Mac.
- macOS agent apps (`LSUIElement`, background-only) are left out, not listed as `no_display`.
