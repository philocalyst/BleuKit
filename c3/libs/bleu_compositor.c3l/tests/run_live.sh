#!/usr/bin/env bash
# Live tests: run the C3 client against the fake compositors in tests/ and check
# what it reported and what the fakes received.
#
#   tests/run_live.sh        from anywhere; needs python3 and c3c
#
# Each scenario starts one fake (a Unix socket server speaking that IPC), runs
# tests/live/live.c3 with only that compositor's environment variables set, and
# checks the output lines and the request log. Nothing is installed; the fakes
# answer from tests/fixtures.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
lib="$(cd "$here/.." && pwd)"
repo="$(cd "$lib/../.." && pwd)"
work="$(mktemp -d /tmp/bleu-live.XXXXXX)"
pids=()
cleanup() { for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null; done; rm -rf "$work"; }
trap cleanup EXIT
fail=0
check() { # check <label> <output file> <fixed string>
  if grep -qF -- "$3" "$2"; then echo "ok    $1: $3"; else echo "FAIL  $1: expected '$3'"; fail=1; fi
}
absent() { # absent <label> <file> <fixed string>
  if grep -qF -- "$3" "$2"; then echo "FAIL  $1: unexpected '$3'"; fail=1; else echo "ok    $1: no '$3'"; fi
}
wait_for() { # wait_for <path>: up to 10 s for a socket file
  for _ in $(seq 200); do [ -e "$1" ] && return 0; sleep 0.05; done
  echo "FAIL  socket $1 never appeared"; fail=1; return 1
}

# The driver, compiled once in a private directory (c3c writes out/ and obj/ in the cwd).
mkdir -p "$work/build" && cd "$work/build" || exit 1
libdir="$("$repo/tools/libdir.sh")"
if ! c3c --libdir "$libdir" --lib bleu_core --lib bleu_rt --lib bleu_compositor compile "$lib/tests/live/live.c3" -o "$work/live" >"$work/compile.txt" 2>&1; then
  cat "$work/compile.txt"; rm -rf "$libdir"; exit 1
fi
rm -rf "$libdir"
fixtures="$lib/tests/fixtures"
live="$work/live"
env_base=(env -i PATH="$PATH" HOME="$work" XDG_RUNTIME_DIR="$work/run")
mkdir -p "$work/run"

# --- Hyprland -------------------------------------------------------------
echo "== hyprland"
python3 "$here/fake_hyprland.py" "$work/run/hypr/fake" "$fixtures/hyprland" "$work/hypr.log" "$lib/tests/live/hyprland_events.txt" &
pids+=($!)
wait_for "$work/run/hypr/fake/.socket.sock"; wait_for "$work/run/hypr/fake/.socket2.sock"
"${env_base[@]}" HYPRLAND_INSTANCE_SIGNATURE=fake "$live" > "$work/hypr.out" 2>&1; rc=$?
cat "$work/hypr.out"
check hypr-detect "$work/hypr.out" "detect kind=HYPRLAND reason=HYPRLAND_INSTANCE_SIGNATURE is set"
check hypr-snapshot "$work/hypr.out" "snapshot windows=2 workspaces=2 outputs=2 focused=foot layout=German"
check hypr-events "$work/hypr.out" "after windows=2 workspaces=2 outputs=2 focused=none layout=English (US)"
check hypr-clone "$work/hypr.out" "clone windows=2"
check hypr-focus "$work/hypr.out" "focus_window=ok"
check hypr-refused-id "$work/hypr.out" "focus_window_not_an_id=failed"
check hypr-log-focus "$work/hypr.log" "j/dispatch focuswindow address:0x55d1c0a4e2b0"
check hypr-log-workspace "$work/hypr.log" "j/dispatch workspace 2"
check hypr-log-move "$work/hypr.log" "j/dispatch movetoworkspace 2,address:0x55d1c0a4e2b0"
check hypr-log-layout "$work/hypr.log" "switchxkblayout main-keyboard 1"
check hypr-log-float "$work/hypr.log" "j/dispatch togglefloating address:0x55d1c0a4e2b0"
check hypr-log-fullscreen "$work/hypr.log" "j/dispatch fullscreen 0"
check hypr-log-close "$work/hypr.log" "j/dispatch closewindow address:0x55d1c0a4e2b0"
[ $rc -eq 0 ] || { echo "FAIL  hyprland driver exit $rc"; fail=1; }
kill "${pids[-1]}" 2>/dev/null; pids=("${pids[@]:0:${#pids[@]}-1}")
rm -rf "$work/run/hypr"

# --- Hyprland with a malformed event line -----------------------------------
echo "== hyprland, malformed event"
python3 "$here/fake_hyprland.py" "$work/run/hypr/fake" "$fixtures/hyprland" "$work/hypr2.log" "$lib/tests/live/hyprland_events.txt" bad &
pids+=($!)
wait_for "$work/run/hypr/fake/.socket2.sock"
"${env_base[@]}" HYPRLAND_INSTANCE_SIGNATURE=fake "$live" > "$work/hypr2.out" 2>&1; rc=$?
check hypr-bad-line "$work/hypr2.out" "read_events=failed hyprland event has no '>>'"
[ $rc -eq 2 ] || { echo "FAIL  malformed event exit $rc, expected 2"; fail=1; }
kill "${pids[-1]}" 2>/dev/null; pids=("${pids[@]:0:${#pids[@]}-1}")
rm -rf "$work/run/hypr"

