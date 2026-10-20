# bleu_tray: implementation notes

Spec: `media_notify_tray.md` part (C), the v1 cut in its section 6. Library: `libs/bleu_tray.c3l`.
This file records what was built, what was verified and how, and where the build departs from
the research or the brief. Nothing here repeats the research.

## Built (v1 cut)

- Linux `sni` (run): StatusNotifierWatcher served when its name is free, followed when it is
  taken; host registration as `org.kde.StatusNotifierHost-<pid>-<n>`; items from the registry and
  from the watcher's Registered/Unregistered signals; item properties (KDE interface, freedesktop
  fallback); item signals re-read only the property they name; `org.freedesktop.DBus` NameOwnerChanged
  per item bus name; DBusMenu client with lazy submenus; Activate, SecondaryActivate, ContextMenu,
  Scroll; our own StatusNotifierItem and DBusMenu exported on the same connection.
- Windows `win32` (compiled only): Shell_NotifyIconW version 4, NIM_ADD then NIM_SETVERSION,
  TaskbarCreated re-add, NIN_SELECT as an own activation, WM_CONTEXTMENU shows our menu with
  TrackPopupMenu and returns the chosen entry as an event.
- macOS `appkit` (compiled only): NSStatusItem with an icon file (or the title), a tooltip, and a
  menu whose target class posts clicks to the worker's mailbox.

## Verified

- Live (Linux, `tests/run.sh served` and `remote`, 41 and 44 checks, all pass): a private
  `dbus-daemon`, a Python dbus-next StatusNotifierItem with a dbusmenu (submenu, separator,
  disabled entry, mnemonic `_Open`, double underscore `__one`, checkmark, shortcut), a Python
  watcher for the remote mode, and a Python dbus-next host that reads and acts on our own icon.
  Covered: `bus/path` registration, bus-only registration (normalised by the Python watcher),
  ARGB32 to RGBA on a 3 by 2 icon (first pixel 17,34,51,128 as expected), NewTitle, NewIcon,
  NewStatus, NewAttentionIcon, NewOverlayIcon, NewToolTip, LayoutUpdated, lazy submenu
  (AboutToShow then GetLayout), Event clicked round trip, Activate, SecondaryActivate,
  ContextMenu, Scroll, item vanishing when its bus name goes away, our own icon seen and
  driven by a dbus-next host, our menu clicked by that host.
- Unit (`src/convert_test.c3`, 7 tests, 58 in the run): pixmap conversion including the
  non-square case (3 by 1), height taken from the height field, size mismatch refused, mnemonics
  (`_` marks, `__` is a literal underscore), registration forms, enum text, Win32 labels.
- Compile: `tools/check.sh bleu_core bleu_rt bleu_service bleu_dbus bleu_objc bleu_win bleu_tray`
  is clean on all six targets. `c3fmt --check` is clean.

## Deviations from the research and the brief

1. **Watcher name only, no freedesktop alias.** The brief asked for the legacy
   `org.freedesktop.StatusNotifierWatcher` where the research says clients use it. The research
   (section 4) records that no reference client serves or reads it, and that the claim is
   UNVERIFIED. We serve and read `org.kde.StatusNotifierWatcher` only.
2. **Host name.** The brief's `org.kde.StatusNotifierHost-<pid>-<n>` is used; the research allows either prefix.
3. **Own-icon events carry no item id.** Activation and menu-click events for our own icon have
   `item_id = ""` on every platform (the model documents this).
4. **Watcher takeover is only "name free".** The research's Waybar takeover (replace another
   watcher) is not done. Re-registration after a lost name is implemented (`WATCHER_LOST`) but
   not exercised live.
5. **Blocking bus calls.** The research reports system-tray uses 1 s timeouts; we do the same
   with synchronous calls on the worker. Reading an item tries the two interface names and then
   stops, so an unresponsive item costs at most two calls per read.
6. **Pixmaps.** `Pixmap.pixels` is `char[]` (C3 has no `ubyte`). The research's `ubyte[]` is not used.
7. **Windows message routing.** The brief asked for the callback through `bleu::win::message_loop`.
   That module dispatches only its own messages (WAKE, power, display, device, session, setting,
   DPI) and has no route for a custom callback message, so `windows_tray.c3` creates its own hidden
   window with the same styles. `bleu_win` is unchanged. Lead: a generic "custom message" event
   in `message_loop` would remove the duplication.
8. **macOS threading.** AppKit objects are created in `create` and removed in `destroy`, which
   run on the caller's thread (the main thread, by contract). Clicks cross from the main thread
   through the worker's mailbox (`OWN_MENU_CLICK`), the only command kind a foreign thread posts.
9. **macOS left click.** An NSStatusItem with a menu opens the menu on click, so no
   `OWN_ACTIVATED` event is sent on macOS (documented in the coverage table).
10. **Item field names.** The brief's `app_id` is `Item.item_id` (the `Id` property) and its
    `is_menu_only` is `Item.item_is_menu` (the `ItemIsMenu` property).
11. **Overflow.** More than 256 queued work items drops them and re-reads everything (`needs_resync`).
12. **Menu tree.** Stored as a tree in an arena and flattened into the snapshot breadth first, so
    each entry's children are contiguous. Submenus are read when opened; a LayoutUpdated keeps the
    submenus that were loaded.

## Sources (cited in code)

- Protocol: KDE `org.kde.StatusNotifierWatcher.xml` and `org.kde.StatusNotifierItem.xml`, libdbusmenu
  `com.canonical.dbusmenu.xml`, as the research cites them. The mnemonic rule (`__` and `_`) comes
  from ksni's dbusmenu documentation as recorded in the research (single source, not re-read here).
- Windows: Microsoft Learn `Shell_NotifyIconW` and `NOTIFYICONDATAW` (the research's citations).
  The NOTIFYICONDATAW layout in `windows_api.c3` follows the shellapi.h field order; it was
  type-checked, not run.
- macOS: Apple AppKit reference (`NSStatusItem`, `NSStatusBar`, `NSMenu`, `NSMenuItem`), as
  cited in the research. Not run.

## Open for the lead

- `bleu_win` `message_loop`: a route for a custom message (deviation 7).
- The live test needs Python with dbus-next; `BLEU_TRAY_PYTHON` names an interpreter that has it.
