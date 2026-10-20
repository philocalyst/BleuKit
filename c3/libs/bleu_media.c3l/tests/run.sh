#!/usr/bin/env bash
# Live test for bleu_media on Linux.
#
# Starts a private dbus-daemon on a short socket path (Unix socket names are
# limited to 108 bytes), the python mock (mock_players.py: two fake MPRIS players
# and one that vanishes, plus a control interface), compiles live/main.c3 and runs
# it against that bus. Prints one PASS or FAIL line per check.
#
#   libs/bleu_media.c3l/tests/run.sh
#
# Needs dbus-daemon, c3c, python3. Set BLEU_MEDIA_PYTHON to a python with
# dbus-next; otherwise a venv is created in the work directory (pypi access).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
work="$(mktemp -d /tmp/bleu-media.XXXX)"
pids=()

cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

if [ -n "${BLEU_MEDIA_PYTHON:-}" ]; then
  PYTHON="$BLEU_MEDIA_PYTHON"
else
  python3 -m venv "$work/venv" && "$work/venv/bin/pip" install -q dbus-next >"$work/pip.log" 2>&1 || {
    echo "could not install dbus-next (see $work/pip.log)"; exit 2; }
  PYTHON="$work/venv/bin/python"
fi

# 1. The private bus.
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
echo "bus: $DBUS_SESSION_BUS_ADDRESS"

# 2. The C3 driver (built first, so the mock is not old when the test starts), built against the libraries in this checkout.
libdir="$(bash "$repo/tools/libdir.sh")"
c3c --libdir "$libdir" --lib bleu_core --lib bleu_rt --lib bleu_service --lib bleu_dbus \
  --lib bleu_win --lib bleu_objc --lib bleu_media compile "$here/live/main.c3" -o "$work/live" \
  >"$work/compile.log" 2>&1 || { echo "compile failed:"; cat "$work/compile.log"; exit 2; }

# 3. The mock players.
"$PYTHON" -I "$here/mock_players.py" "$DBUS_SESSION_BUS_ADDRESS" >"$work/mock.out" 2>"$work/mock.err" &
pids+=("$!")
for _ in $(seq 1 200); do grep -q READY "$work/mock.out" 2>/dev/null && break; sleep 0.05; done
grep -q READY "$work/mock.out" || { echo "the mock did not start:"; cat "$work/mock.err"; exit 2; }

# 4. Run it.
timeout 120 "$work/live"
status=$?
if [ "$status" -eq 0 ]; then echo "LIVE RUN OK"; else echo "LIVE RUN FAILED (exit $status)"; cat "$work/mock.err" | tail -20; fi
exit "$status"
