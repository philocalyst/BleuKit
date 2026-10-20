#!/usr/bin/env bash
# Type-check one application for every supported target without linking.
#
#   tools/check-app.sh bleud            all six targets
#   TARGETS="macos-aarch64" tools/check-app.sh bleuctl
#
# The application is apps/<name>/src/*.c3; its libraries are the closure of the
# "dependencies" in apps/<name>/manifest.json, found through each library's own
# manifest. C3 type-checks every function, so a clean run means the whole
# application compiles on that target. Nothing is linked or run.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:?usage: tools/check-app.sh <app>}"
src="$here/apps/$app/src"
[ -d "$src" ] || { echo "no such application: apps/$app" >&2; exit 2; }
targets="${TARGETS:-linux-x64 linux-aarch64 macos-aarch64 macos-x64 windows-x64 windows-aarch64}"

# The library closure, dependencies first-visited order, from the manifests.
libs=$(python3 - "$here" "$app" <<'PY'
import json, os, sys
here, app = sys.argv[1], sys.argv[2]
seen = []
def visit(name):
    if name in seen:
        return
    manifest = os.path.join(here, "libs", name + ".c3l", "manifest.json")
    if not os.path.exists(manifest):
        return
    seen.append(name)
    for dep in json.load(open(manifest)).get("dependencies", []):
        visit(dep)
for dep in json.load(open(os.path.join(here, "apps", app, "manifest.json")))["dependencies"]:
    visit(dep)
print(" ".join(seen))
PY
)
args=(); for l in $libs; do args+=(--lib "$l"); done
libdir="$("$here/tools/libdir.sh")"
work="$(mktemp -d)"; trap 'rm -rf "$work" "$libdir"' EXIT; cd "$work"   # c3c writes out/ and obj/ into the cwd
status=0
for t in $targets; do
  out="$(c3c --libdir "$libdir" "${args[@]}" --target "$t" --no-entry --no-obj \
          --warn-deprecation=error --warn-deadcode=no compile-only "$src"/*.c3 2>&1)"
  if [ $? -eq 0 ]; then echo "ok    $t"; else echo "FAIL  $t"; echo "$out" | head -${LINES_PER_TARGET:-14}; status=1; fi
done
exit $status
