#!/usr/bin/env bash
# Live test of the Linux tray host (bleu_tray, backend "sni") on a private session bus.
#
#   libs/bleu_tray.c3l/tests/run.sh          the host serves the watcher (mode "served")
#   libs/bleu_tray.c3l/tests/run.sh remote   another watcher (fake_watcher.py) is running, the host follows it
#
# 1. starts a private dbus-daemon and points DBUS_SESSION_BUS_ADDRESS at it;
# 2. compiles tray_probe.c3 and starts it: in mode "served" the probe serves the watcher and
#    publishes its own icon; in mode "remote" fake_watcher.py serves the watcher first;
# 3. starts fake_item.py (a StatusNotifierItem with a dbusmenu, registered as bus/path) and
#    host_check.py (a dbus-next host that reads and acts on our own icon);
# 4. checks every observation the probe and the scripts print against the expected lines.
#
# Needs dbus-daemon, c3c, python3 (with dbus-next: BLEU_TRAY_PYTHON, or a virtual environment
# created in the work directory, which needs pypi access). Prints one line per check and exits
# non-zero if any check fails. BLEU_TRAY_KEEP=1 keeps the outputs even when every check passes.
set -u
mode="${1:-served}"
case "$mode" in
  served) served=1 ;;
  remote) served=0 ;;
  *) echo "usage: run.sh [served|remote]"; exit 2 ;;
esac
here="$(cd "$(dirname "$0")" && pwd)"
lib="$(cd "$here/.." && pwd)"
repo="$(cd "$lib/../.." && pwd)"
work="$(mktemp -d)"
pids=()
failures=0

cleanup() {
  set +e  # a process that already exited makes kill fail; that is not an error here
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
  # The outputs are kept when a check failed, or when BLEU_TRAY_KEEP is set, for inspection.
  if [ -n "${BLEU_TRAY_KEEP:-}" ] || [ "$failures" -ne 0 ]; then
    say "outputs kept in $work"
  else
    rm -rf "$work"
  fi
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }

if [ -n "${BLEU_TRAY_PYTHON:-}" ]; then
  PYTHON="$BLEU_TRAY_PYTHON"
else
  python3 -m venv "$work/venv" && "$work/venv/bin/pip" install -q dbus-next >"$work/pip.log" 2>&1 || {
    say "could not install dbus-next (see $work/pip.log)"; exit 2; }
  PYTHON="$work/venv/bin/python"
fi

# A session bus of our own. Its socket lives in the work directory, which is short enough.
cat >"$work/bus.conf" <<XML
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=$work</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow receive_sender="*"/>
    <allow own="*"/>
  </policy>
</busconfig>
XML
dbus-daemon --config-file="$work/bus.conf" --nofork --print-address=1 >"$work/address" 2>"$work/daemon.log" &
pids+=("$!")
for _ in $(seq 1 100); do [ -s "$work/address" ] && break; sleep 0.05; done
DBUS_SESSION_BUS_ADDRESS="$(head -n1 "$work/address")"
export DBUS_SESSION_BUS_ADDRESS
say "bus: $DBUS_SESSION_BUS_ADDRESS"

# The probe, compiled once and run as a program.
ld="${BLEU_LIBDIR:-$("$repo/tools/libdir.sh")}"
libs=(--lib bleu_core --lib bleu_rt --lib bleu_service --lib bleu_dbus --lib bleu_objc --lib bleu_win --lib bleu_tray)
(cd "$work" && c3c --libdir "$ld" "${libs[@]}" compile "$here/tray_probe.c3" -o "$work/probe") >"$work/build.log" 2>&1 || {
  say "the probe does not compile (see $work/build.log)"; cat "$work/build.log"; exit 2; }
# In remote mode the foreign watcher runs before the probe, which must follow it.
if [ "$mode" = remote ]; then
  "$PYTHON" -I "$here/fake_watcher.py" >"$work/watcher.out" 2>&1 &
  pids+=("$!")
  for _ in $(seq 1 100); do grep -q '^WATCHER ready' "$work/watcher.out" 2>/dev/null && break; sleep 0.05; done
fi

# The fake item and the host client start once the probe is up.
"$work/probe" >"$work/probe.out" 2>&1 &
PROBE=$!
pids+=("$PROBE")
for _ in $(seq 1 300); do grep -q '^BACKEND' "$work/probe.out" 2>/dev/null && break; sleep 0.1; done
"$PYTHON" -I "$here/fake_item.py" >"$work/fake.out" 2>&1 &
pids+=("$!")
sleep 0.5
"$PYTHON" -I "$here/host_check.py" >"$work/host.out" 2>&1 &
pids+=("$!")

# The probe finishes when every phase has been seen (or a phase timed out).
timed_out=1
for _ in $(seq 1 600); do
  if ! kill -0 "$PROBE" 2>/dev/null; then timed_out=0; break; fi
  sleep 0.1
done
if [ "$timed_out" = 1 ]; then say "FAIL the probe did not finish"; kill "$PROBE" 2>/dev/null; failures=$((failures + 1)); fi

expect() { # file, regex, description
  if grep -Eq -- "$2" "$1"; then say "ok    $3"; else say "FAIL  $3  (no line matching: $2)"; failures=$((failures + 1)); fi
}

