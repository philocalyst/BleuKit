#!/usr/bin/env bash
# Live test of the compositor backend of bleu_input against the fake compositors of bleu_compositor.
#
#   libs/bleu_input.c3l/tests/run_compositor.sh     # needs python3 and c3c
#
# For each compositor it starts the fake (a Unix socket server speaking that IPC, answering from the
# bleu_compositor fixtures), runs live/input_live.c3 with only that compositor's environment variables set,
# and checks the lines the driver printed and the requests the fake received. Nothing is installed.
set -u
export PYTHONDONTWRITEBYTECODE=1
here="$(cd "$(dirname "$0")" && pwd)"
lib="$(cd "$here/.." && pwd)"
repo="$(cd "$lib/../.." && pwd)"
comp="$repo/libs/bleu_compositor.c3l"
work="$(mktemp -d "${TMPDIR:-/tmp}/bleu-input-comp.XXXXXX")"
pids=()
cleanup() { for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null; done; rm -rf "$work"; }
trap cleanup EXIT
fail=0
check() { # check <label> <file> <fixed string>
  if grep -qF -- "$3" "$2"; then echo "ok    $1: $3"; else echo "FAIL  $1: expected '$3'"; fail=1; fi
}
wait_for() { # wait_for <path>: up to 10 s for a socket
  for _ in $(seq 200); do [ -e "$1" ] && return 0; sleep 0.05; done
  echo "FAIL  socket $1 never appeared"; fail=1; return 1
}

# The driver, compiled once in a private directory (c3c writes out/ and obj/ in the cwd).
mkdir -p "$work/build" && cd "$work/build" || exit 1
libdir="$("$repo/tools/libdir.sh")"
if ! timeout 600 c3c --libdir "$libdir" --lib bleu_core --lib bleu_rt --lib bleu_service --lib bleu_compositor --lib bleu_dbus --lib bleu_objc --lib bleu_win --lib bleu_input compile "$lib/tests/live/input_live.c3" -o "$work/live" >"$work/compile.txt" 2>&1; then
  cat "$work/compile.txt"; rm -rf "$libdir"; exit 1
fi
rm -rf "$libdir"
live="$work/live"
fixtures="$comp/tests/fixtures"
env_base=(env -i PATH="$PATH" HOME="$work" XDG_RUNTIME_DIR="$work/run")
mkdir -p "$work/run"

# --- sway: the layout list, events, and the switch command --------------------
echo "== sway"
python3 "$comp/tests/fake_sway.py" "$work/run/sway.sock" "$fixtures/sway" "$work/sway.log" "$comp/tests/live/sway_events.tsv" > "$work/sway.fake" 2>&1 &
pids+=($!)
wait_for "$work/run/sway.sock"
"${env_base[@]}" SWAYSOCK="$work/run/sway.sock" INPUT_SWITCH_TO=us "$live" > "$work/sway.out" 2>&1; rc=$?
cat "$work/sway.out"
check sway-backend "$work/sway.out" "open=ok backend=compositor"
check sway-cap-switch "$work/sway.out" "cap SWITCH=yes reason=0"
check sway-layout0 "$work/sway.out" "layout index=0 id=us name=English (US) short=US language=en-US variant="
check sway-layout1 "$work/sway.out" "layout index=1 id=German (Germany) name=German (Germany) short=GER language= variant="
check sway-can-switch "$work/sway.out" "layouts=2 can_switch=yes"
check sway-refuse-unknown "$work/sway.out" "switch_unknown=refused NOT_FOUND"
check sway-switch "$work/sway.out" "switch=done outcome=ACKNOWLEDGED"
check sway-event "$work/sway.out" "event kind=1 layout=German (Germany)"
check sway-log-switch "$work/sway.log" "input type:keyboard xkb_switch_layout 0"
[ $rc -eq 0 ] || { echo "FAIL  sway driver exit $rc"; fail=1; }
kill "${pids[-1]}" 2>/dev/null; pids=("${pids[@]:0:${#pids[@]}-1}")
rm -f "$work/run/sway.sock"

# --- niri: the layout list, the event and the Index action -------------------
echo "== niri"
python3 "$comp/tests/fake_niri.py" "$work/run/niri.sock" "$fixtures/niri" "$work/niri.log" "$comp/tests/fixtures/niri/events.jsonl" > "$work/niri.fake" 2>&1 &
pids+=($!)
wait_for "$work/run/niri.sock"
"${env_base[@]}" NIRI_SOCKET="$work/run/niri.sock" INPUT_SWITCH_TO=ru "$live" > "$work/niri.out" 2>&1; rc=$?
cat "$work/niri.out"
check niri-backend "$work/niri.out" "open=ok backend=compositor"
check niri-layout0 "$work/niri.out" "layout index=0 id=us name=English (US) short=US language=en-US variant="
check niri-layout1 "$work/niri.out" "layout index=1 id=ru name=Russian short=RU language=ru-RU variant="
check niri-current "$work/niri.out" "current=0"
check niri-switch "$work/niri.out" "switch=done outcome=ACKNOWLEDGED"
check niri-log-switch "$work/niri.log" '{"Action":{"SwitchLayout":{"layout":{"Index":1}}}}'
[ $rc -eq 0 ] || { echo "FAIL  niri driver exit $rc"; fail=1; }
kill "${pids[-1]}" 2>/dev/null; pids=("${pids[@]:0:${#pids[@]}-1}")
rm -f "$work/run/niri.sock"

# --- Hyprland: one layout is known, so switching is refused and nothing is sent -
echo "== hyprland"
python3 "$comp/tests/fake_hyprland.py" "$work/run/hypr/fake" "$fixtures/hyprland" "$work/hypr.log" "$comp/tests/live/hyprland_events.txt" > "$work/hypr.fake" 2>&1 &
pids+=($!)
wait_for "$work/run/hypr/fake/.socket2.sock"
"${env_base[@]}" HYPRLAND_INSTANCE_SIGNATURE=fake INPUT_SWITCH_TO=de "$live" > "$work/hypr.out" 2>&1; rc=$?
cat "$work/hypr.out"
check hypr-backend "$work/hypr.out" "open=ok backend=compositor"
check hypr-cap-list "$work/hypr.out" "cap LIST=yes reason=8"
check hypr-cap-switch "$work/hypr.out" "cap SWITCH=no reason=2"
check hypr-layout0 "$work/hypr.out" "layout index=0 id=de name=German short=DE language=de-DE variant="
check hypr-current "$work/hypr.out" "current=0"
check hypr-refused "$work/hypr.out" "switch=refused UNSUPPORTED"
# The fake writes a request to its log only when it receives one: a missing log means nothing was sent.
if [ -e "$work/hypr.log" ] && grep -qF -- "switchxkblayout" "$work/hypr.log"; then
  echo "FAIL  hypr-no-request: a switchxkblayout reached the fake"; fail=1
else
  echo "ok    hypr-no-request: no switchxkblayout reached the fake"
fi
[ $rc -eq 0 ] || { echo "FAIL  hyprland driver exit $rc"; fail=1; }

if [ "$fail" -eq 0 ]; then echo "compositor: passed"; else echo "compositor: FAILED"; fi
exit "$fail"
