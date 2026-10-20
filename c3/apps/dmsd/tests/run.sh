#!/usr/bin/env bash
# End-to-end test of dmsd: the DMS wire protocol over a real socket, brightness on a
# fake sysfs tree, loginctl and the sleep barrier against a private system bus and the
# dbus-next logind mock. Nothing touches the real /sys, /dev or system bus.
#
#   apps/dmsd/tests/run.sh
#
# Environment:
#   DMSD_PYTHON   python3 with dbus-next (default: a virtual environment made here)
#   DMSD_LIBDIR   library directory for c3c (default: tools/libdir.sh)
#
# Needs c3c, dbus-daemon, dbus-send and python3. The unit tests of the arithmetic run
# first (src/brightness_math_test.c3).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
app="$(cd "$here/.." && pwd)"
repo="$(cd "$app/../.." && pwd)"
work="$(mktemp -d /tmp/dmsd.XXXXXX)"
libdir="${DMSD_LIBDIR:-}"
own_libdir=""
pids=()
status=0

cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
  [ -n "$own_libdir" ] && rm -rf "$own_libdir"
  rm -rf "$work"
}
trap cleanup EXIT

if [ -z "$libdir" ]; then
  own_libdir="$("$repo/tools/libdir.sh")"
  libdir="$own_libdir"
fi
libs=(bleu_core bleu_rt bleu_service bleu_dbus bleu_ddc bleu_dl bleu_objc bleu_win bleu_session bleu_power bleu_brightness bleu_ipc bleu_json bleu_bluetooth bleu_clipboard bleu_wl bleu_sysinfo bleu_apps bleu_xdg bleu_plist)
largs=(); for l in "${libs[@]}"; do largs+=(--lib "$l"); done
# c3c writes out/ and build/ into the working directory: compile from the private one.
c3t() { (cd "$work" && c3c --libdir "$libdir" "${largs[@]}" "$@"); }

echo "== unit tests: brightness arithmetic"
if c3t compile-test "$app/src/brightness_math.c3" "$app/src/brightness_math_test.c3" -o "$work/unit" >"$work/unit.log" 2>&1 \
   && grep -q "Test Result: PASSED" "$work/unit.log"; then
  echo "ok   unit tests"
else
  echo "FAIL unit tests (see $work/unit.log)"; tail -20 "$work/unit.log"; status=1
fi

