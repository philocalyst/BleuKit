#!/usr/bin/env bash
# dmsd's `bluetooth` module, against a private system bus with the BlueZ mock of
# libs/bleu_bluetooth.c3l/tests/mock_bluez.py (run from there, not copied) and the logind
# mock of this directory. Nothing touches the real system bus or /sys.
#
#   apps/dmsd/tests/bluetooth.sh <dmsd binary> <python with dbus-next> <work directory>
#
# Called by run.sh, which builds dmsd and makes the python. Prints one "ok" or "FAIL" line
# per check. Exit status 0 when every check passed.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
app="$(cd "$here/.." && pwd)"
repo="$(cd "$app/../.." && pwd)"
dmsd_bin="$1"
python="$2"
work="$3/bluetooth"
mock="$repo/libs/bleu_bluetooth.c3l/tests/mock_bluez.py"
status=0
pids=()

cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
}
trap cleanup EXIT

mkdir -p "$work"
if [ ! -f "$mock" ]; then
  echo "FAIL the BlueZ mock is missing: $mock"; exit 2
fi

# A private system bus, as run.sh makes one.
cat >"$work/bus.conf" <<XML
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>system</type>
  <listen>unix:path=$work/bus.sock</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow receive_sender="*"/>
    <allow own="*"/>
  </policy>
</busconfig>
XML
dbus-daemon --config-file="$work/bus.conf" --nofork >"$work/dbus.log" 2>&1 &
pids+=($!)
for _ in $(seq 100); do [ -S "$work/bus.sock" ] && break; sleep 0.05; done
export DBUS_SYSTEM_BUS_ADDRESS="unix:path=$work/bus.sock"

# The logind mock: it makes the handshake's order checkable (loginctl, bluetooth, brightness).
DMSD_MOCK_LOG="$work/logind.log" "$python" "$app/tests/mock_logind.py" >"$work/logind.out" 2>&1 &
pids+=($!)
for _ in $(seq 100); do grep -q READY "$work/logind.out" 2>/dev/null && break; sleep 0.05; done

# The BlueZ mock owns org.bluez on the bus. The mock connects to DBUS_SESSION_BUS_ADDRESS, so it gets this bus.
DBUS_SESSION_BUS_ADDRESS="$DBUS_SYSTEM_BUS_ADDRESS" "$python" -I "$mock" >"$work/bluez.out" 2>"$work/bluez.err" &
bluez_pid=$!
pids+=($bluez_pid)
for _ in $(seq 200); do grep -q READY "$work/bluez.out" 2>/dev/null && break; sleep 0.05; done
if ! grep -q READY "$work/bluez.out"; then
  echo "FAIL the BlueZ mock did not start"; cat "$work/bluez.err"; exit 2
fi

# A fake rfkill tree: one Bluetooth switch, not blocked (bleu_bluetooth reads <root>/sys/class/rfkill).
root="$work/root"
mkdir -p "$root/sys/class/rfkill/rfkill0"
echo bluetooth >"$root/sys/class/rfkill/rfkill0/type"
echo 0 >"$root/sys/class/rfkill/rfkill0/soft"
echo 0 >"$root/sys/class/rfkill/rfkill0/hard"
# The brightness module needs a backlight to start (so the handshake shows it as run.sh's does).
mkdir -p "$root/sys/class/backlight/intel_backlight" "$root/sys/class/drm"
echo firmware >"$root/sys/class/backlight/intel_backlight/type"
echo 48000 >"$root/sys/class/backlight/intel_backlight/brightness"
echo 96000 >"$root/sys/class/backlight/intel_backlight/max_brightness"

# Whether the handshake of the socket at $1 advertises capability $2: prints yes or no.
advertises() {
  "$python" -c "
import json, socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
caps = json.loads(s.makefile('rb').readline().decode())['capabilities']
print('yes' if sys.argv[2] in caps else 'no')" "$1" "$2"
}

