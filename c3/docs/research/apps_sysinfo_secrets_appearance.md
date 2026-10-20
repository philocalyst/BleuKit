# Research spike: apps, sysinfo, secrets, appearance

Status: research only, 2026-10-20. Nothing in `libs/` was changed.
Scope note: `libs/bleu_xdg.c3l` and `libs/bleu_plist.c3l` are not present in this checkout (only `bleu_core` and `bleu_dl` exist under `libs/`), so the Desktop Entry parser and plist parser are out of scope here, as instructed.

How the claims were checked:
* **Read in full or in relevant part:** sysinfo 0.33.1 (`src/unix/linux`, `src/unix/apple`, `src/windows`), keyring 3.6.2 (`windows.rs`, `macos.rs`), secret-service 4.0.0 (`session.rs`, `util.rs`), ashpd 0.10.2 (`desktop/settings.rs`, `desktop/wallpaper.rs`), dark-light 2.0.0, wallpaper 3.2.0 (`linux/`), security-framework-sys 2.14.0 bindings, objc2-app-kit 0.3.1 generated bindings, fsevent-sys 4.1.0 bindings, core-services 0.1.0 bindings, GIO `gio/gdesktopappinfo.c` (GNOME/glib main), kwalletd `kwalletd.h`/`kwalletd.cpp` (KDE/kwallet master).
* **Specs read:** Desktop Entry spec (gitlab.freedesktop.org xdg-specs raw XML), Secret Service spec pages (specifications.freedesktop.org), Startup Notification spec, xdg-activation-v1 XML, portal Settings and Wallpaper XML (flatpak/xdg-desktop-portal `data/`), kernel docs (proc, cpufreq, hwmon ABI, block stats, iostats), inotify UAPI header.
* **Headers cross-checked:** XNU `osfmk/mach/*.h` and `machine.h` (apple-oss-distributions/xnu), Wine `wincred.h` and `wincrypt.h` (wine-mirror/wine) for Windows constants.
* **Microsoft Learn read:** CredWriteW, CREDENTIALW, CredReadW, CredDeleteW, CryptProtectData, GetSystemTimes, GlobalMemoryStatusEx, GetIfTable2, SystemParametersInfoW, IDesktopWallpaper, UISettings, WM_SETTINGCHANGE, GetDynamicTimeZoneInformation, IShellLinkW, IApplicationActivationManager, ReadDirectoryChangesW, PDH functions.
* **Apple developer pages:** the body text is JavaScript-rendered and not retrievable here. Every Apple behaviour claim that depends on prose (TN3137, NSWorkspace notes) is therefore `(UNVERIFIED)` or sourced from binding doc comments.
* **Not read:** htop and btop sources (only existence checked), DankMaterialShell (only `apppicker/manager.go`, `thememode/manager.go`, `wallpaper/manager.go` read; these are a request queue and a scheduler, with no OS integration), KDE `kdeglobals` internals, Windows `.lnk` parsing code, and the Flatpak/snap export path rules beyond what the Desktop Entry spec says.

Source keys used below (URLs in section 3 of each service):
`[DE]` Desktop Entry spec, `[DBA]` D-Bus Activation section of the same spec, `[SN]` Startup Notification spec, `[XA]` xdg-activation-v1, `[GIO]` gdesktopappinfo.c, `[INO]` inotify.h, `[SS]` Secret Service spec, `[SSC]` secret-service crate, `[PORTAL]` portal Settings XML, `[PWP]` portal Wallpaper XML, `[PROC]` kernel proc.rst, `[HWM]` hwmon ABI, `[CPF]` cpufreq.rst, `[BLK]` block stat.rst, `[SYSI]` sysinfo 0.33.1 crate, `[XNU]` XNU headers, `[WINE]` Wine headers, `[MS-*]` Microsoft Learn page, `[KW]` kwalletd source.

---

# apps

## 1. What a shell needs

