#!/usr/bin/env bash
# Live tests for bleu_windows on Linux: the windows service against the fake
# compositors that bleu_compositor ships (reused by path, not copied).
#
#   libs/bleu_windows.c3l/tests/run.sh     needs python3 and c3c
#
# Each scenario starts one fake, runs tests/live/service_live.c3 with only that
# compositor's environment variables set, and checks the output lines. The
# reconnect scenario kills the Hyprland fake after the first actions, restarts it
# when the driver reports the loss, and expects the service to come back.
set -u
export PYTHONDONTWRITEBYTECODE=1
here="$(cd "$(dirname "$0")" && pwd)"
lib="$(cd "$here/.." && pwd)"
repo="$(cd "$lib/../.." && pwd)"
fakes="$repo/libs/bleu_compositor.c3l/tests"
fixtures="$fakes/fixtures"
work="$(mktemp -d "${TMPDIR:-/tmp}/bleu-windows-live.XXXXXX")"
pids=()
cleanup() { for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null; done; rm -rf "$work"; }
trap cleanup EXIT
fail=0
# The ids the driver acted on, as it printed them: "target=<id> destination=<id>".
target_of() { sed -n 's/^target=\([^ ]*\) .*/\1/p' "$1"; }
dest_of() { sed -n 's/^target=.* destination=\(.*\)$/\1/p' "$1"; }
check() { # check <label> <output file> <fixed string>
  if grep -qF -- "$3" "$2"; then echo "ok    $1: $3"; else echo "FAIL  $1: expected '$3'"; fail=1; fi
}
wait_for() { # wait_for <path>: up to 10 s for a socket file
  for _ in $(seq 200); do [ -e "$1" ] && return 0; sleep 0.05; done
  echo "FAIL  socket $1 never appeared"; fail=1; return 1
}
wait_for_line() { # wait_for_line <file> <fixed string>: up to 30 s
  for _ in $(seq 600); do grep -qF -- "$2" "$1" 2>/dev/null && return 0; sleep 0.05; done
  echo "FAIL  '$2' never appeared in $1"; fail=1; return 1
}

# The driver, compiled once in a private directory (c3c writes out/ and obj/ in the cwd).
mkdir -p "$work/build" && cd "$work/build" || exit 1
libdir="$("$repo/tools/libdir.sh")"
if ! timeout 600 c3c --libdir "$libdir" --lib bleu_core --lib bleu_rt --lib bleu_service \
     --lib bleu_compositor --lib bleu_win --lib bleu_objc --lib bleu_dl --lib bleu_windows \
     compile "$lib/tests/live/service_live.c3" -o "$work/live" >"$work/compile.txt" 2>&1; then
  cat "$work/compile.txt"; rm -rf "$libdir"; exit 1
fi
rm -rf "$libdir"
live="$work/live"
env_base=(env -i PATH="$PATH" HOME="$work" XDG_RUNTIME_DIR="$work/run")
mkdir -p "$work/run"