echo "== bluetooth module: DMS methods, pairing prompts, state topic"
sock="$work/dmsd.sock"
"$dmsd_bin" --socket "$sock" --fake-root "$root" >"$work/dmsd.out" 2>"$work/dmsd.err" &
dmsd_pid=$!
pids+=($dmsd_pid)
for _ in $(seq 100); do [ -S "$sock" ] && break; sleep 0.05; done
if "$python" "$app/tests/bluetooth_check.py" "$sock" "$app/tests" >"$work/check.log" 2>&1; then
  echo "ok   bluetooth checks ($(grep -c '^ok' "$work/check.log") checks)"
else
  echo "FAIL bluetooth checks"; grep -v "^ok" "$work/check.log" | head -40; status=1
fi

echo "== bluetooth module: shutdown with a pairing in flight"
kill -TERM "$dmsd_pid"
for _ in $(seq 100); do kill -0 "$dmsd_pid" 2>/dev/null || break; sleep 0.05; done
if kill -0 "$dmsd_pid" 2>/dev/null; then
  echo "FAIL dmsd did not stop within 5 s with a pairing in flight"; status=1; kill -KILL "$dmsd_pid"
else
  wait "$dmsd_pid"; rc=$?
  if [ "$rc" -eq 0 ]; then echo "ok   exit status 0 after SIGTERM with a pairing in flight"; else echo "FAIL exit status $rc"; status=1; fi
fi
if grep -q "LEAKS\|Out of bounds\|ERROR" "$work/dmsd.err"; then
  echo "FAIL dmsd reported a leak or an error"; cat "$work/dmsd.err"; status=1
else
  echo "ok   no leak or runtime error reported"
fi

echo "== bluetooth module: --module-off bluetooth leaves it out"
sock_off="$work/off.sock"
"$dmsd_bin" --socket "$sock_off" --fake-root "$root" --module-off bluetooth >/dev/null 2>"$work/off.err" &
off_pid=$!
pids+=($off_pid)
for _ in $(seq 100); do [ -S "$sock_off" ] && break; sleep 0.05; done
off_bluetooth=$(advertises "$sock_off" bluetooth)
off_brightness=$(advertises "$sock_off" brightness)
kill -TERM "$off_pid"; wait "$off_pid" 2>/dev/null
if [ "$off_bluetooth" = no ] && [ "$off_brightness" = yes ]; then
  echo "ok   --module-off bluetooth: not advertised"
else
  echo "FAIL --module-off bluetooth: advertised $off_bluetooth, brightness $off_brightness"; status=1
fi

echo "== bluetooth module: absent BlueZ is reported once and not advertised"
kill "$bluez_pid" 2>/dev/null
wait "$bluez_pid" 2>/dev/null
sock_absent="$work/absent.sock"
"$dmsd_bin" --socket "$sock_absent" --fake-root "$root" >/dev/null 2>"$work/absent.err" &
absent_pid=$!
pids+=($absent_pid)
for _ in $(seq 100); do [ -S "$sock_absent" ] && break; sleep 0.05; done
absent_bluetooth=$(advertises "$sock_absent" bluetooth)
absent_loginctl=$(advertises "$sock_absent" loginctl)
kill -TERM "$absent_pid"; wait "$absent_pid" 2>/dev/null
if [ "$absent_bluetooth" = no ] && [ "$absent_loginctl" = yes ] \
   && [ "$(grep -c 'bluetooth: not started' "$work/absent.err")" -eq 1 ]; then
  echo "ok   no BlueZ: bluetooth not advertised (loginctl still is), reported once"
else
  echo "FAIL no BlueZ: bluetooth advertised $absent_bluetooth, loginctl $absent_loginctl"; cat "$work/absent.err"; status=1
fi

if [ "$status" -eq 0 ]; then echo "BLUETOOTH PASSED"; else echo "BLUETOOTH FAILED"; fi
exit "$status"
