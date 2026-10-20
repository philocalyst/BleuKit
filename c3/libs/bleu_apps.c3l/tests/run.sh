#!/usr/bin/env bash
# Live test for bleu_apps D-Bus activation.
#
# Starts a private dbus-daemon and the python-dbus-next mock (activation_mock.py),
# builds a fake XDG tree with two desktop entries, runs activation_main.c3 against
# them, and checks what the mock received and which Exec lines ran.
#
#   libs/bleu_apps.c3l/tests/run.sh
#
# Needs dbus-daemon, c3c and python3 with dbus-next. BLEU_APPS_PYTHON selects the
# python; BLEU_APPS_LIBDIR overrides the library directory (default: tools/libdir.sh).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
work="$(mktemp -d)"
python="${BLEU_APPS_PYTHON:-python3}"
libdir="${BLEU_APPS_LIBDIR:-$("$repo/tools/libdir.sh")}"
pids=()
cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }

cat >"$work/bus.conf" <<XML
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path=$work/bus</listen>
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

BLEU_MOCK_LOG="$work/mock.log" "$python" -I "$here/activation_mock.py" >"$work/mock.out" 2>"$work/mock.err" &
pids+=("$!")
for _ in $(seq 1 100); do grep -q READY "$work/mock.out" 2>/dev/null && break; sleep 0.05; done
grep -q READY "$work/mock.out" || { cat "$work/mock.err"; fail "mock service did not start"; }

tree="$work/tree"
mkdir -p "$tree/usr/share/applications" "$tree/home/.local/share/applications"
cat >"$tree/usr/share/applications/org.example.Activatable.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Activatable
DBusActivatable=true
Exec=/bin/sh -c "echo exec > $work/activatable-exec" sh %U
Actions=second;

[Desktop Action second]
Name=Second
Exec=/bin/sh -c "echo exec > $work/activatable-exec-action" sh
DESKTOP
cat >"$tree/usr/share/applications/org.example.Hang.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Hang
DBusActivatable=true
Exec=/bin/sh -c "echo exec > $work/hang-exec"
DESKTOP
cat >"$tree/usr/share/applications/org.example.Missing.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Missing
DBusActivatable=true
Exec=/bin/sh -c "echo exec > $work/missing-exec"
DESKTOP

(cd "$work" && BLEU_APPS_ROOT="$tree" c3c --libdir "$libdir" --lib bleu_core --lib bleu_rt --lib bleu_service \
  --lib bleu_xdg --lib bleu_plist --lib bleu_dbus --lib bleu_objc --lib bleu_win --lib bleu_apps \
  compile-run "$here/activation_main.c3") || fail "the C3 driver failed"

[ -s "$work/mock.log" ] || fail "the mock received no calls"
grep -q '^Activate startup=startup-1 token=token-1$' "$work/mock.log" || fail "Activate with startup id and token"
grep -q '^Open file:///tmp/a.txt$' "$work/mock.log" || fail "Open with the URI"
grep -q '^ActivateAction second$' "$work/mock.log" || fail "ActivateAction"
[ ! -e "$work/activatable-exec" ] || fail "Exec ran although the bus activated the app"
[ ! -e "$work/hang-exec" ] || fail "Exec ran after an activation the bus did not answer"
[ -e "$work/missing-exec" ] || fail "Exec did not run as the fallback"
echo "mock calls:"; cat "$work/mock.log"
echo "PASS: D-Bus activation over a private session bus"