echo "== build dmsd"
if ! c3t compile -o "$work/dmsd" "$app"/src/*.c3 >"$work/build.log" 2>&1; then
  echo "FAIL build (see $work/build.log)"; tail -40 "$work/build.log"; exit 1
fi
echo "ok   build"

python="${DMSD_PYTHON:-}"
if [ -z "$python" ]; then
  python3 -m venv "$work/venv" && "$work/venv/bin/pip" install -q dbus-next >"$work/pip.log" 2>&1 || {
    echo "could not install dbus-next (see $work/pip.log)"; exit 2; }
  python="$work/venv/bin/python"
fi

# A private system bus with the logind mock on it.
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

export DMSD_MOCK_LOG="$work/mock.log"
"$python" "$here/mock_logind.py" >"$work/mock.out" 2>&1 &
pids+=($!)
for _ in $(seq 100); do grep -q READY "$work/mock.out" 2>/dev/null && break; sleep 0.05; done
if ! grep -q READY "$work/mock.out"; then echo "logind mock did not start"; cat "$work/mock.out"; exit 2; fi

# A fake sysfs tree: one panel backlight (no actual_brightness, so the backend reads
# `brightness` back) and one keyboard LED.
root="$work/root"
mkdir -p "$root/sys/class/backlight/intel_backlight" "$root/sys/class/leds/input5::kbd_backlight" "$root/sys/class/drm"
echo firmware >"$root/sys/class/backlight/intel_backlight/type"
echo 48000 >"$root/sys/class/backlight/intel_backlight/brightness"
echo 96000 >"$root/sys/class/backlight/intel_backlight/max_brightness"
echo 1 >"$root/sys/class/leds/input5::kbd_backlight/brightness"
echo 3 >"$root/sys/class/leds/input5::kbd_backlight/max_brightness"

sock="$work/dmsd.sock"
env -u WAYLAND_DISPLAY "$work/dmsd" --socket "$sock" --fake-root "$root" >"$work/dmsd.out" 2>"$work/dmsd.err" &
dmsd_pid=$!
pids+=($dmsd_pid)
for _ in $(seq 100); do [ -S "$sock" ] && break; sleep 0.05; done

echo "== protocol and modules"
if "$python" "$here/check_dms.py" "$sock" "$root" "$here" >"$work/check.log" 2>&1; then
  echo "ok   protocol checks ($(grep -c '^ok' "$work/check.log") checks)"
else
  echo "FAIL protocol checks"; grep -v "^ok" "$work/check.log" | head -40; status=1
fi

echo "== sleep barrier: PREPARE_SLEEP is answered after lockerReady"

sleep_test() {
  # $1: "ready" to send lockerReady one second in, "silent" to send nothing.
  local mode="$1"
  local start end
  "$python" - "$sock" "$mode" <<'EOF' &
import os, sys, time
sys.path.insert(0, os.environ["DMSD_TEST_DIR"])
from dmsclient import DmsClient
client = DmsClient(sys.argv[1])
client.request("loginctl.unlock")
client.request("loginctl.setLockBeforeSuspend", {"enabled": True})
client.request("loginctl.setSleepInhibitorEnabled", {"enabled": True})
time.sleep(float(os.environ.get("DMSD_SLEEP_SETTLE", "1")))
if sys.argv[2] == "ready":
    time.sleep(1.0)
    reply = client.request("loginctl.lockerReady")
    print("lockerReady", reply.get("result"))
time.sleep(float(os.environ.get("DMSD_SLEEP_WAIT", "0")))
client.close()
EOF
  local client_pid=$!
  start=$(date +%s%N)
  sleep 0.5
  dbus-send --system --print-reply --dest=org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager.Suspend boolean:false >"$work/suspend-$mode.out" 2>&1
  end=$(date +%s%N)
  wait "$client_pid"
  echo "$(( (end - start) / 1000000 ))" >"$work/suspend-$mode.ms"
}
export DMSD_TEST_DIR="$here"
: >"$work/mock.log"
sleep_test ready
ready_ms=$(cat "$work/suspend-ready.ms")
if grep -q "Released" "$work/mock.log" && [ "$ready_ms" -ge 1000 ] && [ "$ready_ms" -lt 4000 ]; then
  echo "ok   suspend finished after lockerReady in ${ready_ms} ms"
else
  echo "FAIL suspend with lockerReady took ${ready_ms} ms"; cat "$work/mock.log"; status=1
fi
for want in "Suspend" "PrepareForSleep true" "LockSession 32" "PrepareForSleep false"; do
  if grep -qx "$want" "$work/mock.log"; then echo "ok   mock saw: $want"; else echo "FAIL mock did not see: $want"; status=1; fi
done
order=$(grep -n "^PrepareForSleep true\|^LockSession 32\|^Released\|^PrepareForSleep false" "$work/mock.log" | cut -d: -f2 | tr '\n' ' ')
case "$order" in
  "PrepareForSleep true LockSession 32 Released"*) echo "ok   order: lock, then release, then resume";;
  *) echo "FAIL order was: $order"; status=1;;
esac

echo "== sleep barrier: without lockerReady the barrier gives up after five seconds"
: >"$work/mock.log"
DMSD_SLEEP_WAIT=0 sleep_test silent
silent_ms=$(cat "$work/suspend-silent.ms")
if [ "$silent_ms" -ge 4500 ] && [ "$silent_ms" -lt 9000 ]; then
  echo "ok   suspend without lockerReady released after ${silent_ms} ms (LOCKER_READY_TIMEOUT)"
else
  echo "FAIL suspend without lockerReady took ${silent_ms} ms"; cat "$work/mock.log"; status=1
fi

echo "== bluetooth module: own private bus with the BlueZ mock (tests/bluetooth.sh)"
if ! bash "$here/bluetooth.sh" "$work/dmsd" "$python" "$work"; then status=1; fi

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
keep=()
for p in "${pids[@]}"; do [ "$p" = "$dmsd_pid" ] || keep+=("$p"); done
pids=("${keep[@]}")

echo "== absent backend is reported once and is not advertised"
env -u WAYLAND_DISPLAY DBUS_SYSTEM_BUS_ADDRESS="unix:path=$work/no-bus.sock" "$work/dmsd" --socket "$work/absent.sock" --fake-root "$root" >/dev/null 2>"$work/absent.err" &
absent_pid=$!
pids+=($absent_pid)
for _ in $(seq 100); do [ -S "$work/absent.sock" ] && break; sleep 0.05; done
hs=$("$python" -c "
import socket,sys
s=socket.socket(socket.AF_UNIX); s.connect('$work/absent.sock'); print(s.makefile('rb').readline().decode().strip())")
kill -TERM "$absent_pid"; wait "$absent_pid" 2>/dev/null
if [ "$hs" = '{"apiVersion":38,"capabilities":["dgop","brightness"]}' ] && [ "$(grep -c 'loginctl: not started' "$work/absent.err")" -eq 1 ]; then
  echo "ok   loginctl not advertised, reported once"
else
  echo "FAIL handshake was $hs"; cat "$work/absent.err"; status=1
fi

echo "== modules: dgop, apps, evdev, refusals, clipboard absence (own daemon, own XDG tree)"
if ! bash "$here/modules.sh" "$work/dmsd" "$python"; then status=1; fi

if [ "$status" -eq 0 ]; then echo "ALL PASSED"; else echo "FAILED"; fi
exit "$status"
