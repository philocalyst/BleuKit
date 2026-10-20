#!/usr/bin/env bash
# Type-check every application under apps/ for every target, without linking.
#
#   tools/check-apps.sh                 all apps, all six targets
#   tools/check-apps.sh dmsd            only the named apps
#   TARGETS="macos-aarch64" tools/check-apps.sh
#
# An app is type-checked with the libraries its apps/<name>/project.json lists as
# "dependencies", so list the whole closure there (c3c does not follow manifests for
# application builds). Apps named in POSIX_ONLY use POSIX APIs (signals, pipes, Unix
# sockets) and are checked for the POSIX targets only; they are reported as skipped on
# Windows rather than failing there.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
targets="${TARGETS:-linux-x64 linux-aarch64 macos-aarch64 macos-x64 windows-x64 windows-aarch64}"
POSIX_ONLY="dmsd"

if [ "$#" -gt 0 ]; then apps=("$@"); else
  apps=()
  for d in "$here"/apps/*/; do [ -f "$d/project.json" ] && apps+=("$(basename "$d")"); done
fi
if [ "${#apps[@]}" -eq 0 ]; then echo "no apps under apps/"; exit 0; fi

libdir="$("$here/tools/libdir.sh")"
work="$(mktemp -d)"
trap 'rm -rf "$work" "$libdir"' EXIT
status=0

# The "dependencies" list of an app's project.json (// comments allowed, as c3c accepts them).
deps_of() {
  python3 -I - "$1" <<'EOF'
import json, re, sys
text = re.sub(r'//[^\n]*', '', open(sys.argv[1]).read())
for lib in json.loads(text).get("dependencies", []):
    print(lib)
EOF
}

for app in "${apps[@]}"; do
  project="$here/apps/$app/project.json"
  if [ ! -f "$project" ]; then echo "FAIL  $app: no apps/$app/project.json"; status=1; continue; fi
  largs=()
  while read -r lib; do largs+=(--lib "$lib"); done < <(deps_of "$project")
  sources=("$here"/apps/"$app"/src/*.c3)
  for t in $targets; do
    case " $POSIX_ONLY " in
      *" $app "*)
        case "$t" in
          windows-*) echo "skip  $app $t (POSIX-only app)"; continue;;
        esac;;
    esac
    out="$(cd "$work" && c3c --libdir "$libdir" "${largs[@]}" --target "$t" --no-obj \
            --warn-deprecation=error --warn-deadcode=no compile-only "${sources[@]}" 2>&1)"
    if [ $? -eq 0 ]; then
      echo "ok    $app $t"
    else
      echo "FAIL  $app $t"; echo "$out" | head -"${LINES_PER_TARGET:-14}"; status=1
    fi
  done
done
exit $status
