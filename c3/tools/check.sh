#!/usr/bin/env bash
# Type-check every Bleu library for every supported target without linking.
#
#   tools/check.sh                     all libraries, all targets
#   tools/check.sh bleu_battery        only the named libraries (+ whatever they need, list them all)
#   TARGETS="macos-aarch64" tools/check.sh
#
# C3 analyses every function of a library, used or not, so a clean run means
# the whole source base type-checks on that target. It does NOT run anything.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
targets="${TARGETS:-linux-x64 linux-aarch64 macos-aarch64 macos-x64 windows-x64 windows-aarch64}"
if [ "$#" -gt 0 ]; then libs=("$@"); else libs=($(cd "$here/libs" && ls -d *.c3l | sed 's/\.c3l$//')); fi
args=(); for l in "${libs[@]}"; do args+=(--lib "$l"); done
status=0
for t in $targets; do
  out="$(c3c --libdir "$here/libs" "${args[@]}" --target "$t" --no-entry --no-obj \
          --warn-deprecation=error --warn-deadcode=no compile-only "$here/tools/empty.c3" 2>&1)"
  if [ $? -eq 0 ]; then echo "ok    $t"; else echo "FAIL  $t"; echo "$out" | head -${LINES_PER_TARGET:-14}; status=1; fi
done
exit $status