# --- Hyprland: state, events, actions -------------------------------------
echo "== hyprland"
python3 "$fakes/fake_hyprland.py" "$work/run/hypr/fake" "$fixtures/hyprland" "$work/hypr.log" "$fakes/live/hyprland_events.txt" > "$work/hypr.fake" 2>&1 &
pids+=($!)
wait_for "$work/run/hypr/fake/.socket2.sock"
"${env_base[@]}" HYPRLAND_INSTANCE_SIGNATURE=fake "$live" > "$work/hypr.out" 2>&1; rc=$?
cat "$work/hypr.out"
check hypr-open "$work/hypr.out" "open=ok backend=compositor"
check hypr-first "$work/hypr.out" "first connection=CONNECTED windows=2 workspaces=2 outputs=2 focused=~/src status=none"
check hypr-ev-open "$work/hypr.out" "event=WINDOW_OPENED id=0x55d1c0a53000"
check hypr-ev-focus "$work/hypr.out" "event=FOCUS_CHANGED id="
check hypr-ev-close "$work/hypr.out" "event=WINDOW_CLOSED id=0x55d1c0a4e2b0"
check hypr-now "$work/hypr.out" "now connection=CONNECTED windows=2 workspaces=2 outputs=2 focused=none status=none"
check hypr-focus "$work/hypr.out" "focus_window=ok"
check hypr-close "$work/hypr.out" "close_window=ok"
check hypr-switch "$work/hypr.out" "switch_workspace=ok"
check hypr-move "$work/hypr.out" "move_window=ok"
check hypr-float "$work/hypr.out" "toggle_floating=ok"
check hypr-fullscreen "$work/hypr.out" "toggle_fullscreen=ok"
check hypr-refused-id "$work/hypr.out" "focus_window_not_an_id=failed"
check hypr-minimize "$work/hypr.out" "minimize_window=refused no compositor IPC in this library minimizes a window"
t="$(target_of "$work/hypr.out")"; d="$(dest_of "$work/hypr.out")"
check hypr-log-focus "$work/hypr.log" "j/dispatch focuswindow address:$t"
check hypr-log-close "$work/hypr.log" "j/dispatch closewindow address:$t"
check hypr-log-move "$work/hypr.log" "j/dispatch movetoworkspace $d,address:$t"
check hypr-log-float "$work/hypr.log" "j/dispatch togglefloating address:$t"
check hypr-log-fullscreen "$work/hypr.log" "j/dispatch fullscreen 0"
check hypr-log-workspace "$work/hypr.log" "j/dispatch workspace $d"
[ $rc -eq 0 ] || { echo "FAIL  hyprland driver exit $rc"; fail=1; }
kill "${pids[-1]}" 2>/dev/null; pids=("${pids[@]:0:${#pids[@]}-1}")
rm -rf "$work/run/hypr"

# --- Hyprland: the compositor goes away and comes back ---------------------
echo "== hyprland, compositor restart"
python3 "$fakes/fake_hyprland.py" "$work/run/hypr/fake" "$fixtures/hyprland" "$work/hypr2.log" "$fakes/live/hyprland_events.txt" > "$work/hypr2.fake" 2>&1 &
fake_pid=$!
pids+=($fake_pid)
wait_for "$work/run/hypr/fake/.socket2.sock"
"${env_base[@]}" HYPRLAND_INSTANCE_SIGNATURE=fake "$live" reconnect > "$work/recon.out" 2>&1 &
live_pid=$!
pids+=($live_pid)
wait_for_line "$work/recon.out" "minimize_window=refused"
kill "$fake_pid" 2>/dev/null; wait "$fake_pid" 2>/dev/null
rm -rf "$work/run/hypr"
wait_for_line "$work/recon.out" "runner=restart-compositor"
python3 "$fakes/fake_hyprland.py" "$work/run/hypr/fake" "$fixtures/hyprland" "$work/hypr3.log" "$fakes/live/hyprland_events.txt" > "$work/hypr3.fake" 2>&1 &
pids+=($!)
wait "$live_pid"; rc=$?
cat "$work/recon.out"
check recon-lost "$work/recon.out" "lost connection=DISCONNECTED windows=0 workspaces=0 outputs=0 focused=none status="
check recon-down-action "$work/recon.out" "action_while_down=failed"
check recon-back "$work/recon.out" "back connection=CONNECTED windows=2 workspaces=2 outputs=2 focused=~/src status=none"
[ $rc -eq 0 ] || { echo "FAIL  reconnect driver exit $rc"; fail=1; }
kill "${pids[-1]}" 2>/dev/null
rm -rf "$work/run/hypr"

# --- no compositor at all -------------------------------------------------
echo "== no compositor"
"${env_base[@]}" "$live" > "$work/none.out" 2>&1; rc=$?
cat "$work/none.out"
check none-open "$work/none.out" "open=failed no windows backend works here"
[ $rc -eq 0 ] || { echo "FAIL  no-compositor driver exit $rc"; fail=1; }

