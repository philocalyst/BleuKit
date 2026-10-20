#!/usr/bin/env bash
# Live test of the configured-layout backend (org.freedesktop.locale1) of bleu_input against a mock service
# on a private system bus.
#
#   libs/bleu_input.c3l/tests/run_locale1.sh
#
# 1. starts a private dbus-daemon and exports DBUS_SYSTEM_BUS_ADDRESS to it;
# 2. starts mock_locale1.py (python-dbus-next), which owns org.freedesktop.locale1 there, with layout=us,de;
# 3. runs live/input_live.c3 with no compositor variables (so the backend chosen is locale1); the script
#    changes the mock's layout to ru during the run, which must arrive as PropertiesChanged;
# 4. stops the mock and runs the driver again: the backend must refuse, because the name has no owner.
#
# Needs dbus-daemon, c3c and python3. Set BLEU_INPUT_PYTHON to a python that has dbus-next; otherwise a
# virtual environment is created in the work directory (needs pypi access).
set -u
export PYTHONDONTWRITEBYTECODE=1
here="$(cd "$(dirname "$0")" && pwd)"
lib="$(cd "$here/.." && pwd)"
repo="$(cd "$lib/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/bleu-input-loc.XXXXXX")"
pids=()
cleanup() {
  set +e
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT
fail=0
check() { # check <label> <file> <fixed string>
  if grep -qF -- "$3" "$2"; then echo "ok    $1: $3"; else echo "FAIL  $1: expected '$3'"; fail=1; fi
}

if [ -n "${BLEU_INPUT_PYTHON:-}" ]; then
  PYTHON="$BLEU_INPUT_PYTHON"
else
  python3 -m venv "$work/venv" && "$work/venv/bin/pip" install -q dbus-next >"$work/pip.log" 2>&1 || {
    echo "could not install dbus-next (see $work/pip.log)"; exit 2; }
  PYTHON="$work/venv/bin/python"
fi

# A session-style private bus; the client reaches it through DBUS_SYSTEM_BUS_ADDRESS.
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
DBUS_SYSTEM_BUS_ADDRESS="$(head -n1 "$work/address")"
export DBUS_SYSTEM_BUS_ADDRESS

# The driver, compiled once in a private directory.
mkdir -p "$work/build" && cd "$work/build" || exit 1
libdir="$("$repo/tools/libdir.sh")"
if ! timeout 600 c3c --libdir "$libdir" --lib bleu_core --lib bleu_rt --lib bleu_service --lib bleu_compositor --lib bleu_dbus --lib bleu_objc --lib bleu_win --lib bleu_input compile "$lib/tests/live/input_live.c3" -o "$work/live" >"$work/compile.txt" 2>&1; then
  cat "$work/compile.txt"; rm -rf "$libdir"; exit 1
fi
rm -rf "$libdir"

start_mock() {
  BLEU_LOCALE1_CONTROL="$work/control" "$PYTHON" -I "$here/mock_locale1.py" >"$work/mock.out" 2>"$work/mock.err" &
  MOCK_PID=$!
  pids+=("$MOCK_PID")
  for _ in $(seq 1 200); do grep -q READY "$work/mock.out" 2>/dev/null && return 0; sleep 0.05; done
  echo "the mock did not start:"; cat "$work/mock.err"; exit 2
}

echo "layout=us,de variant=,nodeadkeys" > "$work/control"
start_mock
echo "== locale1: configured layouts, a change on the bus, and a refused switch"
# Change the configured layout while the driver is watching: the mock emits PropertiesChanged.
( sleep 0.8; echo "layout=ru variant=" > "$work/control" ) &
pids+=("$!")
env -i PATH="$PATH" HOME="$work" DBUS_SYSTEM_BUS_ADDRESS="$DBUS_SYSTEM_BUS_ADDRESS" INPUT_SWITCH_TO=de "$work/live" > "$work/loc.out" 2>&1; rc=$?
cat "$work/loc.out"
check open "$work/loc.out" "open=ok backend=locale1"
check cap-list "$work/loc.out" "cap LIST=yes reason=8"
check cap-current "$work/loc.out" "cap CURRENT=no reason=2"
check cap-switch "$work/loc.out" "cap SWITCH=no reason=2"
check cap-events "$work/loc.out" "cap EVENTS=yes reason=0"
check count "$work/loc.out" "layouts=2 can_switch=no"
check layout0 "$work/loc.out" "layout index=0 id=us name=English (US) short=US language=en-US variant="
check layout1 "$work/loc.out" "layout index=1 id=de(nodeadkeys) name=German (nodeadkeys) short=DE language=de-DE variant=nodeadkeys"
check no-current "$work/loc.out" "current=none"
check refuse-unknown "$work/loc.out" "switch_unknown=refused UNSUPPORTED"
check refuse-switch "$work/loc.out" "switch=refused UNSUPPORTED"
check changed "$work/loc.out" "event kind=0 layout="
check changed-layout "$work/loc.out" "layout index=0 id=ru name=Russian short=RU language=ru-RU variant="
[ $rc -eq 0 ] || { echo "FAIL  locale1 driver exit $rc"; fail=1; }
kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null
pids=("${pids[@]/$MOCK_PID/}")

echo "== locale1: no service on the bus"
env -i PATH="$PATH" HOME="$work" DBUS_SYSTEM_BUS_ADDRESS="$DBUS_SYSTEM_BUS_ADDRESS" "$work/live" > "$work/absent.out" 2>&1; rc=$?
cat "$work/absent.out"
check absent-open "$work/absent.out" "open=failed"
[ $rc -eq 1 ] || { echo "FAIL  absent driver exit $rc, expected 1"; fail=1; }

if [ "$fail" -eq 0 ]; then echo "locale1: passed"; else echo "locale1: FAILED"; fi
exit "$fail"
