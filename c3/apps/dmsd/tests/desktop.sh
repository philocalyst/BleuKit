#!/usr/bin/env bash
# End-to-end test of the dmsd modules wlroutput, gamma, theme.auto and freedesktop, on a fake
# Wayland compositor (fake_wayland.py, the wlr protocols) and a mock portal (mock_portal.py) on a
# private session bus. Nothing touches the real display, the session bus or /sys.
#
#   desktop.sh <dmsd binary> <python with dbus-next>
#
# Called by run.sh with the daemon it built. Exit status 0 when every check passed.
# DMSD_KEEP_WORK=1 keeps the work directory (the logs of every process) for inspection.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
dmsd="$1"
python="$2"
work="$(mktemp -d /tmp/dmsd-mod.XXXXXX)"
pids=()
status=0

cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
  if [ -n "${DMSD_KEEP_WORK:-}" ]; then echo "work kept in $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT

# Wait until a path exists (a socket, or a file a process writes when ready), or fail after ~5 s.
wait_for_path() {
  for _ in $(seq 100); do [ -e "$1" ] && return 0; sleep 0.05; done
  echo "timed out waiting for $1"; return 1
}

# A private session bus (the portal mock and the freedesktop backend use it).
cat >"$work/session.conf" <<XML
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path=$work/session.sock</listen>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow receive_sender="*"/>
    <allow own="*"/>
  </policy>
</busconfig>
XML
dbus-daemon --config-file="$work/session.conf" --nofork >"$work/dbus.log" 2>&1 &
pids+=($!)
wait_for_path "$work/session.sock" || exit 2
export DBUS_SESSION_BUS_ADDRESS="unix:path=$work/session.sock"

"$python" "$here/mock_portal.py" >"$work/portal.out" 2>&1 &
pids+=($!)
for _ in $(seq 100); do grep -q READY "$work/portal.out" 2>/dev/null && break; sleep 0.05; done
if ! grep -q READY "$work/portal.out"; then echo "portal mock did not start"; cat "$work/portal.out"; exit 2; fi

# The fake compositor: DP-1 takes a gamma ramp, HDMI-A-1 does not (its gamma control is refused).
cat >"$work/scenario.json" <<'JSON'
{
  "outputs": [
    {"name": "DP-1", "description": "Fake panel", "make": "Acme", "model": "P1", "serial": "SN1",
     "width_mm": 600, "height_mm": 340, "x": 0, "y": 0, "scale": 1.0,
     "modes": [{"width": 1920, "height": 1080, "refresh": 60000, "preferred": true},
               {"width": 1280, "height": 720, "refresh": 60000, "preferred": false}],
     "current": {"width": 1920, "height": 1080, "refresh": 60000, "preferred": true}},
    {"name": "HDMI-A-1", "description": "Fake monitor", "make": "Acme", "model": "M2", "serial": "SN2",
     "width_mm": 520, "height_mm": 290, "x": 1920, "y": 0, "scale": 1.0,
     "modes": [{"width": 1920, "height": 1080, "refresh": 60000, "preferred": true}],
     "current": {"width": 1920, "height": 1080, "refresh": 60000, "preferred": true}, "gamma": false}
  ]
}
JSON
"$python" "$here/fake_wayland.py" "$work/wl-test" "$work/scenario.json" "$work/wayland.log" >"$work/wayland.out" 2>&1 &
pids+=($!)
wait_for_path "$work/wl-test" || { cat "$work/wayland.out"; exit 2; }

# A fake sysfs tree for the brightness module (as run.sh makes it).
root="$work/root"
mkdir -p "$root/sys/class/backlight/intel_backlight" "$root/sys/class/leds/input5::kbd_backlight" "$root/sys/class/drm"
echo firmware >"$root/sys/class/backlight/intel_backlight/type"
echo 48000 >"$root/sys/class/backlight/intel_backlight/brightness"
echo 96000 >"$root/sys/class/backlight/intel_backlight/max_brightness"
echo 1 >"$root/sys/class/leds/input5::kbd_backlight/brightness"
echo 3 >"$root/sys/class/leds/input5::kbd_backlight/max_brightness"

echo "== the modules, against the fake compositor and the portal"
sock="$work/dmsd.sock"
XDG_RUNTIME_DIR="$work" WAYLAND_DISPLAY=wl-test "$dmsd" --socket "$sock" --fake-root "$root" \
  >"$work/dmsd.out" 2>"$work/dmsd.err" &
dmsd_pid=$!
pids+=($dmsd_pid)
wait_for_path "$sock" || { cat "$work/dmsd.err"; exit 2; }

if "$python" "$here/check_desktop.py" "$sock" "$work" "$here" >"$work/check.log" 2>&1; then
  echo "ok   module checks ($(grep -c '^ok' "$work/check.log") checks)"
else
  echo "FAIL module checks"; grep -v "^ok" "$work/check.log" | head -60; status=1
fi

echo "== shutdown on SIGTERM"
kill -TERM "$dmsd_pid"
for _ in $(seq 100); do kill -0 "$dmsd_pid" 2>/dev/null || break; sleep 0.05; done
if kill -0 "$dmsd_pid" 2>/dev/null; then
  echo "FAIL dmsd did not stop within 5 s"; status=1; kill -KILL "$dmsd_pid"
else
  wait "$dmsd_pid"; rc=$?
  if [ "$rc" -eq 0 ]; then echo "ok   exit status 0 after SIGTERM"; else echo "FAIL exit status $rc"; status=1; fi
fi
if grep -q "LEAKS\|Out of bounds\|ERROR" "$work/dmsd.err"; then
  echo "FAIL dmsd reported a leak or an error"; cat "$work/dmsd.err"; status=1
else
  echo "ok   no leak or runtime error reported"
fi

echo "== no compositor: the gamma and wlroutput modules are reported once and not advertised"
absent_sock="$work/absent.sock"
XDG_RUNTIME_DIR="$work" WAYLAND_DISPLAY=no-such-display "$dmsd" --socket "$absent_sock" --fake-root "$root" \
  >/dev/null 2>"$work/absent.err" &
absent_pid=$!
pids+=($absent_pid)
wait_for_path "$absent_sock" || { cat "$work/absent.err"; exit 2; }
caps=$("$python" -c "
import socket
s = socket.socket(socket.AF_UNIX); s.connect('$absent_sock')
print(s.makefile('rb').readline().decode().strip())")
kill -TERM "$absent_pid"; wait "$absent_pid" 2>/dev/null
ok=1
for name in gamma wlroutput; do
  if echo "$caps" | grep -q "\"$name\""; then ok=0; fi
  if [ "$(grep -c "$name: not started" "$work/absent.err")" -ne 1 ]; then ok=0; fi
done
if [ "$ok" -eq 1 ] && echo "$caps" | grep -q '"freedesktop"' && echo "$caps" | grep -q '"theme.auto"'; then
  echo "ok   gamma and wlroutput absent and reported once; freedesktop and theme.auto still advertised"
else
  echo "FAIL handshake was $caps"; cat "$work/absent.err"; status=1
fi

if [ "$status" -eq 0 ]; then echo "MODULES PASSED"; else echo "MODULES FAILED"; fi
exit "$status"