# --- a compositor variable naming a socket nobody listens on --------------
echo "== stale socket"
"${env_base[@]}" SWAYSOCK="$work/run/gone.sock" "$live" > "$work/stale.out" 2>&1; rc=$?
cat "$work/stale.out"
check stale-first "$work/stale.out" "first connection=DISCONNECTED windows=0 workspaces=0 outputs=0 focused=none status="
check stale-none "$work/stale.out" "no-targets"
[ $rc -eq 0 ] || { echo "FAIL  stale-socket driver exit $rc"; fail=1; }

# --- sway -----------------------------------------------------------------
echo "== sway"
python3 "$fakes/fake_sway.py" "$work/run/sway.sock" "$fixtures/sway" "$work/sway.log" "$fakes/live/sway_events.tsv" > "$work/sway.fake" 2>&1 &
pids+=($!)
wait_for "$work/run/sway.sock"
"${env_base[@]}" SWAYSOCK="$work/run/sway.sock" "$live" > "$work/sway.out" 2>&1; rc=$?
cat "$work/sway.out"
check sway-first "$work/sway.out" "first connection=CONNECTED windows=3 workspaces=2 outputs=1 focused=Browser status=none"
check sway-focus "$work/sway.out" "focus_window=ok"
t="$(target_of "$work/sway.out")"
check sway-log-focus "$work/sway.log" "[con_id=$t] focus"
check sway-log-float "$work/sway.log" "[con_id=$t] floating toggle"
[ $rc -eq 0 ] || { echo "FAIL  sway driver exit $rc"; fail=1; }
kill "${pids[-1]}" 2>/dev/null; pids=("${pids[@]:0:${#pids[@]}-1}")
rm -f "$work/run/sway.sock"

# --- i3 (the same tree protocol as sway, and no layouts) -----------------
echo "== i3"
python3 "$fakes/fake_sway.py" "$work/run/i3.sock" "$fixtures/sway" "$work/i3.log" "$fakes/live/sway_events.tsv" i3 > "$work/i3.fake" 2>&1 &
pids+=($!)
wait_for "$work/run/i3.sock"
"${env_base[@]}" I3SOCK="$work/run/i3.sock" "$live" > "$work/i3.out" 2>&1; rc=$?
cat "$work/i3.out"
check i3-first "$work/i3.out" "first connection=CONNECTED windows=3 workspaces=2 outputs=1 focused=Browser status=none"
check i3-focus "$work/i3.out" "focus_window=ok"
t="$(target_of "$work/i3.out")"
check i3-log-focus "$work/i3.log" "[con_id=$t] focus"
[ $rc -eq 0 ] || { echo "FAIL  i3 driver exit $rc"; fail=1; }
kill "${pids[-1]}" 2>/dev/null; pids=("${pids[@]:0:${#pids[@]}-1}")
rm -f "$work/run/i3.sock"

# --- niri -----------------------------------------------------------------
echo "== niri"
python3 "$fakes/fake_niri.py" "$work/run/niri.sock" "$fixtures/niri" "$work/niri.log" "$fixtures/niri/events.jsonl" > "$work/niri.fake" 2>&1 &
pids+=($!)
wait_for "$work/run/niri.sock"
"${env_base[@]}" NIRI_SOCKET="$work/run/niri.sock" "$live" > "$work/niri.out" 2>&1; rc=$?
cat "$work/niri.out"
check niri-first "$work/niri.out" "first connection=CONNECTED windows=2 workspaces=3 outputs=2 focused=~/src - foot status=none"
check niri-focus "$work/niri.out" "focus_window=ok"
t="$(target_of "$work/niri.out")"
check niri-log-focus "$work/niri.log" "{\"Action\":{\"FocusWindow\":{\"id\":$t}}}"
[ $rc -eq 0 ] || { echo "FAIL  niri driver exit $rc"; fail=1; }

echo
if [ $fail -eq 0 ]; then echo "windows live: all checks passed"; else echo "windows live: FAILURES"; fi
exit $fail
