#!/usr/bin/env bash
# Runs the whole test surface of the repository and prints one table: PASS, FAIL,
# TIMEOUT or NO-TESTS per item, then the counts. Exits nonzero if any item FAILs or
# TIMEOUTs.
#
#   tools/test-all.sh                  everything: unit, live, check
#   tools/test-all.sh unit             only the unit tests of libs/*.c3l
#   tools/test-all.sh unit bleu_rt     unit tests of the named libraries only
#   tools/test-all.sh live             only the live scripts
#   tools/test-all.sh check            only the type-checks
#   KEEP_LOGS=1 tools/test-all.sh      keep the work directory with every log
#
# Items:
#   unit:<lib>     c3c compile-test of libs/<lib>.c3l/src/*.c3 (plus tests/unit/*.c3 where a
#                  library has them), linked with the library closure from its manifest.
#                  c3c runs every test in the binary, so a failing dependency test fails the
#                  item too; the detail line says how many of the failures are the library's own.
#   live:<name>    libs/*/tests/run.sh; the other live entry points listed in EXTRA_LIVE;
#                  apps/*/tests/run.sh; and the C ABI (tools/capi: check, build, tests/run.sh).
#   check:libs     tools/check.sh: every library on all six targets, type-check only.
#   check:<app>    the application on all six targets: tools/check-apps.sh <app> when the app has
#                  project.json (dmsd), tools/check-app.sh <app> when it has manifest.json (bleud, bleuctl).
#
# Status: PASS (exit 0), FAIL (nonzero exit), TIMEOUT (killed by `timeout`),
# NO-TESTS (a library whose build succeeded but that has no @test in its sources; not a failure).
#
# Environment:
#   TEST_TIMEOUT   seconds per unit item (default 600)
#   LIVE_TIMEOUT   seconds per live item (default 900)
#   CHECK_TIMEOUT  seconds per check item (default 1800)
#   KEEP_LOGS=1    keep the work directory (logs) and print its path
#
# Everything c3c and the scripts write goes into a private work directory under
# ${TMPDIR:-/tmp}, never into libs/. The one exception is tools/capi/build.sh, which
# regenerates include/bleu; it runs in --check mode first and the item fails if the
# headers are stale, so the regeneration only rewrites identical content.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
group="${1:-all}"
[ "$#" -gt 0 ] && shift
only=("$@")
case "$group" in
  all|unit|live|check) ;;
  *) echo "usage: tools/test-all.sh [all|unit|live|check] [library ...]" >&2; exit 2;;
esac
TEST_TIMEOUT="${TEST_TIMEOUT:-600}"
LIVE_TIMEOUT="${LIVE_TIMEOUT:-900}"
CHECK_TIMEOUT="${CHECK_TIMEOUT:-1800}"
command -v timeout >/dev/null 2>&1 || { echo "test-all: needs timeout(1)" >&2; exit 2; }

# Live entry points that are not named tests/run.sh but are live tests of a library.
EXTRA_LIVE=(
  libs/bleu_compositor.c3l/tests/run_live.sh
  libs/bleu_dbus.c3l/tests/integration.sh
  libs/bleu_input.c3l/tests/run_compositor.sh
  libs/bleu_input.c3l/tests/run_locale1.sh
)

work="$(mktemp -d "${TMPDIR:-/tmp}/bleu-test-all.XXXXXX")"
libdir="$("$here/tools/libdir.sh")"
cleanup() {
  rm -rf "$libdir"
  [ -n "${KEEP_LOGS:-}" ] || rm -rf "$work"
}
trap cleanup EXIT

ST=(); NM=(); DT=(); LG=()
record() { ST+=("$1"); NM+=("$2"); DT+=("$3"); LG+=("$4"); }

# status_of <exit code>: PASS, TIMEOUT (124 from timeout, 137 after its kill) or FAIL.
status_of() {
  case "$1" in
    0) echo PASS;;
    124|137) echo TIMEOUT;;
    *) echo FAIL;;
  esac
}

# run_item <seconds> <cwd> <log> <command...>: runs the command under timeout with its
# output in <log>; the exit code is left in RC.
run_item() {
  local secs="$1" cwd="$2" log="$3"; shift 3
  RC=0
  timeout -k 15 "$secs" bash -c 'cd "$1" && shift && exec "$@"' _ "$cwd" "$@" >"$log" 2>&1 || RC=$?
}

# The library closure of a manifest's dependencies, space separated, without the library itself.
CLOSURE_PY='
import json, os, sys
libs, name = sys.argv[1], sys.argv[2]
seen = []
def visit(n):
    m = os.path.join(libs, n + ".c3l", "manifest.json")
    if n in seen or not os.path.exists(m):
        return
    seen.append(n)
    for d in json.load(open(m)).get("dependencies", []):
        visit(d)
