#!/usr/bin/env bash
# Runs the Linux Secret Service backend against a private dbus-daemon and the
# Python mock in secret_service_mock.py. Each mock mode has its own live test file
# in tests/live; every run also executes the pure unit tests in src/.
#
#   libs/bleu_secrets.c3l/tests/run.sh
#
# Needs dbus-daemon, c3c and python3 with dbus-next and cryptography. Set
# BLEU_SECRETS_PYTHON to such a python; otherwise a venv is created in the work
# directory (needs pypi.org access). BLEU_SECRETS_LIBDIR overrides the library
# directory (see tools/libdir.sh), e.g. to test against a committed bleu_dbus.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
lib="$(cd "$here/.." && pwd)"
repo="$(cd "$lib/../.." && pwd)"
work="$(mktemp -d)"
pids=()
cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

PY="${BLEU_SECRETS_PYTHON:-}"
if [ -z "$PY" ]; then
  python3 -m venv "$work/venv" && "$work/venv/bin/pip" install -q dbus-next cryptography >"$work/pip.log" 2>&1 || {
    echo "could not install dbus-next and cryptography (see $work/pip.log)"; exit 2; }
  PY="$work/venv/bin/python"
fi

# A private session bus listening on a Unix socket in the work directory.
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
pids+=($!)
for _ in $(seq 50); do [ -s "$work/address" ] && break; sleep 0.1; done
export DBUS_SESSION_BUS_ADDRESS="$(head -n1 "$work/address")"

libdir="${BLEU_SECRETS_LIBDIR:-$(bash "$repo/tools/libdir.sh")}"
sources=("$lib"/src/*.c3)
deps=(--lib bleu_core --lib bleu_rt --lib bleu_service --lib bleu_dbus --lib bleu_objc --lib bleu_win)

failures=0
run_mode() {
  local mode="$1" test_file="$2"
  "$PY" -I "$lib/tests/secret_service_mock.py" "$DBUS_SESSION_BUS_ADDRESS" "$mode" >"$work/mock-$mode.out" 2>"$work/mock-$mode.err" &
  local mock=$!
  pids+=("$mock")
  for _ in $(seq 100); do grep -q READY "$work/mock-$mode.out" 2>/dev/null && break; sleep 0.1; done
  if ! grep -q READY "$work/mock-$mode.out"; then
    echo "FAIL mock did not start in mode $mode (see $work/mock-$mode.err)"; failures=$((failures + 1)); kill "$mock" 2>/dev/null; return
  fi
  echo "== mode $mode: $(basename "$test_file")"
  (cd "$work" && c3c --libdir "$libdir" "${deps[@]}" compile-test "$test_file" --sources "${sources[@]}") >"$work/test-$mode.log" 2>&1
  local status=$?
  grep -E "\[(PASS|FAIL)\]|tests run|Test Result|ERROR|Test failed" "$work/test-$mode.log" | sed 's/^/  /'
  [ $status -eq 0 ] || failures=$((failures + 1))
  kill "$mock" 2>/dev/null
  wait "$mock" 2>/dev/null
}

run_mode normal "$lib/tests/live/live_normal_test.c3"
run_mode no-collection "$lib/tests/live/live_nocollection_test.c3"
run_mode refuse-dh "$lib/tests/live/live_plain_test.c3"
run_mode locked "$lib/tests/live/live_locked_test.c3"
run_mode dismiss "$lib/tests/live/live_dismiss_test.c3"
run_mode hang "$lib/tests/live/live_hang_test.c3"

echo "== modes with failures: $failures"
exit "$failures"
