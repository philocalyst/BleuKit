#!/usr/bin/env bash
# Live test of the bleu_power Linux mechanism.
#
# Starts a private dbus-daemon, the python-dbus-next mock of logind and
# power-profiles-daemon (integration/mock_daemons.py), and runs the C3 client
# against them in three daemon modes: modern (both interfaces), legacy (only the
# legacy profile interface) and none (no profile daemon). Nothing destructive
# runs: the mock records every action and answers it.
#
#   libs/bleu_power.c3l/tests/run.sh
#
# Needs dbus-daemon, c3c and python3. Set BLEU_POWER_PYTHON to a python that has
# dbus-next; otherwise a virtual environment is created in the work directory
# and dbus-next is installed into it (network access to pypi.org needed).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
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

python_with_dbus_next() {
  if [ -n "${BLEU_POWER_PYTHON:-}" ]; then
    echo "$BLEU_POWER_PYTHON"
    return
  fi
  python3 -m venv "$work/venv" && "$work/venv/bin/pip" install -q dbus-next >"$work/pip.log" 2>&1 || {
    say "could not install dbus-next (see $work/pip.log)"; exit 2; }
  echo "$work/venv/bin/python"
}

# Starts a bus on a filesystem socket under $work and points the system bus
# address at it. Sets BUS_PID.
start_bus() {
  local conf="$work/bus.conf"
  cat >"$conf" <<XML
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>system</type>
  <listen>unix:path=$work/bus-socket</listen>
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
  DBUS_SYSTEM_BUS_ADDRESS="$(head -n1 "$work/address")"
  export DBUS_SYSTEM_BUS_ADDRESS
}

# Starts the mock with the given profile daemon mode and waits for READY.
start_mock() {
  "$PYTHON" -I "$here/integration/mock_daemons.py" "$1" >"$work/mock.out" 2>"$work/mock.err" &
  MOCK_PID=$!
  pids+=("$MOCK_PID")
  for _ in $(seq 1 200); do
    grep -q READY "$work/mock.out" 2>/dev/null && return 0
    sleep 0.05
  done
  say "the mock did not start:"; cat "$work/mock.err"; exit 2
}

PYTHON="$(python_with_dbus_next)"
sources=("$here"/../src/*.c3)
libdir="$(bash "$repo/tools/libdir.sh")"
c3c --libdir "$libdir" --lib bleu_core --lib bleu_rt --lib bleu_service --lib bleu_dbus \
  --lib bleu_objc --lib bleu_win --lib bleu_power compile "$here/integration/main.c3" \
  --sources "${sources[@]}" -o "$work/integration" >"$work/compile.log" 2>&1 || {
  say "compile failed"; cat "$work/compile.log"; exit 2; }

for mode in modern legacy none; do
  say "== mode: $mode"
  start_bus
  start_mock "$mode"
  timeout 180 "$work/integration" "$mode" >"$work/suite.out" 2>&1
  status=$?
  cat "$work/suite.out"
  say "exit status: $status"
  [ "$status" -eq 0 ] || failed=1
  kill "$MOCK_PID" "$BUS_PID" 2>/dev/null
  wait "$MOCK_PID" "$BUS_PID" 2>/dev/null
done

if [ "$failed" -eq 0 ]; then say "POWER INTEGRATION OK"; else say "POWER INTEGRATION FAILED"; fi
exit "$failed"