for d in json.load(open(os.path.join(libs, name + ".c3l", "manifest.json"))).get("dependencies", []):
    visit(d)
print(" ".join(seen))
'

# Summarises a compile-test log: the library's own tests (module prefix of each @test file)
# against the whole binary, and the names of any failing tests.
PARSE_UNIT_PY='
import re, sys
log_path, files = sys.argv[1], sys.argv[2:]
prefixes, has_tests = [], False
for f in files:
    try:
        text = open(f, errors="replace").read()
    except OSError:
        continue
    if "@test" not in text:
        continue
    has_tests = True
    m = re.search(r"^module\s+([\w:]+)", text, re.M)
    if m:
        prefixes.append(m.group(1) + "::")
text = open(log_path, errors="replace").read()
rows = re.findall(r"^Testing (\S+) \.+ \[(\w+)\]", text, re.M)
own = [(n, s) for n, s in rows if any(n.startswith(p) for p in prefixes)]
own_pass = sum(1 for _, s in own if s == "PASS")
own_fail = [n for n, s in own if s not in ("PASS", "SKIP")]
m = re.search(r"Test Result: \w+: (\d+) passed, (\d+) failed, (\d+) skipped", text)
bin_pass, bin_fail = (m.group(1), m.group(2)) if m else ("?", "?")
print(f"own {own_pass} pass / {len(own_fail)} fail; binary {bin_pass} pass / {bin_fail} fail; has_tests={int(has_tests)}")
for n in own_fail[:5]:
    print(f"own-fail {n}")
'

# ---- unit ---------------------------------------------------------------------------
unit_item() {
  local lib="$1" dir="$here/libs/$1.c3l" name="unit:$1" log="$work/unit-$1.log"
  local deps d largs=() srcs=() f
  deps="$(python3 -I -c "$CLOSURE_PY" "$here/libs" "$lib")" || { record FAIL "$name" "closure of manifest failed" "$log"; return; }
  for d in $deps; do largs+=(--lib "$d"); done
  # The manifests say "src/**": sources in subdirectories (bleu_wl's src/proto) count too.
  mapfile -t srcs < <(find "$dir/src" -name '*.c3' | sort)
  if [ -d "$dir/tests/unit" ]; then
    mapfile -t extra < <(find "$dir/tests/unit" -name '*.c3' | sort)
    srcs+=("${extra[@]}")
  fi
  mkdir -p "$work/run-$lib"
  run_item "$TEST_TIMEOUT" "$work/run-$lib" "$log" \
    c3c --libdir "$libdir" "${largs[@]}" compile-test "${srcs[@]}" -o "$work/bin-$lib"
  local st detail
  st="$(status_of "$RC")"
  detail="$(python3 -I -c "$PARSE_UNIT_PY" "$log" "${srcs[@]}" 2>/dev/null | tr '\n' ' ')"
  if [ "$st" = PASS ] && [[ "$detail" == *"has_tests=0"* ]]; then st=NO-TESTS; fi
  if [ "$st" = PASS ] || [ "$st" = NO-TESTS ]; then
    record "$st" "$name" "$detail" "$log"
  else
    record "$st" "$name" "exit $RC; $detail" "$log"
  fi
}

# ---- live ---------------------------------------------------------------------------
PY=""
if [ "$group" = all ] || [ "$group" = live ]; then
  if python3 -m venv "$work/venv" >"$work/venv.log" 2>&1 \
     && "$work/venv/bin/pip" install -q dbus-next cryptography >>"$work/venv.log" 2>&1; then
    PY="$work/venv/bin/python"
  fi
fi
if [ -n "$PY" ]; then
  # Every live script that needs a python with dbus-next uses this one (its own variable is set).
  for v in APPEARANCE APPS BATTERY BLUETOOTH BRIGHTNESS DBUS HOTKEY INPUT MEDIA NETWORK NOTIFY POWER SECRETS SESSION TRAY DMSD; do
    export "BLEU_${v}_PYTHON=$PY"
  done
  export DMSD_PYTHON="$PY"
fi

live_script() {  # live_script <name> <path>
  local name="live:$1" path="$2" log="$work/live-$1.log" rel
  rel="${path#"$here"/}"
  run_item "$LIVE_TIMEOUT" "$(dirname "$path")" "$log" bash "$path"
  record "$(status_of "$RC")" "$name" "exit $RC ($rel)" "$log"
}