1. List installed launchable apps with id, name, generic name, comment, keywords, categories, icon, exec/launch target, terminal flag, actions, MIME types, hidden/NoDisplay, bundle id/AUMID.
2. Search with ranking inputs. Frecency is per app (launch count and recency), not per desktop-file action.
3. Launch with args or URIs, with a startup-notification / activation token so focus moves to the new window. Use `DBusActivatable` when present.
4. Running-instance detection (window to app mapping is the shell's job; the catalogue only provides ids and `StartupWMClass`).
5. Icon file resolution (name or path to a file on disk, size-aware).
6. Recently used list.
7. Catalogue change events when apps are added or removed (inotify, FSEvents, ReadDirectoryChangesW).

## 2. Per-platform native route

### 2.1 Linux

**Catalogue (Desktop Entry).**
* Interface: files `*.desktop` under `$XDG_DATA_HOME/applications` and each `$XDG_DATA_DIRS/applications` entry (basedir spec, `https://specifications.freedesktop.org/basedir-spec/latest/`). Desktop-file id = path relative to the applications dir with `/` replaced by `-`.
* Keys that matter for a launcher (`[DE]`):
  * `Type=Application` (required for launchable entries).
  * `Name`, `GenericName`, `Comment`, `Keywords` (`;`-separated, localised with `Keywords[xx]`), `Categories`.
  * `Icon` (icon name without extension, or an absolute path).
  * `Exec` (required unless `DBusActivatable=true`). Field codes: `%f %F %u %U` (file/URI list, at most one of them per command line), `%i` (expands to `--icon <Icon>`), `%c` (Name), `%k` (desktop-file location). `%F %U %i` may only be standalone arguments. Field codes must not sit inside quoted arguments.
  * `TryExec` (if absent or not executable in PATH, the entry may be hidden).
  * `Terminal` (bool): run `Exec` inside a terminal emulator.
  * `Hidden` (hide everywhere) and `NoDisplay` (hide from menus, still usable for MIME association).
  * `MimeType` (`;`-list), `Actions` (`;`-list of group names `[Desktop Action <name>]`, each with `Name`, `Exec`, `Icon`).
  * `DBusActivatable` (bool, default false): if true, ignore `Exec` and call D-Bus.
  * `StartupNotify` (bool): true means the app sends "remove" after startup with `DESKTOP_STARTUP_ID` set.
  * `StartupWMClass`: window class to match the launched window to the startup sequence.
  * `X-` keys are free-form and not in the spec.
* Mime defaults: `mimeapps.list` (`mime-apps-spec`, `https://gitlab.freedesktop.org/xdg/xdg-specs/-/raw/master/mime-apps/mime-apps-spec.xml`), read the `[Default Applications]` and `[Added Associations]` sections. Parsing is out of scope here.

**Launch.**
* Route A (preferred when `DBusActivatable=true` and the session bus is up): `org.freedesktop.Application` on bus name = desktop-file id without `.desktop`, object path = `/` + id with `.` to `/` and `-` to `_` (`[DBA]`). Methods (from the introspection XML in `[DBA]`):
  * `Activate(a{sv} platform_data)`
  * `Open(as uris, a{sv} platform_data)`
  * `ActivateAction(s action_name, av parameter, a{sv} platform_data)`
  * `platform_data` keys: `desktop-startup-id` (s) and `activation-token` (s), both defined by `[DBA]`.
* Route B (fallback, everything else): fork/exec `Exec` after field-code expansion. Prefer `systemd-run --user --scope -- <argv>` only if the shell wants a cgroup per app (the flag exists in systemd-run; the man page is in `https://raw.githubusercontent.com/systemd/systemd/main/man/systemd-run.xml`, not parsed here).
* Startup notification (`[SN]`): set `DESKTOP_STARTUP_ID` (same token) and `XDG_ACTIVATION_TOKEN` (the xdg-activation token, same string in GIO). The launchee sends `remove:` when done. A `new:` message is equivalent to `change:` if the sequence exists.
* Focus-stealing prevention (`[XA]`): request a token from `xdg_activation_v1.get_activation_token`, then on the `xdg_activation_token_v1` object send `set_serial(serial uint, seat object)`, `set_app_id(string)`, `set_surface(object)`, `commit`. The compositor answers with `done(string token)`. Pass the token to the child as `XDG_ACTIVATION_TOKEN`. Tokens are single-use; `activate(token, surface)` is the request on the global object.

**Icon resolution.** Icon theme spec (`https://specifications.freedesktop.org/icon-theme/latest/`) and freedesktop-icons crate (not downloaded: static.crates.io returned 404 for 0.17.0, so not read). Use `$XDG_DATA_HOME/icons`, `$XDG_DATA_DIRS/icons`, `/usr/share/pixmaps`, and the theme's `index.theme` for size lookup. The icon name may be an absolute path (`[DE]`).

**Running-instance detection.** Not in the catalogue. Options: `StartupWMClass`, the window's app-id on Wayland (`xdg_toplevel` app_id), or the process path of the `Exec` binary. Only the shell's window source can answer this. Not researched further.

**Recently used.** `$XDG_DATA_HOME/recently-used.xbel` (GTK / freedesktop recent-file format). The spec URL `https://specifications.freedesktop.org/recent-file-spec/latest/` returned 404; the XBEL file name and location are `(UNVERIFIED)` for this spike. Alternative: keep your own frecency store, which the contract already requires.

**Change events.** inotify (`[INO]`, kernel `include/uapi/linux/inotify.h`):
* Flags: `IN_CREATE 0x00000100`, `IN_DELETE 0x00000200`, `IN_MOVED_FROM 0x00000040`, `IN_MOVED_TO 0x00000080`, `IN_CLOSE_WRITE 0x00000008`, `IN_ATTRIB 0x00000004`, `IN_DELETE_SELF 0x00000400`, `IN_MOVE_SELF 0x00000800`, `IN_ONLYDIR 0x01000000`, `IN_DONT_FOLLOW 0x02000000`, `IN_ISDIR 0x40000000`, `IN_Q_OVERFLOW 0x00004000`, `IN_IGNORED 0x00008000`.
* `inotify_init1` accepts `IN_NONBLOCK` (= `O_NONBLOCK`) and `IN_CLOEXEC` (= `O_CLOEXEC`).
* On `IN_Q_OVERFLOW`, rescan the directories (the contract's rule: the cure is re-reading the observable).
* Flatpak and snap export dirs (`~/.local/share/flatpak/exports/share/applications`, `/var/lib/flatpak/exports/share/applications`, `/var/lib/snapd/desktop/applications`) are `(UNVERIFIED)` from memory; the flatpak doc URL returned 404. Watch them as normal `applications` dirs, which is what XDG_DATA_DIRS implies.

**Pitfalls.**
* GIO only uses D-Bus activation if `DBusActivatable=true`, the desktop-file basename is a valid D-Bus name not starting with `:`, and the session bus object exists. Otherwise it spawns `Exec` (`[GIO]` `g_desktop_app_info_launch_uris_with_spawn` / `launch_uris_with_dbus`, around lines 2068-2090 and 3554-3570). The D-Bus call has no spawn fallback if the name is not activatable.
* GIO, in the spawn path, sets both `DESKTOP_STARTUP_ID` and `XDG_ACTIVATION_TOKEN` to the same startup-notify id (`[GIO]` lines 3054-3055). It is not a standard-conforming "activation token" in general, but it is what the reference implementation does.
* `Exec` field codes inside quotes are undefined (`[DE]`).

### 2.2 macOS

**Catalogue.**
* Scan `/Applications`, `~/Applications`, `/System/Applications`, `/System/Applications/Utilities`, and nested folders for `*.app` bundles. Read `Contents/Info.plist`: `CFBundleIdentifier` (bundle id), `CFBundleDisplayName` / `CFBundleName`, `CFBundleIconFile` or `CFBundleIconName`, `LSUIElement` / `LSBackgroundOnly` (agent apps, hide from launcher), `CFBundleDocumentTypes` (document types, roughly the MIME analogue). Plist parsing is out of scope (`libs/bleu_plist.c3l` absent).
* Alternatively, LaunchServices gives you the installed URLs for a bundle id: `LSCopyApplicationURLsForBundleIdentifier(CFStringRef bundleID, CFErrorRef *outError) -> CFArrayRef` (`core-services` crate binding, `src/lib.rs:121`, single-source; Apple declaration not fetched).
* Spotlight: `NSMetadataQuery` with `kMDItemKind == 'Application'` (task brief; not verified here, `(UNVERIFIED)`).

**Launch.**
* `NSWorkspace openApplicationAtURL:configuration:completionHandler:` (task brief; objc2-app-kit bindings were not grepped for this selector, so `(UNVERIFIED)` as to exact Swift/ObjC name in 0.3.1).
* Pass arguments via `NSWorkspaceOpenConfiguration.arguments`, and files via `openURLs:withApplicationAtURL:...` (names from memory, `(UNVERIFIED)`).
* `NSWorkspace urlForApplicationWithBundleIdentifier:` gives the app URL (task brief, `(UNVERIFIED)` in bindings).

**Icons.** `NSWorkspace iconForFile:` gives an `NSImage`; encode to PNG for transport (task brief; the `.icns` route is a parse task of its own).

**Change events.** FSEvents (`fsevent-sys` 4.1.0 bindings, `src/fsevent.rs`, single-source):
* `kFSEventStreamCreateFlagFileEvents = 0x00000010` (per-file events, needed to see file names), `kFSEventStreamCreateFlagWatchRoot = 0x00000004`, `kFSEventStreamCreateFlagNoDefer = 0x00000002`, `kFSEventStreamCreateFlagIgnoreSelf = 0x00000008`.
* Item flags: `kFSEventStreamEventFlagItemCreated = 0x00000100`, `kFSEventStreamEventFlagItemRenamed = 0x00000800`.
* `kFSEventStreamEventIdSinceNow = 0xFFFFFFFFFFFFFFFF`.
* Rescan on `kFSEventStreamEventFlagMustScanSubDirs` (the flag is referenced in the binding but its value was not checked here, `(UNVERIFIED)`).

**Permissions.** None for `/Applications` reads. `NSWorkspace` launch needs nothing extra.

**Pitfalls.** Agent apps (`LSUIElement`) and helper bundles inside other apps' `Contents/` are the usual sources of duplicate entries. Skip nested bundles under `Contents`.

### 2.3 Windows

**Catalogue.** Three sources, deduplicated by AUMID or target path:
1. Start Menu shortcuts: `%ProgramData%\Microsoft\Windows\Start Menu\Programs` and `%AppData%\Microsoft\Windows\Start Menu\Programs`, `*.lnk`. Resolve with `IShellLinkW` + `IPersistFile::Load` (`[MS-shlink]` at `https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nn-shobjidl_core-ishelllinkw`, fetched: confirms the interface exists; the `GetPath` / `GetArguments` / `GetIconLocation` member list was not parsed here, so the method names are `(UNVERIFIED)` as written).
2. Packaged (UWP / MSIX) apps: enumerate `shell:AppsFolder` (IShellItem enumeration), each item has an AUMID (`Package family name!AppId`).
3. Registry App Paths: `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths` (memory, `(UNVERIFIED)` in this spike).

**Launch.**
* Classic apps: `ShellExecuteExW` or `CreateProcessW` on the target path with arguments.
* Packaged apps: `IApplicationActivationManager::ActivateApplication(appUserModelId, arguments, options, &processId)` (Learn page fetched: the interface and method name exist; `ActivateForFile` and `ActivateForProtocol` also exist on the same interface; the options enum values `AO_NONE` etc. were not verified).
* Requires COM initialised on the worker thread (apartment rules are part of the bleu_win work, not researched here).

**Icons.** `IShellItemImageFactory::GetImage` (for AppsFolder items) or `SHDefExtractIconW` (for `.exe` / `.lnk` targets). `(UNVERIFIED)` as to exact flags.

**Change events.** `ReadDirectoryChangesW` on the Start Menu folders (Learn page fetched, `https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-readdirectorychangesw`, ~10 KB, not fully parsed). Packaged-app changes do not appear as file events; re-enumerate `shell:AppsFolder` on a timer or on package events (`(UNVERIFIED)`).

**Reference.** Flow Launcher (task brief, not read).

## 3. Reference implementations

| Project | Language | File (raw URL) | Read? | Idea to copy |
| --- | --- | --- | --- | --- |
| GLib / GIO `GDesktopAppInfo` | C | `https://raw.githubusercontent.com/GNOME/glib/main/gio/gdesktopappinfo.c` | read (launch, DBusActivatable, platform_data) | D-Bus activation decision, platform_data keys, env vars for startup-notify |
| freedesktop-desktop-entry 0.7.0 | Rust | `static.crates.io/crates/freedesktop-desktop-entry/...-0.7.0.crate` (`src/`, 7 .rs files) | downloaded, not read | desktop-entry model; not read in this spike |
| ashpd 0.10.2 | Rust | `static.crates.io/crates/ashpd/ashpd-0.10.2.crate` `src/desktop/settings.rs`, `src/desktop/wallpaper.rs` | read | portal Settings reads, Read double-variant handling, Wallpaper options |
| dark-light 2.0.0 | Rust | `static.crates.io/crates/dark-light/...` `src/platforms/{freedesktop,macos,windows}.rs` | read | portal-first detection with 25 ms timeout; macOS NSUserDefaults key; Windows registry DWORD |
| wallpaper 3.2.0 | Rust | `static.crates.io/crates/wallpaper/...` `src/linux/{mod,gnome,kde,xfce,lxde}.rs` | read | per-desktop wallpaper backends |
| keyring 3.6.2 | Rust | (see section 2 of secrets) | read | secrets, not apps |
| sysinfo, htop, btop | Rust, C, C++ | htop `linux/LinuxProcessTable.c` and btop `src/linux/btop_collect.cpp` exist on raw.githubusercontent.com | htop and btop existence only | not used for apps |
| DankMaterialShell | Go | `https://raw.githubusercontent.com/AvengeMedia/DankMaterialShell/master/core/internal/server/apppicker/manager.go` | read (48 lines) | apps logic is not in this file; the manager is a pub/sub open-request queue only |
| Quickshell DesktopEntries | C++ | `Quickshell/quickshell` desktop entry service path not found by probe | not read | (UNVERIFIED path) |

## 4. Double validation

| Claim | Source A | Source B | Status |
| --- | --- | --- | --- |
| `DBusActivatable=true`: ignore Exec, send D-Bus; `Exec` still recommended | `[DE]` | `[GIO]` (only DBus-activates when the flag is set) | 2 sources |
| D-Bus object path = `/` + id with `.`→`/`, `-`→`_` | `[DBA]` | `[GIO]` `object_path_from_appid` (lines 3336-3340 handle `.` and `-`) | 2 sources |
| Methods Activate(a{sv}), Open(as, a{sv}), ActivateAction(s, av, a{sv}) | `[DBA]` introspection XML | `[GIO]` calls "Activate"/"Open"/"ActivateAction" | 2 sources |
| `platform_data` keys `desktop-startup-id` and `activation-token` | `[DBA]` | `[GIO]` lines 3366-3367 | 2 sources |
| GIO sets `XDG_ACTIVATION_TOKEN` equal to `DESKTOP_STARTUP_ID` | `[GIO]` lines 3054-3055 | none | (single-source) |
| xdg-activation: `get_activation_token`, token `set_serial/set_app_id/set_surface/commit`, `done(token)`, `activate(token, surface)` | `[XA]` XML | none | (single-source) |
| Field codes and standalone rule for `%F %U %i` | `[DE]` | none | (single-source) |
| inotify flag values | `[INO]` uapi header | none | (single-source) |
| FSEvents flag values | `fsevent-sys` 4.1.0 binding | none | (single-source) |
| LaunchServices `LSCopyApplicationURLsForBundleIdentifier` | `core-services` 0.1.0 binding | none | (single-source) |
| Flatpak/snap export dirs | none | none | (UNVERIFIED) |
| `recently-used.xbel` path | none | none | (UNVERIFIED) |
| `IApplicationActivationManager::ActivateApplication` name | `[MS-activation]` page title | none | (single-source, name only) |

## 5. Proposed Bleu model

```c3
// Desktop Entry tree for each app; platform-neutral, plain data (contract rule 1).
struct AppEntry {
    String id;              // desktop-file id (Linux), AUMID (Windows), bundle id (macOS)
    String name;
    String generic_name;
    String comment;
    String[] keywords;
    String[] categories;
    AppIcon icon;           // name or absolute path, never a pointer
    AppLaunch launch;       // see below
    bool terminal;
    bool hidden;            // Hidden / LSUIElement / not listed in start menu
    bool no_display;        // NoDisplay: usable, not listed
    AppAction[] actions;
    String[] mime_types;
    String startup_wm_class;
    bool startup_notify;
    bool dbus_activatable;  // Linux only; false elsewhere
}

enum AppLaunchKind : char { EXEC, DBUS_ACTIVATE, LAUNCH_SERVICES, PACKAGED_ACTIVATE }
struct AppLaunch { AppLaunchKind kind; String target; }  // Exec argv / bus name / bundle URL / AUMID

struct AppAction { String id; String name; String exec; String icon; }

// Operations (contract rule 4): launch is an Operation{Value}.
// Launch options carry the activation token and args/URIs.
struct LaunchOptions { String[] args; String[] uris; String activation_token; bool new_instance; }

// Capabilities (contract rule 5)
enum AppCap : char { LIST, LAUNCH, LAUNCH_ACTION, ICON, WATCH, RECENT, SEARCH_RANKING, RUNNING_DETECT }
```

Backend list per OS:
* Linux: `desktop_entry` (XDG dirs + Desktop Entry), `flatpak_snap` (same, extra dirs), `mime` (mimeapps only for `mime_types`).
* macOS: `bundle_scan` (Info.plist), `launch_services` (LSCopyApplicationURLs, NSWorkspace launch), `spotlight` optional.
* Windows: `start_menu` (`.lnk`), `apps_folder` (packaged), `app_paths` optional.

Platform-unavailable fields: `startup_wm_class` (macOS, Windows), `dbus_activatable` (macOS, Windows), `recent` (macOS, Windows need separate sources), `AUMID` (Linux: none).

## 6. Risks and cut lines

* `.lnk` parsing via COM is slow and fragile; the shell must cache results.
* Packaged apps change without file events; re-enumerate `AppsFolder`.
* macOS launch via LaunchServices may prompt for permissions in sandboxed setups (`(UNVERIFIED)`).
* Activation tokens are single-use and time-limited; a token minted too early is rejected (the compositor rule, `[XA]`).
* Cut line for v1: Linux desktop entries and Start Menu `.lnk` only. Defer packaged apps, Spotlight, recently used, and running-instance detection.

---

# sysinfo

## 1. What a shell needs

1. Total CPU usage percent and per-core percent, CPU frequency, CPU temperature, load average, CPU model string.
2. Memory: total, used, available, cached, swap total/used.
3. Disks: mounts, total/used/free, read and write rates.
4. Network throughput per interface (rx and tx bytes per second).
5. GPU basics: utilisation, temperature, VRAM used (vendor-specific, see risks).
6. Temperatures and fans.
7. Uptime, hostname, OS name and version, kernel, architecture.
8. Top processes: pid, name, cpu %, memory, user.
9. Process kill (signal or TerminateProcess).

Polling cadence: CPU percent needs two samples at least `MINIMUM_CPU_UPDATE_INTERVAL` apart (200 ms on Linux, macOS and Windows per `[SYSI]`). Shells typically poll at 1 s; process CPU uses the same totals.

## 2. Per-platform native route

### 2.1 Linux

**CPU usage (total and per core).**
* Source: `/proc/stat`, first line `cpu` (aggregate), then `cpuN` lines. Fields in USER_HZ units (`[PROC]` 1.7): `user nice system idle iowait irq softirq steal guest guest_nice`.
* Algorithm (`[SYSI]` `unix/linux/cpu.rs` lines 286-325): `work = user + nice + system + irq + softirq`, `total = work + idle + iowait + guest + guest_nice`. `percent = (work_new - work_old) / (total_new - total_old) * 100`, clamped to 100. `guest` is subtracted from `user` and `guest_nice` from `nice` when the values are stored (`cpu.rs` lines 219-223).
* Steal is not added to total (`cpu.rs` comment). Do not invent a different total without a reason.
* Call sequence:
  1. Read `/proc/stat` into a snapshot.
  2. Wait at least 200 ms (or simply the poll interval).
  3. Read again. Compute deltas per line.
  4. Store the new snapshot as "old".
* Frequency: `/sys/devices/system/cpu/cpu<N>/cpufreq/scaling_cur_freq`, unit kHz (`[CPF]` `scaling_cur_freq`; `[SYSI]` `cpu.rs` line 410). `cpuinfo_cur_freq` is the same unit (`[CPF]`).
* Model string: `/proc/cpuinfo` (`model name` line; `[SYSI]` line 423).

**Temperatures and fans.**
* hwmon: `/sys/class/hwmon/hwmon<N>/name`; `temp<k>_input` in millidegree Celsius, `temp<k>_label`, `temp<k>_crit`; `fan<k>_input` in RPM (`[HWM]` ABI `sysfs-class-hwmon`, lines 403 and 420 for millidegree, 218-272 for RPM).
* Fallback: `/sys/class/thermal/thermal_zone0/temp` (`[SYSI]` `component.rs` lines 429-433).

**Memory.**
* `/proc/meminfo` values in kB (multiply by 1024). Keys: `MemTotal`, `MemFree`, `MemAvailable`, `Buffers`, `Cached`, `Shmem`, `SReclaimable`, `SwapTotal`, `SwapFree` (`[SYSI]` `system.rs` lines 228-250; `[PROC]` documents `MemAvailable` around line 1062).
* If `MemAvailable` is missing (Linux < 3.14), fall back to `free + buffers + cached + sreclaimable - shmem` (`system.rs` lines 243-250).
* Used = total - available (sysinfo convention; not stated in the proc docs, `(single-source)`).

**Load average, uptime.** `/proc/loadavg` (1, 5, 15 min) and `/proc/uptime` (seconds since boot, first field) per `[PROC]` lines 767 and 794.

**Disks.**
* Mounts: `/proc/mounts`. `statvfs` on each mount for size and free (`[SYSI]` `unix/linux/disk.rs` lines 158, 207-223).
* I/O: `/proc/diskstats` fields 3 (sectors read) and 7 (sectors written). Sectors are always 512 bytes (`[BLK]` "The sectors in question are the standard UNIX 512-byte sectors"; `[SYSI]` `disk.rs` line 29 `SECTOR_SIZE = 512`). Rate = delta bytes / delta seconds.
* Map a mount to its device name by reading `/proc/mounts` then resolving `/dev/...` to `/sys/block/<disk>` (`disk.rs` lines 186-315).

**Network.** Per interface: `/sys/class/net/<if>/statistics/rx_bytes` and `tx_bytes` (`[SYSI]` `unix/linux/network.rs` lines 41-61; the code reads `statistics/` under each interface). Rate = delta / delta seconds. Skip `lo` by policy.

**Process list and CPU per process.**
* `/proc/<pid>/stat`: fields `utime` and `stime` (jiffies; `[PROC]` lines 339-342), `starttime` (jiffies since boot), `comm`, state. `/proc/<pid>/status` for `Uid:`, `VmRSS`, Name.
* Process CPU percent = `(utime_new + stime_new - utime_old - stime_old) / total_time_delta * 100`, clamped to `number_of_cpus * 100` (`[SYSI]` `unix/linux/process.rs` lines 288-302). The first refresh has no reference and returns 0.
* `starttime` converted to seconds by dividing by the clock cycle (`process.rs` line 362; `sysconf(_SC_CLK_TCK)` is USER_HZ).

**Process kill.** `kill(pid, SIGTERM|SIGKILL)` (POSIX). Permission failures are `EPERM`. Signal numbers are not verified in this spike (`(UNVERIFIED)` for numeric values).

**GPU.**
* AMD (amdgpu): `/sys/class/drm/card<N>/device/gpu_busy_percent` and `mem_info_vram_used` / `mem_info_vram_total` are the documented sysfs attributes (`[PROC]`-adjacent amdgpu doc link `Documentation/gpu/amdgpu/thermal.rst` fetched; the ABI attribute list was not parsed, `(UNVERIFIED)` for exact names).
* NVIDIA: NVML (`nvmlDeviceGetUtilizationRates`, `nvmlDeviceGetTemperature`) via dlopen. Not researched here.
* Intel: no stable sysfs utilisation. `(UNVERIFIED)`.

**Hostname, OS, kernel, arch.** `uname(2)` (`sysname`, `release`, `machine`, `nodename`) and `/etc/os-release` `PRETTY_NAME` (sysinfo does this, not re-read here).

**Permissions.** None for `/proc` and `/sys` reads on a normal desktop. Reading other users' `/proc/<pid>/` may fail (EPERM) and must be a per-process `Option`.

### 2.2 macOS

**CPU total and per core (`[XNU]` headers).**
* `host_processor_info(host, PROCESSOR_CPU_LOAD_INFO=2, &cpu_count, &info, &info_count)` returns `processor_cpu_load_info` per CPU (`osfmk/mach/processor_info.h` line 94 for the constant, line 114-115 for the struct: `unsigned int cpu_ticks[CPU_STATE_MAX]`).
* `CPU_STATE_USER = 0`, `CPU_STATE_SYSTEM = 1`, `CPU_STATE_IDLE = 2`, `CPU_STATE_NICE = 3`, `CPU_STATE_MAX = 4` (`osfmk/mach/machine.h` lines 74-79).
* Total: `host_cpu_load_info` via `host_statistics(host, HOST_CPU_LOAD_INFO=3, ...)` (`osfmk/mach/host_info.h` line 193 and struct at line 279) gives aggregate ticks.
* Percent: delta(user + system + nice) / delta(all four) * 100, per CPU and aggregate.
* sysinfo uses `host_processor_info` in `unix/apple/macos/system.rs` lines 15-40, and derives time with `mach_timebase_info` (`unix/apple/cpu.rs` lines 340-400, approximately).
* Mach ports: `mach_host_self()` returns the host port. Release the returned array with `vm_deallocate` (sysinfo calls `munmap` on the buffer, `macos/system.rs` line 50, `(single-source)`).

**Memory (`[XNU]` `vm_statistics.h` and sysinfo).**
* `host_statistics64(host, HOST_VM_INFO64=4, (host_info64_t)&stat, &count)` with `count = HOST_VM_INFO64_COUNT` (`host_info.h` lines 196, 244).
* Fields of `vm_statistics64`: `free_count`, `active_count`, `inactive_count`, `wire_count`, `purgeable_count`, `speculative_count`, `compressor_page_count`, `throttled_count`, `external_page_count`, `internal_page_count`, plus 64-bit counters (`xnu_vm_statistics.h`).
* sysinfo formulas (`unix/apple/system.rs` lines 189-205), multiplied by the page size:
  * available = free + inactive + purgeable - compressor_page_count
  * used = active + wire + compressor + speculative
  * free = free - speculative
* Total: `hw.memsize` sysctl (`mem::size_of::<u64>()` in `system.rs` lines 175-182).
* Swap: `vm.swapusage` sysctl (`(UNVERIFIED)` in this spike; not read).

**Frequency.** `sysctlbyname("hw.cpufrequency")`, unit Hz, sysinfo divides by 1 000 000 for MHz (`unix/apple/cpu.rs` lines 200-215). If the sysctl fails, sysinfo returns 0. Whether Apple Silicon lacks the key is `(UNVERIFIED)`; treat the value as optional.

**Load average.** `getloadavg(3)` (`unix/apple/system.rs` line 379).

**Uptime.** `sysctl kern.boottime` (`timeval`), uptime = now - boottime (sysinfo `unix/apple/system.rs`, `(single-source)`).

**Temperatures and fans.** SMC via IOKit (`AppleSMC`), keys like `TC0P` (CPU proximity), `F0Ac` (fan RPM) are the community convention. sysinfo has `unix/apple/macos/component/` (`x86.rs`, `mod.rs`) for SMC. Not read in full; `(UNVERIFIED)` for key names.

**Disks.** `statfs` / `getmntinfo` for mounts; IOKit `IOBlockStorageDriver` `Statistics` dictionary for I/O bytes. `(UNVERIFIED)` for the key names.

**Network.** `getifaddrs` with `AF_LINK` entries and `if_data` (`ifi_ibytes`, `ifi_obytes`). `(UNVERIFIED)` in this spike.

**Process list.** `sysctl(KERN_PROC_ALL)` or `libproc` `proc_listpids` / `proc_pidinfo(PROC_PIDTASKINFO)` (`pti_total_user`, `pti_total_system`). sysinfo implements this in `unix/apple/macos/process.rs` (not read in this spike).

**Process kill.** `kill(2)`, same as Linux.

**Permissions.** Some process and disk info needs no entitlement. Full-disk access (TCC) may hide some paths. Not checked.

### 2.3 Windows

**CPU total and per core.**
* sysinfo uses PDH counters `\Processor(_Total)\% Idle Time` and `\Processor(N)\% Idle Time`, then `usage = 100 - idle` (`[SYSI]` `windows/system.rs` lines 113-160). It adds English counter names via `PdhAddEnglishCounterA` to avoid localisation (`windows/cpu.rs` line 94).
* Alternative with no PDH: `GetSystemTimes(&idle, &kernel, &user)`. Kernel time includes idle time (`[MS-GetSystemTimes]`: "This time value also includes the amount of time the system has been idle"). So busy = (kernel + user - idle) (kernel already contains idle; busy = kernel + user - idle) and percent = busy_delta / (kernel_delta + user_delta) * 100.

**Frequency.** `CallNtPowerInformation(ProcessorInformation, ...)` returns `PROCESSOR_POWER_INFORMATION` with `CurrentMhz`, `MaxMhz` (`[SYSI]` `windows/cpu.rs` lines 488-505).

**Memory.** `GlobalMemoryStatusEx(MEMORYSTATUSEX)`: `ullTotalPhys`, `ullAvailPhys`, `ullTotalPageFile`, `ullAvailPageFile` (`[SYSI]` `windows/system.rs` lines 175-182; `[MS-GMSE]` Learn page fetched, exists).

**Disks.**
* Free and total: `GetDiskFreeSpaceExW` (`[SYSI]` `windows/disk.rs` line 258).
* Mounts / volumes: `FindFirstVolumeW` / `FindNextVolumeW` (`disk.rs` line 14).
* I/O: `IOCTL_DISK_PERFORMANCE` via `DeviceIoControl` returning `DISK_PERFORMANCE` (`disk.rs` lines 416-426). Requires the disk performance counters to be enabled (`diskperf -y`) on older Windows (`(UNVERIFIED)` for current defaults).

**Network.** `GetIfTable2` returns `MIB_IF_TABLE2` with per-interface `InOctets` / `OutOctets` (`[SYSI]` `windows/network.rs` line 37; `[MS-GetIfTable2]` page fetched). `GetAdaptersAddresses` for names and addresses (`network_helper.rs` line 115).

**Processes.** `NtQuerySystemInformation(SystemProcessInformation, ...)` (`[SYSI]` `windows/system.rs` lines 247-277). The function is in `ntdll` and is documented by winternl / phnt headers, not by Microsoft Learn (`(single-source: sysinfo)`). Per-process CPU: kernel and user times from `GetProcessTimes` (`process.rs` line 446). Process I/O: `GetProcessIoCounters`. Process user: `OpenProcessToken` + `GetTokenInformation` (`process.rs` line 44).

**Uptime.** `GetTickCount64()` (ms since boot; `[SYSI]` `windows/system.rs` line 75).

**Hostname.** `GetComputerNameExW(ComputerNamePhysicalDnsHostname, ...)` (`system.rs` line 31).

**Temperatures.** WMI `root\WMI` class `MSAcpi_ThermalZoneTemperature` (`[SYSI]` `windows/component.rs` lines 214-256). The value is in tenths of Kelvin (`(UNVERIFIED)` for unit; read from memory). Many machines expose no ACPI thermal zone, so the value is optional.

**GPU.** DXGI `IDXGIAdapter3::QueryVideoMemoryInfo` gives budget and usage; vendor utilisation needs NVML / ADLX / PDH GPU Engine counters. Not researched here (`(UNVERIFIED)`).

**Process kill.** `TerminateProcess(handle, exitCode)` with `PROCESS_TERMINATE` access (not verified in this spike).

**Permissions.** Reading other users' processes requires `PROCESS_QUERY_LIMITED_INFORMATION`, and some system processes need elevation (`(UNVERIFIED)` for the exact access mask rules).

## 3. Reference implementations

| Project | Language | File | Read? | Idea |
| --- | --- | --- | --- | --- |
| sysinfo 0.33.1 | Rust | `static.crates.io/crates/sysinfo/sysinfo-0.33.1.crate`: `src/unix/linux/{cpu,system,disk,network,process,component}.rs`, `src/unix/apple/{system,cpu,macos/system,macos/process}.rs`, `src/windows/{cpu,system,disk,network,process,component}.rs` | read the lines cited | best map for every platform (this is the primary reference) |
| htop | C | `https://raw.githubusercontent.com/htop-dev/htop/main/linux/LinuxProcessTable.c` | existence only (200 OK) | per-process fields from `/proc` |
| btop | C++ | `https://raw.githubusercontent.com/aristocratos/btop/main/src/linux/btop_collect.cpp` | existence only | collector structure |
| glances, neofetch, fastfetch | Python, bash, C | not fetched | no | uname / os-release conventions |
| DankMaterialShell sysmon | Go | `core/internal/server/sysmon/*.go` not found at expected paths; `dgop` is an external module (`core/go.mod`) | no | `dgop` is the likely source; not read |

## 4. Double validation

| Claim | Source A | Source B | Status |
| --- | --- | --- | --- |
| `/proc/stat` cpu field order and USER_HZ | `[PROC]` 1.7 | `[SYSI]` `cpu.rs` lines 205-215 | 2 sources |
| CPU percent formula | `[SYSI]` `cpu.rs` 286-325 | `[PROC]` (semantics) | 2 sources (formula only in sysinfo) |
| MemAvailable fallback formula | `[SYSI]` `system.rs` 243-250 | `[PROC]` 1062/1127 (MemAvailable exists) | 2 sources for presence, (single-source) for fallback formula |
| scaling_cur_freq unit kHz | `[CPF]` lines 294-295 | `[SYSI]` `cpu.rs` line 410 | 2 sources |
| hwmon temp millidegree C, fan RPM | `[HWM]` ABI lines 403, 420, 218 | `[SYSI]` `component.rs` (reads temp inputs as millidegree) | 2 sources |
| diskstats sectors are 512 bytes | `[BLK]` lines 67-72 | `[SYSI]` `disk.rs` line 29 | 2 sources |
| `host_processor_info` PROCESSOR_CPU_LOAD_INFO = 2 | `[XNU]` `processor_info.h` line 94 | `[SYSI]` `macos/system.rs` line 8 imports the constant | 2 sources |
| CPU_STATE_* values | `[XNU]` `machine.h` 76-79 | `[SYSI]` macOS CPU ticks index them | 2 sources |
| HOST_VM_INFO64 = 4, HOST_CPU_LOAD_INFO = 3 | `[XNU]` `host_info.h` 193, 196 | `[SYSI]` `apple/system.rs` line 184-187 | 2 sources |
| macOS mem_available / mem_used formulas | `[SYSI]` `apple/system.rs` 189-205 | none | (single-source) |
| hw.cpufrequency absent on Apple Silicon | none | none | (UNVERIFIED) |
| GetSystemTimes kernel includes idle | `[MS-GetSystemTimes]` | none (sysinfo does not use this to compute totals) | (single-source) |
| Windows CPU via PDH "% Idle Time" | `[SYSI]` `windows/system.rs` 113-160 | none | (single-source) |
| CRED/WMI/NtQuery are Windows names | Learn page / sysinfo imports | none | per row |
| MSAcpi tenths-of-Kelvin | none | none | (UNVERIFIED) |
| SMC key names | none | none | (UNVERIFIED) |

## 5. Proposed Bleu model

```c3
// Plain data only (contract rule 1). Every field is a scalar, a typedef quantity, String or slice.
typedef Percent = float;     // 0..100
typedef Bytes = ulong;
typedef BytesPerSec = ulong;
typedef Mhz = uint;
typedef Celsius = float;
typedef Rpm = uint;

struct CpuCoreUsage { String id; Percent usage; Mhz freq; }
struct CpuState {
    String model;             // "" when unknown
    Percent total_usage;      // Unavailable -> Cap value UNSUPPORTED_CPU_USAGE
    CpuCoreUsage[] cores;
    Mhz frequency;            // 0 means unknown (macOS Apple Silicon may stay 0)
    Celsius temperature;      // NaN not allowed; use Sensor.available
    float[3] load_average;    // 1, 5, 15 min
}
struct MemState { Bytes total; Bytes used; Bytes available; Bytes cached; Bytes swap_total; Bytes swap_used; }
struct DiskState { String mount; String device; Bytes total; Bytes available; BytesPerSec read_rate; BytesPerSec write_rate; }
struct NetIface { String name; BytesPerSec rx_rate; BytesPerSec tx_rate; }
struct GpuState { String name; Percent utilisation; Celsius temperature; Bytes vram_used; Bytes vram_total; }
struct FanState { String label; Rpm rpm; }
struct TempState { String label; Celsius value; }
struct ProcessInfo { uint pid; String name; Percent cpu; Bytes memory; String user; }
struct SystemInfo { String hostname; String os; String os_version; String kernel; String arch; ulong uptime_seconds; }

// Sysinfo snapshot: one immutable struct tree
struct SysinfoState {
    CpuState cpu;
    MemState mem;
    DiskState[] disks;
    NetIface[] networks;
    GpuState[] gpus;
    TempState[] temps;
    FanState[] fans;
    ProcessInfo[] top_processes;
    SystemInfo system;
}

enum SysinfoCap : char { CPU_USAGE, CPU_PER_CORE, CPU_FREQUENCY, CPU_TEMPERATURE, GPU, FANS, TEMPERATURES, DISK_IO, NET_RATES, PROCESS_KILL }
```

Backends per OS:
* Linux: `procfs_sysfs` (default), `sysinfo_fallback` (optional, not needed if the procfs path is complete).
* macOS: `mach_host` (host_processor_info, host_statistics64), `sysctl` (mem, boottime), `smc_private` (temperatures, runtime-resolved, see section 6).
* Windows: `pdh_wmi` (CPU via PDH, temperature via WMI), `win_api` (memory, disks, net, process via NtQuery).

Unavailable on a platform: GPU on Windows and macOS without vendor tools, fans on macOS without SMC, process `user` on Windows without token access.

## 6. Risks and cut lines

* Delta CPU needs two samples. The first snapshot must return 0 and the API must say so (`Availability` with a reason), never a silent zero.
* macOS temperatures and fans use SMC, a private interface. Resolve at run time (contract: `bleu::dl`) and mark each use in a `*_private.c3` file with OS versions observed. Not verified here.
* Windows temperatures via WMI are often absent on consumer hardware. Treat as optional.
* Per-process data for other users needs elevation on Windows and may be denied on Linux (`hidepid`). Optional per process.
* GPU is vendor-specific. Cut line for v1: no GPU.
* Process kill: on Windows, `TerminateProcess` is not a graceful stop; state that in the operation's result.
* Cut line for v1: CPU total, memory, disks (usage only), uptime, OS strings, top processes by CPU, kill. Defer per-core frequency, fans, GPU, and macOS temperatures.

---

# secrets

## 1. What a shell needs

1. Store, read and delete secrets (Wi-Fi passwords, VPN passwords, tokens) keyed by a service and an account.
2. Prompts when the keyring is locked (the shell must not block forever).
3. No plaintext in logs, and no secret in the shell's own snapshot state (secrets go through a separate operation, not the `State` struct).
4. Fallbacks when a keyring service is missing (KWallet on KDE; no service at all).

## 2. Per-platform native route

### 2.1 Linux

**Route 1 (preferred): Secret Service over D-Bus.**
* Bus name `org.freedesktop.secrets`, service object `/org/freedesktop/secrets`, interfaces `org.freedesktop.Secret.Service`, `.Collection`, `.Item`, `.Session`, `.Prompt` (`[SS]` Interfaces chapter).
* Service methods (`[SS]` `org.freedesktop.Secret.Service`):
  * `OpenSession(s algorithm, v input, out v output, out o result)`
  * `CreateCollection(a{sv} properties, s alias, out o collection, out o prompt)`
  * `SearchItems(a{ss} attributes, out ao unlocked, out ao locked)`
  * `Unlock(ao objects, out ao unlocked, out o prompt)`
  * `Lock(ao objects, out ao locked, out o prompt)`
  * `GetSecrets(ao items, o session, out a{o(oayays)} secrets)` (spec: `Dict<ObjectPath,Secret>`; the `(oayays)` struct signature is `(UNVERIFIED)` in this spike)
  * `ReadAlias(s name, out o collection)` and `SetAlias(s name, o collection)`
* Collection methods: `Delete(out o prompt)`, `SearchItems(a{ss} attributes, out ao results)`, `CreateItem(a{sv} properties, (oayays) secret, b replace, out o item, out o prompt)`.
* Item methods: `GetSecret()` and `SetSecret()` (named in `[SS]` transfer-secrets page; the wire signatures were not read in this spike).
* Algorithms (`[SS]` section 7.1-7.3): negotiated in `OpenSession`.
  * `plain`: `input` is the empty string, `output` is empty, and secrets travel unencrypted on the bus.
  * `dh-ietf1024-sha256-aes128-cbc-pkcs7`: `input` = client DH public key as a byte array (unsigned big-endian, minimal length). `output` = service public key. Secret `parameters` = 16-byte AES IV.
* Constants in `[SSC]` `session.rs` (crate source, single-source for the numeric values but matched to the spec text):
  * DH generator `g = 2`.
  * DH prime = RFC 2409 Second Oakley Group (1024-bit MODP), spec section 7.3 names it `[SS]` "1024 bit parameters of the standard IETF 'Second Oakley Group'". The crate prime starts `FFFFFFFF FFFFFFFF C90FDAA2 2168C234`, which is the RFC 2409 group 2 prime.
  * Private key: 128 random bytes (`Keypair::generate`).
  * Shared secret: `s = server_pub^private mod p`, serialised as 128 bytes, zero-padded on the left.
  * AES key: HKDF-SHA-256 with salt = none, info = empty, output 16 bytes (`derive_shared` and `hkdf` in `session.rs`; the spec says the same thing in section 7.3).
  * Secret encryption: AES-128-CBC with PKCS#7 padding, IV = `parameters` (`[SS]` 7.3).
* Call sequence for store (plain or encrypted):
  1. Connect to the session bus.
  2. `OpenSession(algorithm, input)`. Keep the session path. Reuse it for the process lifetime.
  3. Get the default collection: `ReadAlias("default")`. If `/`, call `CreateCollection({"org.freedesktop.Secret.Collection.Label": "..."}, "default", ...)`, and handle the prompt if `prompt != "/"`.
  4. If the collection's `Locked` property is true, call `Unlock([collection], ...)`. If the returned `prompt` is not `/`, run the prompt (below).
  5. `CreateItem(properties, secret, replace=true, ...)`. The `properties` map carries `org.freedesktop.Secret.Item.Label` and `org.freedesktop.Secret.Item.Attributes` (crate constants `SS_ITEM_LABEL`, `SS_ITEM_ATTRIBUTES` in `ss.rs`). Attributes are `a{ss}` (service, account, etc.).
  6. If `prompt != "/"`, run the prompt and wait for the result.
* Call sequence for read: `SearchItems(attributes)` on the service, then `GetSecrets([item], session)` (or `Item.GetSecret(session)`). Decrypt with the session AES key.
* Prompt: `org.freedesktop.Secret.Prompt.Prompt(s window_id)` then wait for `Completed(b dismissed, v result)`. Subscribe to `Completed` before calling `Prompt` (the crate does this in `util.rs` lines 115-127, comment: "handle_signal"). `dismissed = true` means the user cancelled, which maps to an error (`util.rs` `handle_signal`).
* Stop: close the session with `org.freedesktop.Secret.Session.Close()` (method name from the Session interface, `(UNVERIFIED)` as printed in this spike).

**Route 2: KWallet (KDE fallback, when Secret Service is not present).**
* Services: `org.kde.kwalletd5` and `org.kde.kwalletd6` are both registered by `kwalletd` (`[KW]` `kwalletd.cpp` lines 33-34).
* Methods used by KWallet clients (from `kwalletd.h`, lines 96-119): `readPassword(int handle, string folder, string key, string appId)`, `writePassword(int handle, folder, key, value, appId) -> int`, `readMap`, `readMapList`, `readPasswordList`. A handle comes from `open` (not read here).
* `kwalletd` can delegate to `org.kde.ksecretd` at `/ksecretd` interface `org.kde.kwalletcompat` (`kwalletd.cpp` lines 487-500), i.e. KWallet may itself sit behind the Secret Service API. Treat Route 1 as always first.
* KWallet has its own unlock prompt flow (not researched).

**Route 3: libsecret (GNOME) is the C client of Route 1.** Not separately researched; `libsecret` source URL on gitlab.gnome.org returned 404 for the probed path.

**Permissions.** None beyond the user session. Unlock prompts are shown by the keyring daemon (gnome-keyring, KWallet, KeePassXC, etc.).

**Pitfalls.**
* `org.freedesktop.secrets` may be absent (no keyring daemon). Return `UNAVAILABLE` (crate maps `InterfaceNotFound` and `Address` errors to `Unavailable`, `util.rs` `handle_conn_error`).
* The crate's prompt wait is unbounded (`receive_completed_iter.next().unwrap()`, `util.rs` lines 124-143). The Bleu version needs a deadline (contract: `bleu::deadline`).
* The prompt returns a `zvariant::OwnedValue`; the caller must check `dismissed` first.

### 2.2 macOS

**Keychain C API.** `Security.framework`, header `SecItem.h` (not fetched).
* Functions (`security-framework-sys` 2.14.0 `src/keychain_item.rs` line 12 for `SecItemAdd`; `SecItemCopyMatching`, `SecItemUpdate`, `SecItemDelete` are declared in the same crate):
  * `OSStatus SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result)`
  * `OSStatus SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result)`
  * `OSStatus SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate)`
  * `OSStatus SecItemDelete(CFDictionaryRef query)`
* Keys (`security-framework-sys` `src/item.rs`): `kSecClassGenericPassword` (line 6), `kSecAttrService` (line 88), `kSecAttrAccount` (line 90), `kSecValueData` (line 91), `kSecUseDataProtectionKeychain` (line 42, `cfg(OSX_10_15)`).
* Data protection keychain selection requires `kSecUseDataProtectionKeychain = kCFBooleanTrue` in the dictionary (`security-framework` 3.0.1 `src/item.rs` lines 682-687, 886-891). The crate doc for `Location::DataProtectionKeychain` (item.rs ~line 938) says it requires the binary to be codesigned with `keychain-access-groups` entitlements.
* The legacy file keychain: `keyring` 3.6.2 `src/macos.rs` lines 240-263 uses `SecKeychain::default_for_domain` (legacy API).
* Error codes (`security-framework-sys` `src/base.rs`, two-source with keyring for -25300): `errSecParam = -50`, `errSecDuplicateItem = -25299`, `errSecItemNotFound = -25300`, `errSecAuthFailed = -25293`. keyring maps -25291, -25292, -25294, -25295 to `NoStorageAccess` (`macos.rs` lines 259-263).

**Call sequence (store).**
1. Build `CFDictionary`: `kSecClass = kSecClassGenericPassword`, `kSecAttrService`, `kSecAttrAccount`, `kSecValueData = CFData`, and `kSecUseDataProtectionKeychain = true` if the binary is entitled.
2. `SecItemAdd`. On `errSecDuplicateItem`, run `SecItemUpdate` with the match dictionary and `kSecValueData`.
3. Zero the CFData buffer after use.

**Call sequence (read).** `SecItemCopyMatching` with `kSecReturnData = true`, `kSecMatchLimit = kSecMatchLimitOne`. `errSecItemNotFound` is "no entry".

**Permissions and prompts.**
* The legacy keychain ACL can show a password prompt ("X wants to access the keychain") for unsigned or re-signed binaries. The exact behaviour is `(UNVERIFIED)` here: the Apple TN3137 page body was not retrievable. The keyring crate uses the legacy keychain, which is the reason for the prompt risk.
* The data protection keychain needs a signed app with entitlements (`[SSC]`-independent: security-framework doc above, single-source).
* `kSecUseDataProtectionKeychain` is gated at OS 10.15 in the binding (`cfg(feature = "OSX_10_15")`, item.rs line 42).

**Pitfalls.** Keychain items survive app deletion. The shell must delete explicitly. Do not use `kSecAttrSynchronizable` for Wi-Fi passwords (`(UNVERIFIED)`, memory).

### 2.3 Windows

**Credential Manager (`advapi32`).** Header `wincred.h`, library `Advapi32.lib`, DLL `Advapi32.dll` (`[MS-CredWriteW]` requirements).
* `BOOL CredWriteW(PCREDENTIALW Credential, DWORD Flags)`. Flag `CRED_PRESERVE_CREDENTIAL_BLOB = 0x00000001`: keep the existing blob (requires `CredentialBlobSize == 0`) (`[MS-CredWriteW]` Flags table; value `0x00000001` from Wine `wincred.h` line 252).
* `BOOL CredReadW(LPCWSTR TargetName, DWORD Type, DWORD Flags, PCREDENTIALW *Credential)`. Free the result with `CredFree`.
* `BOOL CredDeleteW(LPCWSTR TargetName, DWORD Type, DWORD Flags)` (`[MS-CredDeleteW]`).
* `CREDENTIALW` (`[MS-CREDENTIALW]`): `DWORD Flags`, `DWORD Type`, `LPWSTR TargetName`, `LPWSTR Comment`, `FILETIME LastWritten`, `DWORD CredentialBlobSize`, `LPBYTE CredentialBlob`, `DWORD Persist`, `DWORD AttributeCount`, `PCREDENTIAL_ATTRIBUTEW Attributes`, `LPWSTR TargetAlias`, `LPWSTR UserName`.
* Constants with values (Learn and Wine `wincred.h` agree):
  * `CRED_TYPE_GENERIC = 1` (Wine line 214; Learn "1 (0x1)").
  * `CRED_PERSIST_NONE = 0` (Wine), `CRED_PERSIST_SESSION = 1`, `CRED_PERSIST_LOCAL_MACHINE = 2`, `CRED_PERSIST_ENTERPRISE = 3` (Wine lines 223-226; Learn lines 137-147).
  * `CRED_MAX_CREDENTIAL_BLOB_SIZE = 5 * CRED_MAX_BLOB_SIZE` = 5 * 512 = 2560 bytes (Wine line 197; Learn "5*512").
  * `CRED_MAX_GENERIC_TARGET_NAME_LENGTH = 32767` (Wine line 191; Learn).
* keyring writes `CRED_PERSIST_ENTERPRISE` (`keyring/src/windows.rs` lines 242-243). This roams with domain profiles. For Wi-Fi and VPN credentials, `CRED_PERSIST_LOCAL_MACHINE` is the better default (recommendation, not verified against Windows behaviour).
* keyring sets `CredentialBlob` to UTF-16 when storing a password (`windows.rs` line 220 counts `encode_utf16 * 2`), so the blob is a UTF-16LE string for password-style writes. Use raw bytes for the Bleu API, and document the encoding.

**DPAPI (`crypt32`).**
* `BOOL CryptProtectData(DATA_BLOB *pDataIn, LPCWSTR szDataDescr, DATA_BLOB *pOptionalEntropy, PVOID pvReserved, CRYPTPROTECT_PROMPTSTRUCT *pPromptStruct, DWORD dwFlags, DATA_BLOB *pDataOut)` (`[MS-CryptProtectData]` page fetched; the full parameter list was partly read).
* Flags (Learn and Wine `wincrypt.h` line 2139-2141 agree): `CRYPTPROTECT_UI_FORBIDDEN = 0x0001`, `CRYPTPROTECT_LOCAL_MACHINE = 0x0004`, `CRYPTPROTECT_AUDIT = 0x0010`. Learn says `UI_FORBIDDEN` makes UI requests fail with `ERROR_PASSWORD_RESTRICTION`.
* Free `pDataOut.pbData` with `LocalFree` (Learn).
* Link with `Crypt32.lib` (Learn).
* Use: encrypt a token before storing it in the Bleu state directory, with `CRYPTPROTECT_UI_FORBIDDEN`. Keep it per-user (no `LOCAL_MACHINE` flag) unless the design requires machine scope.

**Permissions.** None for per-user credentials. `CRED_PERSIST_ENTERPRISE` may need domain setup (`(UNVERIFIED)`).

## 3. Reference implementations

| Project | Language | File (raw URL) | Read? | Idea |
| --- | --- | --- | --- | --- |
| secret-service 4.0.0 | Rust | `static.crates.io/crates/secret-service/secret-service-4.0.0.crate`: `src/session.rs`, `src/util.rs`, `src/ss.rs`, `src/collection.rs`, `src/item.rs` | read | DH constants, HKDF, prompt flow |
| oo7 0.3.0 | Rust | `static.crates.io/crates/oo7/oo7-0.3.0.crate` (33 .rs files) | downloaded, not read | alternative Secret Service client |
| keyring 3.6.2 | Rust | `static.crates.io/crates/keyring/keyring-3.6.2.crate`: `src/windows.rs`, `src/macos.rs`, `src/secret_service.rs` | `windows.rs` and `macos.rs` read; `secret_service.rs` not read | CredWriteW/ReadW/DeleteW use; legacy macOS keychain; error mapping |
| security-framework 3.0.1 | Rust | `static.crates.io/crates/security-framework/security-framework-3.0.1.crate`: `src/item.rs` | read (lines 679-690, 880-890, 934-948) | data protection keychain selection |
| security-framework-sys 2.14.0 | Rust | `static.crates.io/crates/security-framework-sys/...` `src/item.rs`, `src/base.rs`, `src/keychain_item.rs` | read | constant names and error codes |
| GNOME libsecret | C | not fetched (gitlab path 404) | no | reference Secret Service client |
| KWallet | C++ | `https://raw.githubusercontent.com/KDE/kwallet/master/src/runtime/kwalletd/kwalletd.{h,cpp}` | read | `kwalletd5`/`kwalletd6` names, method list, ksecretd delegation |
| Wine headers | C | `https://raw.githubusercontent.com/wine-mirror/wine/master/include/wincred.h`, `wincrypt.h` | read | numeric constants cross-check |

## 4. Double validation

| Claim | Source A | Source B | Status |
| --- | --- | --- | --- |
| Service name `org.freedesktop.secrets`; default alias `default` | `[SS]` (Service methods, alias text) | `[SSC]` `ss.rs` line 11, `blocking/mod.rs` line 100 | 2 sources |
| `OpenSession` algorithm strings `plain`, `dh-ietf1024-sha256-aes128-cbc-pkcs7` | `[SS]` 7.2, 7.3 | `[SSC]` `ss.rs` lines 18-19 | 2 sources |
| DH generator 2, prime = Second Oakley Group | `[SS]` 7.3 (Oakley group 2) | `[SSC]` `session.rs` lines 36-44 | 2 sources |
| AES key via HKDF-SHA256 with NULL salt and empty info, 16 bytes | `[SS]` 7.3 | `[SSC]` `session.rs` `hkdf` (`info = []`, salt None) | 2 sources |
| AES-128-CBC PKCS7, 16-byte IV in `parameters` | `[SS]` 7.3 | `[SSC]` `session.rs` `U16` generic array and `util.rs` `SecretStruct.parameters` | 2 sources |
| Public keys as unsigned big-endian minimal bytes | `[SS]` 7.3 | `[SSC]` `to_bytes_be()` | 2 sources |
| Prompt returns `Completed(dismissed, result)` | `[SS]` 9 (Prompt) | `[SSC]` `util.rs` `handle_signal` | 2 sources |
| Secret struct fields session, parameters, value, content_type | `[SSC]` `util.rs` lines 100-106 | none | (single-source) |
| Secret wire signature `(oayays)` | none in this spike | none | (UNVERIFIED) |
| `GetSecret` / `SetSecret` on Item; `GetSecrets` on Service | `[SS]` transfer-secrets text | `[SSC]` item.rs (uses get/set) | 2 sources |
| CRED_TYPE_GENERIC = 1 | `[MS-credentials]` Learn | Wine `wincred.h` | 2 sources |
| CRED_PERSIST_* values 1, 2, 3 | Learn | Wine `wincred.h` | 2 sources |
| CRED_MAX_CREDENTIAL_BLOB_SIZE = 2560 | Learn "5*512" | Wine `wincred.h` | 2 sources |
| CRED_PRESERVE_CREDENTIAL_BLOB = 1 | Learn | Wine `wincred.h` | 2 sources |
| CryptProtectData flags 0x1, 0x4, 0x10 | Learn (names) | Wine `wincrypt.h` | 2 sources (names in Learn, values in Wine) |
| `errSecItemNotFound = -25300` | `security-framework-sys` `base.rs` | keyring `macos.rs` line 263 | 2 sources |
| `errSecAuthFailed = -25293` | `security-framework-sys` `base.rs` | none | (single-source) |
| `kSecUseDataProtectionKeychain` gated at 10.15 | `security-framework-sys` cfg | none | (single-source) |
| Legacy-ACL prompt for unsigned binaries | none | none | (UNVERIFIED) |
| Data protection keychain requires entitlements | `security-framework` doc (item.rs ~938) | none | (single-source) |
| Apple TN3137 prose | not readable | not readable | (UNVERIFIED) |

## 5. Proposed Bleu model

```c3
// Secrets are NOT part of the published State (contract rule 1 forbids leaking them into snapshots).
// A separate operation surface; values are bytes, never String, and never in logs.

struct SecretKey {
    String service;          // e.g. "bleu.wifi"
    String account;          // e.g. SSID or VPN profile id
}

enum SecretsBackendKind : char { SECRET_SERVICE, KWALLET, MACOS_KEYCHAIN, MACOS_DATA_PROTECTION, WIN_CRED_MANAGER, WIN_DPAPI }

enum SecretPersist : char { SESSION, LOCAL_MACHINE, ENTERPRISE }  // Windows CRED_PERSIST_*; ignored on other OSes

struct SecretsOptions {
    SecretsBackendKind backend;   // force one, or ANY
    String collection;            // Secret Service alias, default "default"
    SecretPersist persist;        // default LOCAL_MACHINE on Windows
    Duration prompt_timeout;      // contract: bleu::deadline
}

enum SecretsCap : char { STORE, READ, DELETE, LIST_ACCOUNTS, PROMPT_UNLOCK, ENCRYPT_IN_TRANSIT }
// ENCRYPT_IN_TRANSIT = Secret Service DH session available (not "plain")

// Operations (contract rule 4): store, read, delete each return Operation{void} or Operation{SecretBytes}.
// SecretBytes is an arena-owned byte slice; zeroised on release.
```

Backend list per OS (priority order):
* Linux: `secret_service` (DH session preferred, plain as fallback only if DH is refused with NotSupported), `kwallet` (when the service is `org.kde.kwalletd5/6` and Secret Service is absent), no third.
* macOS: `data_protection` (only if the binary is entitled; availability checked at run time), `legacy_keychain` (default, with the prompt risk noted in `SecretsCap`).
* Windows: `cred_manager` (CRED_TYPE_GENERIC), `dpapi` (file-level encryption helper, not a credential store).

Unavailable fields: `PROMPT_UNLOCK` (Windows and macOS legacy keychain can show a system prompt; no "unlock" concept in Credential Manager), `ENCRYPT_IN_TRANSIT` (macOS and Windows; they have no session transfer concept).

## 6. Risks and cut lines

* Secret Service may be present but locked, and the prompt may never complete. Enforce the deadline.
* Storing secrets in Bleu's own state files is forbidden by the contract's rule 1 (and by DPAPI usage here). Use the OS store only.
* macOS legacy keychain may prompt the user repeatedly if the binary's signature changes between builds (`(UNVERIFIED)`).
* Windows CRED_PERSIST_ENTERPRISE roams; choose LOCAL_MACHINE for device-bound secrets (recommendation).
* Cut line for v1: Secret Service with DH plus a Windows CredWriteW/CredReadW/CredDeleteW backend. Defer KWallet, macOS data protection (needs signing), DPAPI, and prompt UI (fail fast with `AUTH_REQUIRED` instead).

---

# appearance

## 1. What a shell needs

1. Colour scheme light, dark, or no preference, plus change events.
2. Accent colour (RGB), contrast preference (normal or high).
3. Reduced motion, reduced transparency.
4. Font name and text scaling factor.
5. Wallpaper path get and set, including per-monitor on Windows and where the desktop supports it.
6. Icon theme, GTK theme, cursor theme names (Linux).
7. Locale, 12 or 24-hour time format, time zone.

## 2. Per-platform native route

### 2.1 Linux

**Route 1 (preferred for colour scheme, accent, contrast): `org.freedesktop.portal.Settings`.**
* Bus name `org.freedesktop.portal.desktop`, object `/org/freedesktop/portal/desktop`, interface `org.freedesktop.portal.Settings`, version 2 (`[PORTAL]` XML, "This documentation describes version 2").
* Methods:
  * `ReadAll(as namespaces) -> a{sa{sv}} value`
  * `Read(s namespace, s key) -> v value` (deprecated in v2 per the XML)
  * `ReadOne(s namespace, s key) -> v value` (added in v2; reads any D-Bus type)
* Signal: `SettingChanged(s namespace, s key, v value)`.
* Property: `version` (u).
* Namespace `org.freedesktop.appearance` keys (`[PORTAL]` documentation text, and `[PORTAL]` impl XML for the same values):
  * `color-scheme` (u): 0 no preference, 1 prefer dark, 2 prefer light. Unknown values = 0.
  * `accent-color` (`(ddd)`): sRGB RGB in [0, 1]. Out-of-range = unset.
  * `contrast` (u): 0 normal, 1 higher contrast.
  * `reduced-motion` (u): 0 no preference, 1 reduced.
* Implementation detail: `Read` returns a variant wrapping a variant on some implementations. ashpd handles this with a `downcast_ref::<Value>` branch (`ashpd` `desktop/settings.rs` lines 224-233). Use the same double-unwrap rule.
* ashpd maps `contrast` value 1 to `High` and everything else to `NoPreference` (`settings.rs` lines 150-157).

Call sequence:
1. Connect to session bus. Create proxy for `org.freedesktop.portal.Settings`.
2. `ReadAll(["org.freedesktop.appearance"])` for the initial state.
3. Subscribe to `SettingChanged` with a match rule on namespace and key (`ashpd` `receive_setting_changed_with_args`, `settings.rs` lines 319-331).
4. On signal, update the matching field only.
5. Stop: drop the match rule.

Portal absence: the Settings portal "can operate without this backend" (`[PORTAL]` text). If the portal is not running, the call fails; dark-light uses a 25 ms timeout (`freedesktop.rs` line 15), which is too short for a cold start. Use a longer timeout in Bleu and a retry after startup.

**Route 2: GSettings or dconf (GNOME and derivatives; not via portal).**
* Schema `org.gnome.desktop.interface` (`gsettings-desktop-schemas`, file `schemas/org.gnome.desktop.interface.gschema.xml.in`, fetched and parsed):
  * `color-scheme` (enum `org.gnome.desktop.GDesktopColorScheme`): `'default'` (default), `'prefer-dark'`, `'prefer-light'`.
  * `accent-color` (enum `org.gnome.desktop.GDesktopAccentColor`): default `'blue'`; values `blue, teal, green, yellow, orange, red, pink, purple, slate`.
  * `gtk-theme` (s, default `'Adwaita'`), `icon-theme` (s, default `'Adwaita'`), `cursor-theme` (s, default `'Adwaita'`).
  * `font-name` (s, default `'Adwaita Sans 11'`), `document-font-name`, `monospace-font-name`.
  * `text-scaling-factor` (d, range 0.5 to 3.0, default 1.0).
  * `clock-format` (enum): `'12h'` or `'24h'`, default `'24h'`.
  * `enable-animations` (b, default true).
* Schema `org.gnome.desktop.background`: `picture-uri` (s) and `picture-uri-dark` (s) (fetched file `org.gnome.desktop.background.gschema.xml.in`).
* D-Bus access: `ca.desrt.dconf` (dconf service) and the file db format are the storage. GSettings client API is the simple route. Cut line: treat dconf's D-Bus write path as out of scope; read through GSettings or `gio` only.
* Change events: `GSettings::changed` signal, or watch the `SettingChanged` portal signal.

**Route 3: KDE (not fully researched).**
* `wallpaper` crate uses `qdbus org.kde.PlasmaShell.evaluateScript` with a Plasma JS snippet, and reads `~/.config/plasma-org.kde.plasma.desktop-appletsrc` (`wallpaper-3.2.0/src/linux/kde.rs` lines 11, 60-64). This is a script injection, not a stable API; mark `(single-source)`.
* `kdeglobals` (`~/.config/kdeglobals`) for colours, fonts and icon theme: `(UNVERIFIED)` key names in this spike.
* The task brief's `org.kde.KGlobalSettings` was not verified; the KDE source file path returned 404.

**Wallpaper.**
* Portal (preferred, sandbox-safe): `org.freedesktop.portal.Wallpaper`, method `SetWallpaperURI(s parent_window, s uri, a{sv} options) -> o handle` and `SetWallpaperFile(s parent_window, h fd, a{sv} options) -> o handle` (`[PWP]` XML). Options: `show-preview` (b), `set-on` (s: `Lockscreen` or `Background`), per `[PWP]` documentation and ashpd `SetOn` (`wallpaper.rs` lines 56-101).
  * No per-monitor parameter in the portal (`(UNVERIFIED)` from the XML: only parent, uri/fd, options).
* Desktop-specific (`wallpaper` crate `linux/mod.rs` and per-desktop files):
  * GNOME: `gsettings set org.gnome.desktop.background picture-uri 'file://...'` (and `picture-uri-dark`).
  * XFCE: `xfconf-query --channel xfce4-desktop ...` (`xfce.rs` lines 16, 33-61).
  * Cinnamon: `dconf write /org/cinnamon/desktop/background/picture-uri`.
  * MATE: `dconf` `/org/mate/desktop/background/picture-filename`.
  * Deepin: `dconf` `/com/deepin/wrap/gnome/desktop/background/picture-uri`.
  * KDE: Plasma script (above).
  * Fallback: spawn `swaybg -i <path>` (`linux/mod.rs` line 80). This is not persistent and does not survive a restart.
* Wayland compositor-specific wallpaper daemons (`swww`, `hyprpaper`, `wpaperd`) use their own IPC sockets. Not standard, not researched (`(UNVERIFIED)`). Consider making them a separate backend, behind the same `Cap`.

**Time zone and locale (systemd).**
* `org.freedesktop.timedate1` at `/org/freedesktop/timedate1` (path and names from `[SD-timedated]` `timedated.c`, fetched):
  * Properties: `Timezone` (s), `LocalRTC` (b), `CanNTP` (b), `NTP` (b), `NTPSynchronized` (b), `TimeUSec` (t).
  * Methods: `SetTimezone`, `SetLocalRTC`, `SetNTP` (`timedated.c` lines 1102-1112; argument types not parsed).
* `org.freedesktop.locale1` (`localed.c`, fetched): property `Locale` of type `as`, entries like `LANG=en_US.UTF-8` (line 559). The interface path `/org/freedesktop/locale1` is `(UNVERIFIED)` (not grepped).
* Time format 12 or 24: no systemd property. Use GNOME `clock-format` on GNOME, or the locale's `LC_TIME` convention. `(UNVERIFIED)` for a generic rule.
* Time zone on non-systemd Linux: `/etc/localtime` symlink (memory, `(UNVERIFIED)`).

**Pitfalls.**
* `Read` double variant (above).
* Portal `SettingChanged` for `accent-color` may come as `(ddd)` but a different value type on some implementations. Parse defensively.
* Desktop detection: `XDG_CURRENT_DESKTOP` is colon-separated (`wallpaper` crate reads one value; the spec is not fetched).

### 2.2 macOS

* Colour scheme: `NSUserDefaults` global domain, key `AppleInterfaceStyle`. Value `Dark` means dark; the key being absent means light. Read via `[NSUserDefaults standardUserDefaults] persistentDomainForName:@"Apple Global Domain"` then `objectForKey:@"AppleInterfaceStyle"` (`dark-light` `macos.rs` lines 10-22; single-source for the key name in Rust code, consistent with the task brief).
* Change notification: `AppleInterfaceThemeChangedNotification` via `NSDistributedNotificationCenter` (task brief, `(UNVERIFIED)` in this spike).
* Accent colour: `AppleAccentColor` (integer; `-1` graphite, `0` red, `1` orange, `2` yellow, `3` green, `4` blue, `5` purple, `6` pink) and `AppleHighlightColor` (string). `(UNVERIFIED)`, from memory.
* Reduced motion, reduced transparency, increased contrast, differentiate without colour: `NSWorkspace` instance methods (objc2-app-kit 0.3.1 `src/generated/NSAccessibility.rs` lines 146-158, names verified in the binding):
  * `accessibilityDisplayShouldReduceMotion`
  * `accessibilityDisplayShouldReduceTransparency`
  * `accessibilityDisplayShouldIncreaseContrast`
  * `accessibilityDisplayShouldDifferentiateWithoutColor`
  * `accessibilityDisplayShouldInvertColors`
* Change notification for these: `NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification` (`(UNVERIFIED)` name from memory).
* Wallpaper set: `[NSWorkspace setDesktopImageURL:forScreen:options:error:]` (objc2-app-kit `src/generated/NSWorkspace.rs` lines 497-500, name verified in binding). Get: `desktopImageURLForScreen:` (line 507).
* Per-screen: `[NSScreen screens]`, one call per screen.
* Locale and time zone: `NSLocale.currentLocale`, `NSTimeZone.systemTimeZone`, change notifications `NSCurrentLocaleDidChangeNotification` and `NSSystemTimeZoneDidChangeNotification` (names from memory, `(UNVERIFIED)`).
* 12 or 24 hour: `AppleICUForce24HourTime` global key (`(UNVERIFIED)`) overrides the locale.
* Font: `NSFont.systemFontSize` and `NSFont.systemFont`. Scale is user-configured in accessibility text sizes, not exposed as a single factor (`(UNVERIFIED)`).
* Permissions: none for these reads. Setting wallpaper needs no TCC prompt (`(UNVERIFIED)`).

### 2.3 Windows

* Colour scheme: `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`, value `AppsUseLightTheme` (REG_DWORD, 0 = dark, 1 = light). `dark-light` reads it as `u32` and returns dark when `0` (`windows.rs` lines 8-13). `SystemUsesLightTheme` (taskbar and system UI) and `ColorPrevalence` (accent on title bars) are named in the task brief, `(UNVERIFIED)` in this spike.
* Accent: `HKCU\Software\Microsoft\Windows\DWM` `AccentColor` / `ColorizationColor` (task brief, `(UNVERIFIED)`).
* UWP settings: `Windows.UI.ViewManagement.UISettings` (`[MS-UISettings]` fetched):
  * `GetColorValue(UIColorType)` with `UIColorType.Accent` and the other accent variants.
  * `ColorValuesChanged` event.
  * `TextScaleFactor` property (fetched page lists it).
  * `AnimationsEnabled` property and `AnimationsEnabledChanged` event.
  * `(UNVERIFIED)` for the exact enum member names other than `Accent`.
* Accessibility high contrast: `Windows.UI.ViewManagement.AccessibilitySettings` (task brief, `(UNVERIFIED)` member names).
* Wallpaper:
  * Single screen: `SystemParametersInfoW(SPI_GETDESKWALLPAPER, cch, pvParam, 0)` returns the path into a buffer of `MAX_PATH` characters. Empty string = no wallpaper. (`[MS-SystemParametersInfoW]` fetched.)
  * Set: `SystemParametersInfoW(SPI_SETDESKWALLPAPER, 0, path, SPIF_UPDATEINIFILE | SPIF_SENDCHANGE)` (flags from memory, `(UNVERIFIED)` as to the exact combination; the function returns TRUE unless the file is missing).
  * Multi-monitor: `IDesktopWallpaper` COM (`[MS-IDesktopWallpaper]` fetched). Methods named in the page: `GetMonitorDevicePathCount`, `GetMonitorDevicePathAt`, `GetMonitorRECT`, `GetWallpaper`, `GetPosition`, `GetBackgroundColor`, `SetWallpaper`, `SetPosition`, `Enable`, `AdvanceSlideshow`. CLSID for `DesktopWallpaper` `(UNVERIFIED)` in this spike.
* Locale: `GetUserDefaultLocaleName` (task brief, name only; not fetched).
* Time zone: `GetDynamicTimeZoneInformation(DYNAMIC_TIME_ZONE_INFORMATION*)` (`[MS-GetDynamicTimeZoneInformation]` fetched; the function exists and returns the current dynamic zone). The struct fields `TimeZoneKeyName` and `DynamicDaylightTimeDisabled` `(UNVERIFIED)` as to exact names.
* 12/24 hour: `HKCU\Control Panel\International` `sShortTime` / `iTime` (memory, `(UNVERIFIED)`).
* Change notifications: `WM_SETTINGCHANGE` broadcast to top-level windows (`[MS-WM_SETTINGCHANGE]` fetched). `lParam` is a pointer to a string naming the changed area. Check it and reload the setting. The `ImmersiveColorSet` string is the one used for theme changes (memory, `(UNVERIFIED)`).
* Threading: `UISettings` needs a WinRT apartment, `IDesktopWallpaper` needs COM init. Keep both on the worker thread (contract). `(UNVERIFIED)` for exact apartment requirements.

## 3. Reference implementations

| Project | Language | File (raw URL) | Read? | Idea |
| --- | --- | --- | --- | --- |
| ashpd 0.10.2 | Rust | `static.crates.io/crates/ashpd/ashpd-0.10.2.crate`: `src/desktop/settings.rs`, `src/desktop/wallpaper.rs` | read | portal Settings reads, double-variant unwrap, Wallpaper options, SetOn |
| dark-light 2.0.0 | Rust | `static.crates.io/crates/dark-light/dark-light-2.0.0.crate`: `src/platforms/{freedesktop,macos,windows}.rs` | read | portal-first colour scheme, macOS key, Windows DWORD |
| wallpaper 3.2.0 | Rust | `static.crates.io/crates/wallpaper/wallpaper-3.2.0.crate`: `src/linux/{mod,gnome,kde,xfce,lxde}.rs` | read | per-desktop wallpaper backends |
| objc2-app-kit 0.3.1 | Rust | `static.crates.io/crates/objc2-app-kit/objc2-app-kit-0.3.1.crate`: `src/generated/NSWorkspace.rs`, `NSAccessibility.rs` | read | NSWorkspace selectors (names verified) |
| DankMaterialShell | Go | `https://raw.githubusercontent.com/AvengeMedia/DankMaterialShell/master/core/internal/server/thememode/manager.go` and `wallpaper/manager.go` | read (scheduler logic only) | theme and wallpaper schedule, not OS calls |
| GNOME gsettings-desktop-schemas | schema XML | `https://raw.githubusercontent.com/GNOME/gsettings-desktop-schemas/master/schemas/org.gnome.desktop.interface.gschema.xml.in` | read | key names, defaults, enum values |
| xdg-desktop-portal | XML | `https://raw.githubusercontent.com/flatpak/xdg-desktop-portal/main/data/org.freedesktop.portal.Settings.xml` and `org.freedesktop.impl.portal.Settings.xml`, `org.freedesktop.portal.Wallpaper.xml` | read | interface definitions |
| systemd timedated / localed | C | `https://raw.githubusercontent.com/systemd/systemd/main/src/timedate/timedated.c`, `src/locale/localed.c` | grep only | D-Bus property names and types |
| KDE plasma-workspace | C++ | `https://raw.githubusercontent.com/KDE/plasma-workspace/master/kcms/colors/colorsmodel.cpp` | fetched, not read | KDE colour model (not read) |

## 4. Double validation

| Claim | Source A | Source B | Status |
| --- | --- | --- | --- |
| Portal color-scheme values 0, 1, 2 | `[PORTAL]` frontend XML doc | `[PORTAL]` impl XML doc; ashpd `ColorScheme` mapping | 2 sources |
| accent-color `(ddd)` in [0, 1] | `[PORTAL]` frontend XML | ashpd `Color` conversion (`settings.rs` line 239) | 2 sources |
| contrast 1 = high | `[PORTAL]` frontend XML | ashpd `Contrast::try_from` (`settings.rs` lines 150-157) | 2 sources |
| reduced-motion key | `[PORTAL]` impl XML | none (ashpd does not expose it) | (single-source) |
| Read returns variant in variant | ashpd `settings.rs` lines 224-233 | none | (single-source) |
| `ReadOne` added in v2 | `[PORTAL]` frontend XML | none | (single-source) |
| `SettingChanged(s, s, v)` | `[PORTAL]` XML | ashpd `receive_setting_changed` | 2 sources |
| SetWallpaperURI signature | `[PWP]` XML | ashpd `wallpaper.rs` lines 142-150 | 2 sources |
| show-preview and set-on options | `[PWP]` docs | ashpd `wallpaper.rs` lines 112-114 | 2 sources |
| GNOME color-scheme values and default | gsettings schema | none | (single-source, schema is authoritative) |
| GNOME accent values | gsettings schema | none | (single-source) |
| text-scaling-factor range 0.5 to 3.0 | gsettings schema | none | (single-source) |
| GNOME picture-uri keys | gsettings background schema | `wallpaper` crate `gnome.rs` lines 10-20 | 2 sources |
| XFCE xfconf channel `xfce4-desktop` | `wallpaper` crate `xfce.rs` | none | (single-source) |
| KDE plasma script wallpaper | `wallpaper` crate `kde.rs` | none | (single-source) |
| timedate1 properties (Timezone s, NTP b, ...) | `timedated.c` lines 1089-1094 | none | (single-source) |
| locale1 Locale `as` | `localed.c` line 559 | none | (single-source) |
| locale1 object path | none | none | (UNVERIFIED) |
| AppleInterfaceStyle, absence = light | `dark-light` `macos.rs` | none | (single-source) |
| NSWorkspace accessibility selectors | objc2-app-kit bindings | none | (single-source, names only) |
| NSWorkspace setDesktopImageURL | objc2-app-kit bindings | none | (single-source) |
| AppleAccentColor values, AppleICUForce24HourTime | none | none | (UNVERIFIED) |
| AppleInterfaceThemeChangedNotification | none | none | (UNVERIFIED) |
| AppsUseLightTheme DWORD, 0 = dark | `dark-light` `windows.rs` | Learn not fetched | (single-source) |
| UISettings members | `[MS-UISettings]` page | none | (single-source) |
| SPI_GETDESKWALLPAPER returns path, MAX_PATH buffer | `[MS-SystemParametersInfoW]` page | none | (single-source) |
| IDesktopWallpaper methods | `[MS-IDesktopWallpaper]` page | none | (single-source, names) |
| WM_SETTINGCHANGE lParam is area string | `[MS-WM_SETTINGCHANGE]` | none | (single-source) |
| ImmersiveColorSet string | none | none | (UNVERIFIED) |
| GetDynamicTimeZoneInformation exists | `[MS-GetDynamicTimeZoneInformation]` | none | (single-source) |

## 5. Proposed Bleu model

```c3
// Appearance state is plain data (contract rule 1). Colours are a typedef'd tuple, never an int with a meaning hidden in it.
typedef Unit = float;   // 0.0 .. 1.0, sRGB

enum ColorScheme : char { NO_PREFERENCE, DARK, LIGHT }        // portal values 0, 1, 2 map to NO_PREFERENCE, DARK, LIGHT
enum Contrast : char { NORMAL, HIGH }
enum Motion : char { NO_PREFERENCE, REDUCED }
enum ClockFormat : char { H12, H24, UNKNOWN }

struct Rgb { Unit r; Unit g; Unit b; }

struct DisplayWallpaper { String screen_id; String path; }   // screen_id = Windows device path, macOS NSScreen id, or "" on Linux

struct AppearanceState {
    ColorScheme color_scheme;
    Rgb accent;                 // valid only when accent_known
    bool accent_known;
    Contrast contrast;
    Motion motion;
    bool reduced_transparency;
    String font_name;
    float text_scale;           // 1.0 default; 0.0 when unknown (Availability carries reason)
    String icon_theme;
    String gtk_theme;
    String cursor_theme;
    String[] wallpapers_global; // one entry per desktop when no per-monitor support
    DisplayWallpaper[] wallpapers;
    ClockFormat clock;
    String locale;              // BCP-47 or POSIX name
    String time_zone;           // IANA name (Linux: from timedate1; macOS and Windows map to IANA)
}

enum AppearanceCap : char {
    COLOR_SCHEME, ACCENT, CONTRAST, REDUCED_MOTION, REDUCED_TRANSPARENCY,
    FONT, TEXT_SCALE, ICON_THEME, GTK_THEME, CURSOR_THEME,
    WALLPAPER_GET, WALLPAPER_SET, WALLPAPER_PER_SCREEN,
    CLOCK_FORMAT, LOCALE, TIME_ZONE, SET_TIME_ZONE
}
```

Backend list per OS:
* Linux: `portal_settings` (color scheme, accent, contrast, reduced motion), `gsettings` (fonts, themes, text scale, clock, GNOME accent), `kde_config` (kdeglobals, UNVERIFIED keys), `timedate1` / `locale1` (system zone and locale), wallpaper: `portal_wallpaper` (set only), `desktop_specific` (GNOME, XFCE, Cinnamon, MATE, KDE script, swaybg fallback).
* macOS: `nsuserdefaults` (AppleInterfaceStyle, accent, ICU 24h), `nsworkspace` (accessibility flags, wallpaper get/set), `nslocale_zone` (locale and time zone).
* Windows: `registry_personalize` (AppsUseLightTheme, ColorPrevalence), `uisettings` (accent, text scale, animations), `win_system` (SPI wallpaper, IDesktopWallpaper per monitor, GetDynamicTimeZoneInformation, locale).

Unavailable on a platform: `WALLPAPER_PER_SCREEN` on Linux (except via compositor-specific backends), `SET_TIME_ZONE` on macOS and Windows without admin (`(UNVERIFIED)`), `TEXT_SCALE` on macOS (no single factor).

## 6. Risks and cut lines

* Portal not running, or the backend does not implement Settings: the portal API still exists, so the frontend answers with an error. Fall back to GSettings or the desktop-specific route only after a timeout (not 25 ms).
* Wallpaper on Linux is not standardised. Every desktop backend is a separate maintenance cost. Cut line for v1: portal wallpaper plus GNOME gsettings only; treat others as "unsupported", not "fail".
* KDE internals are unverified. Cut line for v1: portal colour scheme and accent only on KDE.
* macOS private keys (`AppleAccentColor`, ICU 24h) are undocumented. Keep them behind a `_private.c3` file or drop from v1.
* Windows `ColorPrevalence` and `SystemUsesLightTheme` are not verified here; include only after reading the Learn page.
* Set time zone needs elevated rights on Windows and polkit on Linux (`org.freedesktop.timedate1.set-timezone` action, `(UNVERIFIED)` name). Cut line: read-only time zone in v1.

---

## Doubts and open items (summary for the lead)

1. `libs/bleu_xdg.c3l` and `libs/bleu_plist.c3l` do not exist in this checkout; the apps section assumes they will.
2. Apple developer pages are JavaScript-rendered; TN3137 and NSWorkspace prose were not readable. Keychain ACL prompt behaviour and Apple accent keys are UNVERIFIED.
3. Recent-file spec, Flatpak export paths, and freedesktop-icons source were not retrieved (404 or not downloaded).
4. Windows `.lnk`, AppsFolder and ReadDirectoryChangesW were checked for names only, not for parameter layouts.
5. GPU on all OSes and macOS SMC temperatures are not researched beyond pointers.
6. DankMaterialShell's OS-level code is not in the three files read; `dgop` (external Go module) is the likely source for sysmon and was not read.
