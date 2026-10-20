#!/usr/bin/env python3
"""Extract the JSON field lists of DankMaterialShell's wire structs from Go source.

    python3 extract_go_tags.py <DMS checkout> > golden/go_tags.json

<DMS checkout> is a DankMaterialShell git checkout at (or after) the revision named
in golden/go_tags.json. Each entry lists the `json` tags of one Go struct in declaration
order, with the file and line range it came from, so the test can compare dmsd's keys
and their order with the Go source rather than with a copy of dmsd's own output.
"""
import json
import os
import re
import sys

# (Go type, file under core/internal/server, the struct's name for the test)
STRUCTS = [
    ("SessionState", "loginctl/types.go"),
    ("Device", "brightness/types.go"),
    ("State", "brightness/types.go"),
    ("DeviceUpdate", "brightness/types.go"),
    ("SuccessResult", "models/types.go"),
    ("ServerInfo", "server.go"),
]
FIELD = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s+\S.*?`json:"([^"]+)"`')


def struct_body(lines, type_name):
    """Return (first line, last line, body lines) of `type <name> struct {` ... `}`, 1-based."""
    start = None
    for i, line in enumerate(lines):
        if re.match(r'^type\s+%s\s+struct\s*\{' % re.escape(type_name), line):
            start = i
            break
    if start is None:
        raise SystemExit("type %s not found" % type_name)
    for j in range(start + 1, len(lines)):
        if lines[j].startswith("}"):
            return start + 1, j + 1, lines[start + 1:j]
    raise SystemExit("unterminated struct %s" % type_name)


def main(checkout):
    root = os.path.join(checkout, "core", "internal", "server")
    out = {"source": "AvengeMedia/DankMaterialShell core/internal/server", "revision": "8be08999", "structs": {}}
    for type_name, rel in STRUCTS:
        path = os.path.join(root, rel)
        with open(path, encoding="utf-8") as f:
            lines = f.read().split("\n")
        first, last, body = struct_body(lines, type_name)
        tags = []
        for line in body:
            m = FIELD.match(line)
            if m:
                tags.append(m.group(2).split(",")[0])
        omit = []
        for line in body:
            m = FIELD.match(line)
            if m and "omitempty" in m.group(2):
                omit.append(m.group(2).split(",")[0])
        out["structs"][type_name] = {"file": "core/internal/server/" + rel, "lines": [first, last],
                                     "fields": tags, "omitempty": omit}
    json.dump(out, sys.stdout, indent=1)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main(sys.argv[1])