expect "$work/probe.out" '^BACKEND sni$'                                  "backend is the StatusNotifier backend"
expect "$work/probe.out" '^OWN_PUBLISHED ok$'                             "own icon published on the bus"
expect "$work/probe.out" "served=$served host=1 own=1"                    "watcher served=$served, this process a registered host with its icon published"
expect "$work/probe.out" '^ITEM id=org.test.FakeItem/StatusNotifierItem title=Probe Item status=1 category=0' "item from bus/path registration, Id/Title/Status/Category read"
expect "$work/probe.out" '^ICON name=face-smile pixmaps=1 '               "IconName read, IconPixmap present"
expect "$work/probe.out" '^PIXMAP 3x2 bytes=24 first=17,34,51,128$'      "ARGB32 network order converted to RGBA (3x2, non-square)"
expect "$work/probe.out" 'MENU index=0 id=0 .* menu_entries=|MENU index=0 id=0 label= ' "menu root is entry 0"
expect "$work/probe.out" 'MENU index=1 id=1 label=Open .* first=0 count=0' "mnemonic '_Open' shown as 'Open'"
expect "$work/probe.out" 'MENU index=2 id=2 label=Recent .* submenu=1 loaded=0' "submenu listed, children not loaded yet"
expect "$work/probe.out" 'MENU index=3 id=4 label= separator=1'           "separator entry"
expect "$work/probe.out" 'MENU index=4 id=6 label=Quit .* enabled=0'      "disabled entry"
expect "$work/probe.out" '^OPEN_SUBMENU ok$'                              "AboutToShow then GetLayout of the submenu"
expect "$work/probe.out" 'MENU index=[0-9]+ id=5 label=Item _one .* toggle=1 state=1 shortcut=Control\+s' "'__' gives '_', checkmark state, shortcut joined"
expect "$work/probe.out" 'MENU index=[0-9]+ id=7 label=Two'               "second submenu child"
expect "$work/probe.out" '^CLICK_MENU ok$'                                "menu click sent (Event clicked)"
expect "$work/probe.out" '^ACTIVATE ok$'                                  "Activate sent"
expect "$work/probe.out" '^SCROLL ok$'                                    "Scroll sent"
expect "$work/probe.out" '^SECONDARY_ACTIVATE ok$'                        "SecondaryActivate sent"
expect "$work/probe.out" '^CONTEXT_MENU ok$'                              "ContextMenu sent"
expect "$work/probe.out" 'ICON name=face-wink .* attention=dialog-warning overlay=emblem-new tooltip=New tip' "NewAttentionIcon, NewOverlayIcon, NewToolTip re-read"
expect "$work/probe.out" '^STATUS_CHANGED ok$'                            "NewStatus re-read the status (NeedsAttention)"
expect "$work/probe.out" '^MENU_RENAMED ok$'                              "LayoutUpdated re-read the menu"
expect "$work/probe.out" 'EVENT MENU_CHANGED item='                       "a menu change is announced as an event"
expect "$work/fake.out"  '^FAKE secondary 1 2$'                           "fake item received SecondaryActivate(1, 2)"
expect "$work/fake.out"  '^FAKE context 3 4$'                             "fake item received ContextMenu(3, 4)"
expect "$work/probe.out" '^ICON_CHANGED ok$'                              "NewIcon re-read the icon name"
expect "$work/probe.out" '^TITLE_CHANGED ok$'                             "NewTitle re-read the title"
expect "$work/probe.out" '^EVENT OWN_ACTIVATED item=.* x=5 y=6'           "our icon's Activate reaches the probe as an event"
expect "$work/probe.out" '^EVENT OWN_MENU_CLICKED item=.* menu=3'         "our menu's click reaches the probe as an event"
expect "$work/probe.out" '^ITEM_VANISHED ok$'                             "item vanished when its bus name went away"
expect "$work/probe.out" '^DONE$'                                         "probe finished"
expect "$work/fake.out"  '^FAKE activate 10 20$'                          "fake item received Activate(10, 20)"
expect "$work/fake.out"  '^FAKE scroll 1 vertical$'                       "fake item received Scroll(1, vertical)"
expect "$work/fake.out"  '^FAKE event clicked 6$'                         "fake menu received Event clicked on entry 6"
expect "$work/fake.out"  '^FAKE abouttoshow 2$'                           "fake menu received AboutToShow for the submenu"
expect "$work/host.out"  '^HOST host_registered True$'                    "a dbus-next host sees the watcher with a registered host"
if [ "$mode" = remote ]; then
  expect "$work/watcher.out" '^WATCHER host org.kde.StatusNotifierHost-'  "the foreign watcher got our host registration"
  expect "$work/watcher.out" '^WATCHER item org.kde.StatusNotifierItem-.*/StatusNotifierItem' "the foreign watcher got our own icon's registration"
  expect "$work/watcher.out" '^WATCHER item org.test.FakeItem/StatusNotifierItem' "the foreign watcher got the fake item's registration"
fi
expect "$work/host.out"  '^HOST own_title Bleu Probe$'                    "a dbus-next host reads our icon's Title"
expect "$work/host.out"  '^HOST own_icon applications-internet$'          "a dbus-next host reads our icon's IconName"
expect "$work/host.out"  '^HOST own_menu_entry 1 _Open$'                  "a dbus-next host reads our menu entry (raw label: the host shows mnemonics)"
expect "$work/host.out"  '^HOST activated own icon$'                      "a dbus-next host activates our icon"
expect "$work/host.out"  '^HOST clicked own menu$'                        "a dbus-next host clicks our menu"

if [ "$failures" -eq 0 ]; then say "tray live: all checks passed"; else say "tray live: $failures check(s) failed"; fi
exit "$failures"