# --- sway -----------------------------------------------------------------
echo "== sway"
python3 "$here/fake_sway.py" "$work/run/sway.sock" "$fixtures/sway" "$work/sway.log" "$lib/tests/live/sway_events.tsv" &
pids+=($!)
wait_for "$work/run/sway.sock"
"${env_base[@]}" SWAYSOCK="$work/run/sway.sock" "$live" > "$work/sway.out" 2>&1; rc=$?
cat "$work/sway.out"
check sway-detect "$work/sway.out" "detect kind=SWAY reason=SWAYSOCK is set"
check sway-snapshot "$work/sway.out" "snapshot windows=3 workspaces=2 outputs=1 focused=Browser layout=English (US)"
check sway-events "$work/sway.out" "after windows=2 workspaces=2 outputs=1 focused=Browser layout=German (Germany)"
check sway-focus "$work/sway.out" "focus_window=ok"
check sway-bad-id "$work/sway.out" "focus_window_not_an_id=failed"
check sway-log-focus "$work/sway.log" '[con_id=11] focus'
check sway-log-workspace "$work/sway.log" 'workspace "2:web"'
check sway-log-move "$work/sway.log" '[con_id=11] move container to workspace "2:web"'
check sway-log-layout "$work/sway.log" 'input type:keyboard xkb_switch_layout 1'
check sway-log-float "$work/sway.log" '[con_id=11] floating toggle'
check sway-log-fullscreen "$work/sway.log" '[con_id=11] fullscreen toggle'
check sway-log-kill "$work/sway.log" '[con_id=11] kill'
[ $rc -eq 0 ] || { echo "FAIL  sway driver exit $rc"; fail=1; }
kill "${pids[-1]}" 2>/dev/null; pids=("${pids[@]:0:${#pids[@]}-1}")
rm -f "$work/run/sway.sock"

# --- i3 (no input events, no layouts) -------------------------------------
echo "== i3"
python3 "$here/fake_sway.py" "$work/run/i3.sock" "$fixtures/sway" "$work/i3.log" "$lib/tests/live/sway_events.tsv" i3 &
pids+=($!)
wait_for "$work/run/i3.sock"
"${env_base[@]}" I3SOCK="$work/run/i3.sock" "$live" > "$work/i3.out" 2>&1; rc=$?
cat "$work/i3.out"
check i3-detect "$work/i3.out" "detect kind=I3 reason=I3SOCK is set"
check i3-snapshot "$work/i3.out" "snapshot windows=3 workspaces=2 outputs=1 focused=Browser layout=none"
check i3-layout "$work/i3.out" "set_layout=failed"
absent i3-no-input "$work/i3.log" "xkb_switch_layout"
[ $rc -eq 0 ] || { echo "FAIL  i3 driver exit $rc"; fail=1; }
kill "${pids[-1]}" 2>/dev/null; pids=("${pids[@]:0:${#pids[@]}-1}")
rm -f "$work/run/i3.sock"

# --- niri -----------------------------------------------------------------
echo "== niri"
python3 "$here/fake_niri.py" "$work/run/niri.sock" "$fixtures/niri" "$work/niri.log" "$fixtures/niri/events.jsonl" &
pids+=($!)
wait_for "$work/run/niri.sock"
"${env_base[@]}" NIRI_SOCKET="$work/run/niri.sock" "$live" > "$work/niri.out" 2>&1; rc=$?
cat "$work/niri.out"
check niri-detect "$work/niri.out" "detect kind=NIRI reason=NIRI_SOCKET is set"
check niri-snapshot "$work/niri.out" "snapshot windows=2 workspaces=3 outputs=2 focused=~/src - foot layout=English (US)"
check niri-events "$work/niri.out" "after windows=2 workspaces=3 outputs=2 focused= layout=Russian"
check niri-focus "$work/niri.out" "focus_window=ok"
check niri-refused "$work/niri.out" "focus_window_refused=failed niri refused action: window 99 not found"
check niri-log-focus "$work/niri.log" '{"Action":{"FocusWindow":{"id":7}}}'
check niri-log-workspace "$work/niri.log" '{"Action":{"FocusWorkspace":{"reference":{"Id":3}}}}'
check niri-log-move "$work/niri.log" '{"Action":{"MoveWindowToWorkspace":{"window_id":7,"reference":{"Id":3},"focus":false}}}'
check niri-log-layout "$work/niri.log" '{"Action":{"SwitchLayout":{"layout":{"Index":1}}}}'
check niri-log-float "$work/niri.log" '{"Action":{"ToggleWindowFloating":{"id":7}}}'
check niri-log-fullscreen "$work/niri.log" '{"Action":{"FullscreenWindow":{"id":7}}}'
check niri-log-close "$work/niri.log" '{"Action":{"CloseWindow":{"id":7}}}'
[ $rc -eq 0 ] || { echo "FAIL  niri driver exit $rc"; fail=1; }

echo
if [ $fail -eq 0 ]; then echo "live: all checks passed"; else echo "live: FAILURES"; fi
exit $fail
