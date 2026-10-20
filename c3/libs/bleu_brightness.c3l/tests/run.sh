#!/usr/bin/env bash
# Tests for bleu_brightness on Linux.
#
#   libs/bleu_brightness.c3l/tests/run.sh
#
# 1. The @test functions in src/ (pure logic, the in-process engine with a fake
#    platform, and the sysfs/DRM tests on a fake root). None of them touches the
#    real /sys, /dev or bus.
# 2. The logind route: a private dbus-daemon, the Python logind stand-in in
#    tests/logind_mock.py (dbus-next), and the service with the fake root. Run
#    twice: once where the stand-in implements SetBrightness, once where it does
#    not (the sysfs fallback must carry the write).
#
# Needs c3c, python3 and dbus-daemon. Set BLEU_BRIGHTNESS_PYTHON to a python with
# dbus-next; otherwise a virtual environment is made in the work directory.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
lib="$(cd "$here/.." && pwd)"
repo="$(cd "$lib/../.." && pwd)"
src="$lib/src"
work="$(mktemp -d)"
libdir="$("$repo/tools/libdir.sh")"
pids=()
cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$work" "$libdir"
}
trap cleanup EXIT

# c3c writes build/ and out/ under its working directory: compile from a private one
# so that concurrent builds of other libraries do not clash with this run.
c3t() { (cd "$work" && c3c "$@"); }
libs=(--lib bleu_core --lib bleu_rt --lib bleu_service --lib bleu_dbus --lib bleu_ddc --lib bleu_dl --lib bleu_brightness)
nontest=$(ls "$src"/*.c3 | grep -v _test.c3)
tests=$(ls "$src"/*_test.c3)
status=0

echo "== unit and fake-root tests"
c3t --libdir "$libdir" "${libs[@]}" compile-test $tests --sources $nontest 2>&1 | tee "$work/unit.log" | grep -E "FAIL|Test Result|ERROR"
grep -q "Test Result: PASSED" "$work/unit.log" || status=1

if [ -n "${BLEU_BRIGHTNESS_PYTHON:-}" ]; then
  python="$BLEU_BRIGHTNESS_PYTHON"
else
  python3 -m venv "$work/venv" && "$work/venv/bin/pip" install -q dbus-next >"$work/pip.log" 2>&1 || {
    echo "could not install dbus-next (see $work/pip.log)"; exit 2; }
  python="$work/venv/bin/python"
fi

start_bus() {
  cat >"$work/bus.conf" <<XML
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path=$work/bus.sock</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow receive_sender="*"/>
    <allow own="*"/>
  </policy>
</busconfig>
XML
  dbus-daemon --config-file="$work/bus.conf" --nofork --print-address=1 >"$work/address" 2>"$work/daemon.log" &
  pids+=($!)
  for _ in $(seq 100); do [ -s "$work/address" ] && break; sleep 0.05; done
  head -1 "$work/address"
}

make_root() {
  local root="$1"
  mkdir -p "$root/sys/class/backlight/intel_backlight" "$root/sys/class/leds/input5::kbd_backlight"
  echo firmware >"$root/sys/class/backlight/intel_backlight/type"
  echo 48000 >"$root/sys/class/backlight/intel_backlight/brightness"
  echo 48000 >"$root/sys/class/backlight/intel_backlight/actual_brightness"
  echo 96000 >"$root/sys/class/backlight/intel_backlight/max_brightness"
  echo 1 >"$root/sys/class/leds/input5::kbd_backlight/brightness"
  echo 3 >"$root/sys/class/leds/input5::kbd_backlight/max_brightness"
}

address="$(start_bus)"
if [ -z "$address" ]; then echo "dbus-daemon did not start (see $work/daemon.log)"; exit 2; fi

for mode in ok unknown; do
  echo "== logind route, stand-in mode: $mode"
  root="$work/root-$mode"
  make_root "$root"
  "$python" "$here/logind_mock.py" "$address" "$root" "$mode" >"$work/mock-$mode.log" 2>&1 &
  mock=$!
  pids+=("$mock")
  for _ in $(seq 100); do grep -q ready "$work/mock-$mode.log" 2>/dev/null && break; sleep 0.05; done
  BLEU_BRIGHTNESS_BUS="$address" BLEU_BRIGHTNESS_ROOT="$root" BLEU_BRIGHTNESS_MODE="$mode" \
    c3t --libdir "$libdir" "${libs[@]}" compile-test "$src/logind_integration_test.c3" --sources $nontest 2>&1 | tee "$work/logind-$mode.log" | grep -E "FAIL|Test Result|ERROR|logind"
  grep -q "Test Result: PASSED" "$work/logind-$mode.log" || { status=1; cat "$work/mock-$mode.log"; }
  kill "$mock" 2>/dev/null; wait "$mock" 2>/dev/null
done

if [ "$status" -eq 0 ]; then echo "ALL PASSED"; else echo "FAILED"; fi
exit $status
