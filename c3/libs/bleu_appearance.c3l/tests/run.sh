#!/usr/bin/env bash
# Live tests for bleu_appearance on Linux.
#
# Starts a private dbus-daemon, a python-dbus-next mock of the Settings portal
# (tests/mock_portal.py), and GNOME settings from tests/schemas compiled into a
# scratch directory, with GSETTINGS_BACKEND=keyfile so nothing touches the real
# session. Then runs tests/appearance_check.c3 in three modes:
#   portal     the mock is on the bus: portal backend, gsettings for desktop keys
#   gsettings  no portal: gsettings backend, with a wallpaper command
#   absent     no portal and no gsettings on PATH: nothing opens
#
#   libs/bleu_appearance.c3l/tests/run.sh
#
# Needs dbus-daemon, glib-compile-schemas, gsettings, c3c and python3. Set
# BLEU_APPEARANCE_PYTHON to a python with dbus-next, or let the script create a
# virtual environment in its work directory (needs pypi access).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
lib="$(cd "$here/.." && pwd)"
repo="$(cd "$here/../../.." && pwd)"
work="$(mktemp -d)"
pids=()
failed=0

cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }

if [ -n "${BLEU_APPEARANCE_PYTHON:-}" ]; then
  PYTHON="$BLEU_APPEARANCE_PYTHON"
else
  python3 -m venv "$work/venv" && "$work/venv/bin/pip" install -q dbus-next >"$work/pip.log" 2>&1 || {
    say "could not install dbus-next (see $work/pip.log)"; exit 2; }
  PYTHON="$work/venv/bin/python"
fi

# GNOME schemas from the fixtures, and a keyfile settings backend in the work directory.
mkdir -p "$work/schemas" "$work/cfg"
cp "$here"/schemas/*.xml "$work/schemas/"
glib-compile-schemas "$work/schemas" || { say "schema compile failed"; exit 2; }
export GSETTINGS_SCHEMA_DIR="$work/schemas" GSETTINGS_BACKEND=keyfile XDG_CONFIG_HOME="$work/cfg"
gs() { gsettings set "$@" || { say "gsettings set $* failed"; exit 2; }; }
gs org.gnome.desktop.interface font-name "'Test Sans 12'"
gs org.gnome.desktop.interface text-scaling-factor 1.25
gs org.gnome.desktop.interface clock-format "'24h'"
gs org.gnome.desktop.interface color-scheme "'prefer-light'"
gs org.gnome.desktop.background picture-uri "'file:///usr/share/backgrounds/test-light.png'"

# Starts the daemon on $1 and sets BUS_PID and DBUS_SESSION_BUS_ADDRESS.
start_bus() {
  local listen="$1" conf="$work/bus.conf"
  cat >"$conf" <<XML
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>$listen</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow receive_sender="*"/>
    <allow own="*"/>
  </policy>
</busconfig>
XML
  rm -f "$work/address"
  dbus-daemon --config-file="$conf" --nofork --print-address=1 >"$work/address" 2>"$work/daemon.log" &
  BUS_PID=$!
  pids+=("$BUS_PID")
  for _ in $(seq 1 100); do
    [ -s "$work/address" ] && break
    sleep 0.05
  done
  DBUS_SESSION_BUS_ADDRESS="$(head -n1 "$work/address")"
  export DBUS_SESSION_BUS_ADDRESS
}

start_mock() {
  "$PYTHON" -I "$here/mock_portal.py" >"$work/mock.out" 2>"$work/mock.err" &
  MOCK_PID=$!
  pids+=("$MOCK_PID")
  for _ in $(seq 1 200); do
    grep -q READY "$work/mock.out" 2>/dev/null && return 0
    sleep 0.05
  done
  say "the mock portal did not start:"; cat "$work/mock.err"; exit 2
}

say "== compile"
# BLEU_LIBDIR overrides the library directory (for testing against a committed dependency).
LIBDIR="${BLEU_LIBDIR:-$(bash "$repo/tools/libdir.sh")}"
(cd "$work" && c3c --libdir "$LIBDIR" --lib bleu_core --lib bleu_rt --lib bleu_service --lib bleu_dbus \
   --lib bleu_objc --lib bleu_win --lib bleu_appearance compile "$here/appearance_check.c3" -o "$work/check") \
   >"$work/compile.log" 2>&1 || { say "compile failed"; cat "$work/compile.log"; exit 2; }

say "== mode: portal"
start_bus "unix:tmpdir=$work"
start_mock
timeout 120 "$work/check" portal || failed=1
gsettings get org.gnome.desktop.interface color-scheme | grep -qx "'prefer-dark'" \
  && say "PASS set_color_scheme wrote prefer-dark to gsettings" \
  || { say "FAIL set_color_scheme did not write gsettings"; failed=1; }
gsettings get org.gnome.desktop.background picture-uri-dark | grep -qx "'file:///usr/share/backgrounds/bleu-new.png'" \
  && say "PASS set_wallpaper wrote picture-uri-dark" \
  || { say "FAIL set_wallpaper did not write picture-uri-dark"; failed=1; }
kill "$MOCK_PID" "$BUS_PID" 2>/dev/null
wait "$MOCK_PID" "$BUS_PID" 2>/dev/null

say "== mode: gsettings (no portal)"
gs org.gnome.desktop.interface color-scheme "'prefer-light'"
start_bus "unix:tmpdir=$work"
marker="$work/wallpaper-command.out"
timeout 120 "$work/check" gsettings "$marker" || failed=1
grep -qx '/tmp/bleu-wallpaper.png' "$marker" \
  && say "PASS the wallpaper command received the path" \
  || { say "FAIL the wallpaper command did not run with the path"; failed=1; }
kill "$BUS_PID" 2>/dev/null
wait "$BUS_PID" 2>/dev/null

say "== mode: absent (no portal, no gsettings on PATH)"
DBUS_SESSION_BUS_ADDRESS="unix:path=$work/no-bus" PATH=/nonexistent "$work/check" absent || failed=1

if [ "$failed" -eq 0 ]; then say "APPEARANCE LIVE TESTS OK"; else say "APPEARANCE LIVE TESTS FAILED"; fi
exit "$failed"