live_capi() {
  local log="$work/live-capi.log"
  run_item "$LIVE_TIMEOUT" "$here" "$log" bash -c '
    set -eu
    echo "== headers up to date (tools/capi/build.sh --check)"
    tools/capi/build.sh --check
    echo "== build into the work directory"
    OUT="$1" tools/capi/build.sh
    echo "== tools/capi/tests/run.sh"
    CAPI_OUT="$1" tools/capi/tests/run.sh' _ "$work/capi"
  record "$(status_of "$RC")" "live:capi" "exit $RC (build, then tests/run.sh)" "$log"
}

# ---- check --------------------------------------------------------------------------
count_targets() {  # count_targets <log>: "N ok, M skipped, K FAIL" from check output lines
  local ok sk fl
  ok="$(grep -c '^ok ' "$1")"; sk="$(grep -c '^skip ' "$1")"; fl="$(grep -c '^FAIL ' "$1")"
  echo "$ok ok, $sk skipped, $fl FAIL"
}

check_libs() {
  local log="$work/check-libs.log"
  run_item "$CHECK_TIMEOUT" "$here" "$log" tools/check.sh
  record "$(status_of "$RC")" "check:libs" "exit $RC; $(count_targets "$log") targets" "$log"
}

check_app() {
  # check-apps.sh reads apps/<app>/project.json (dmsd); check-app.sh reads manifest.json (bleud, bleuctl).
  local app="$1" log="$work/check-app-$1.log" tool="tools/check-apps.sh"
  [ -f "$here/apps/$app/project.json" ] || tool="tools/check-app.sh"
  run_item "$CHECK_TIMEOUT" "$here" "$log" "$tool" "$app"
  record "$(status_of "$RC")" "check:$app" "exit $RC; $(count_targets "$log") targets" "$log"
}

# ---- selection and run --------------------------------------------------------------
wanted_lib() {
  [ "${#only[@]}" -eq 0 ] && return 0
  local o; for o in "${only[@]}"; do [ "$o" = "$1" ] && return 0; done
  return 1
}

if [ "$group" = all ] || [ "$group" = unit ]; then
  for dir in "$here"/libs/*.c3l; do
    [ -f "$dir/manifest.json" ] || continue
    lib="$(basename "$dir" .c3l)"
    wanted_lib "$lib" || continue
    unit_item "$lib"
  done
fi

if [ "$group" = all ] || [ "$group" = live ]; then
  for dir in "$here"/libs/*.c3l; do
    [ -f "$dir/tests/run.sh" ] || continue
    live_script "$(basename "$dir" .c3l | sed 's/^bleu_//')" "$dir/tests/run.sh"
  done
  for rel in "${EXTRA_LIVE[@]}"; do
    [ -f "$here/$rel" ] || { record FAIL "live:$rel" "missing" ""; continue; }
    live_script "$(basename "$(dirname "$(dirname "$here/$rel")")" .c3l | sed 's/^bleu_//')-$(basename "$rel" .sh)" "$here/$rel"
  done
  for dir in "$here"/apps/*/; do
    [ -f "$dir/tests/run.sh" ] || continue
    live_script "app-$(basename "$dir")" "$dir/tests/run.sh"
  done
  live_capi
fi

if [ "$group" = all ] || [ "$group" = check ]; then
  check_libs
  for dir in "$here"/apps/*/; do
    [ -f "$dir/project.json" ] || [ -f "$dir/manifest.json" ] || continue
    check_app "$(basename "$dir")"
  done
fi

# ---- report -------------------------------------------------------------------------
n=${#ST[@]}
if [ "$n" -eq 0 ]; then echo "test-all: nothing selected"; exit 2; fi
npass=0; nfail=0; ntime=0; nnone=0
printf '%-9s %-40s %s\n' STATUS ITEM DETAIL
for ((i = 0; i < n; i++)); do
  printf '%-9s %-40s %s\n' "${ST[$i]}" "${NM[$i]}" "${DT[$i]}"
  case "${ST[$i]}" in
    PASS) npass=$((npass + 1));;
    FAIL) nfail=$((nfail + 1));;
    TIMEOUT) ntime=$((ntime + 1));;
    NO-TESTS) nnone=$((nnone + 1));;
  esac
done
echo
echo "items $n: PASS $npass, FAIL $nfail, TIMEOUT $ntime, NO-TESTS $nnone"

if [ $((nfail + ntime)) -gt 0 ]; then
  for ((i = 0; i < n; i++)); do
    case "${ST[$i]}" in FAIL|TIMEOUT) ;; *) continue;; esac
    echo
    echo "---- ${ST[$i]} ${NM[$i]}  (log: ${LG[$i]})"
    [ -n "${LG[$i]}" ] && [ -f "${LG[$i]}" ] && tail -n 25 "${LG[$i]}"
  done
fi
[ -n "${KEEP_LOGS:-}" ] && echo && echo "logs kept in $work"

[ $((nfail + ntime)) -eq 0 ]
