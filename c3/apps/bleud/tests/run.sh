#!/usr/bin/env bash
# Build bleud and bleuctl for Linux and run the end-to-end checks in check_bleud.py.
#
#   apps/bleud/tests/run.sh
#
# Needs python3. Everything is built and run in a private temporary directory, so
# the repository tree is not touched (c3c writes out/ and obj/ into the cwd).
set -eu
here="$(cd "$(dirname "$0")/../../.." && pwd)"
work="$(mktemp -d)"
libdir="$("$here/tools/libdir.sh")"
trap 'rm -rf "$work" "$libdir"' EXIT
closure() {
  python3 - "$here" "$1" <<'PY'
import json, os, sys
here, app = sys.argv[1], sys.argv[2]
seen = []
def visit(name):
    if name in seen: return
    m = os.path.join(here, "libs", name + ".c3l", "manifest.json")
    if not os.path.exists(m): return
    seen.append(name)
    for dep in json.load(open(m)).get("dependencies", []): visit(dep)
for dep in json.load(open(os.path.join(here, "apps", app, "manifest.json")))["dependencies"]: visit(dep)
print(" ".join(seen))
PY
}
build() {
  local app="$1"
  local args=()
  for l in $(closure "$app"); do args+=(--lib "$l"); done
  (cd "$work" && c3c --libdir "$libdir" "${args[@]}" compile "$here/apps/$app/src/"*.c3 -o "$work/$app")
}
build bleud
build bleuctl
python3 "$here/apps/bleud/tests/check_bleud.py" "$work/bleud" "$work/bleuctl" "$work"
