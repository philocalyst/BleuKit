# bleu_tray

The system tray, as plain data: on Linux the tray items of other applications (the
StatusNotifier host), and on all three systems our own tray icon with its menu.
Module root `bleu::tray`. Depends on `bleu_core`, `bleu_rt`, `bleu_service`, `bleu_dbus`,
`bleu_objc` (macOS) and `bleu_win` (Windows). Spec: `docs/research/media_notify_tray.md` part (C);
what was built and verified: `docs/research/tray_impl.md`.

## Public API

    Tray* tray = tray::open(mem, { .publish_own = true, .own = { .title, .icon, .menu } })!!;
    tray.latest() / tray.wait_after(seen, timeout)   // Snapshot{State}: items, watcher, own icon
    tray.watch(listener, ctx) / tray.unwatch(id)     // every state, on the worker thread
    tray.subscribe()                                 // Reader{Event}: ITEM_ADDED ... OWN_MENU_CLICKED
    tray.activate(id, x, y) / secondary_activate / context_menu / scroll(id, delta, horizontal)
    tray.open_submenu(id, menu_id)                   // AboutToShow + GetLayout; value: menu changed
    tray.click_menu(id, menu_id)                     // DBusMenu Event "clicked"
    tray.refresh() / tray.capability(Cap) / tray.backend_name() / tray.close()

Every command returns `Operation{bool}*`; `wait` it for the outcome, then `release` it.
`Item.id` (bus name + object path) is stable while the item is registered. `Item.menu` is a flat
tree: entry 0 is the root, and the children of entry `i` are `menu[first_child .. first_child + child_count]`.

## Coverage

Status per capability: **Run** = executed against fakes on Linux (the live test,
`tests/run.sh`, and the unit tests); **Unit** = pure logic run by `@test`; **Compiled** =
type-checked for the target only (`tools/check.sh`), never executed; **Not done**; **UNSUPPORTED**
= reported by `capability()` and refused.

| Capability | Linux `sni` | Windows `win32` | macOS `appkit` |
| --- | --- | --- | --- |
| `HOST`: list other applications' items | Run (served and remote watcher) | UNSUPPORTED (no API) | UNSUPPORTED (Accessibility, not used) |
| Item properties: Id, Title, Status, Category, IconName, IconPixmap, Attention and Overlay icons, ToolTip, ItemIsMenu, Menu | Run | - | - |
| Re-read on NewTitle, NewStatus, NewIcon, NewAttentionIcon, NewOverlayIcon, NewToolTip | Run (all but NewMenu) | - | - |
| NewMenu (KDE) | Not done (the signal is ignored) | - | - |
| Registration forms: "bus/path" (Electron), bare bus name | Run | - | - |
| Registration form "/path" (sender is the bus) | Unit (parse only) | - | - |
| Watcher served by us (name free) / followed (name taken) | Run / Run | - | - |
| Watcher lost: take it again, re-register everything | Compiled (not run) | - | - |
| Item vanishes (bus name owner gone) | Run | - | - |
| Activate, SecondaryActivate, ContextMenu, Scroll | Run | UNSUPPORTED | UNSUPPORTED |
| Menu: GetLayout, lazy submenu (AboutToShow), separators, disabled, toggle, shortcut, mnemonics | Run | UNSUPPORTED | UNSUPPORTED |
| Menu: icon-name | Compiled (not run) | - | - |
| Menu: icon-data (PNG) | Not done (not decoded) | - | - |
| Menu click (Event "clicked") | Run | UNSUPPORTED | UNSUPPORTED |
| LayoutUpdated | Run | - | - |
| ItemsPropertiesUpdated | Compiled (same path as LayoutUpdated, not run) | - | - |
| Pixmaps: ARGB32 network order to RGBA, size checks | Run and Unit | - | - |
| Publish own icon | Run (served and remote watcher) | Compiled | Compiled |
| Own menu and its click events | Run | Compiled | Compiled |
| Own icon events: activate (x, y), secondary activate | Run (Activate driven by a host; SecondaryActivate handled, not driven) | Compiled (activate; secondary not sent) | not sent: the status item opens its menu on click |
| Explorer restart: re-add our icon (TaskbarCreated) | - | Compiled | - |
| XEmbed system tray (X11) | Not done (cut) | - | - |

## Not done

- Other applications' icons on Windows and macOS: no public API; refused as UNSUPPORTED.
- XEmbed (X11 `_NET_SYSTEM_TRAY`): cut by the v1 spec.
- Menu icon-data (PNG) is not decoded; menu icons come from the icon name only.
- Shortcuts: the first chord only, joined with "+".
- `ProvideXdgActivationToken`, KDE `NewMenu`, `EventGroup` and `AboutToShowGroup`: not used.
- Hosts that vanish are not removed from `host_registered` when this process serves the watcher.
- Watcher takeover from a running watcher (Waybar-style replacement): not done; we take the name only when it is free.
- Own icon and menu are fixed at `open`; changing them needs a new service.
- Bus calls are synchronous on the worker with a 1 s timeout; a hung application costs the worker up to two calls per item.
- macOS: `open` and `close` must run on the main thread (AppKit); menu clicks are delivered through the mailbox, and a click racing `close` is dropped.
- Windows: the own icon's callbacks and TaskbarCreated arrive as `CUSTOM_MESSAGE` events of a `bleu::win::message_loop.Loop` on the worker.

## Tests

    libs/bleu_tray.c3l/tests/run.sh [served|remote]   # live, Linux: private dbus-daemon, Python dbus-next peers
    c3c --libdir "$(tools/libdir.sh)" --lib bleu_core --lib bleu_rt --lib bleu_service --lib bleu_dbus \
        --lib bleu_objc --lib bleu_win --lib bleu_tray compile-test src/convert_test.c3 --sources src/convert.c3

`served` runs the probe as the watcher; `remote` runs `fake_watcher.py` first, so the probe follows it.
The live test needs `dbus-daemon`, `c3c` and Python with `dbus-next` (`BLEU_TRAY_PYTHON` names one).
