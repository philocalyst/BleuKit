#!/usr/bin/env python3
"""Verify fuzz_main output with python3's own JSON, UTF-8 and float rules.

Usage: python3 -I check_fuzz.py fuzz.txt

  S <hex bytes> <json>   json.loads(json) must equal bytes.decode('utf-8', 'replace')
  D <hex bits> <json>    NaN/inf must be null; otherwise json.loads gives the same
                         double and the text is the shortest '%.Ng' that does
  F <hex bits> <json>    the same rule for binary32, with 9 digits at most
"""
import json
import math
import struct
import sys


def shortest_g(value, single):
    """The shortest '%.Ng' text that reads back to `value` (as float32 when `single`)."""
    limit = 9 if single else 17
    for digits in range(1, limit + 1):
        text = "%.*g" % (digits, value)
        back = float(text)
        if single:
            back = struct.unpack("<f", struct.pack("<f", back))[0]
        if back == value:
            return text
    return "%.*g" % (limit, value)


def check_line(kind, hex_bits, text):
    if kind == "S":
        data = bytes.fromhex(hex_bits)
        value = json.loads(text)
        expected = data.decode("utf-8", "replace")
        if value != expected:
            return "string mismatch: %r != %r" % (value, expected)
        return None
    if kind == "D":
        value = struct.unpack(">d", bytes.fromhex(hex_bits))[0]
    elif kind == "F":
        value = struct.unpack(">f", bytes.fromhex(hex_bits))[0]
    else:
        return "unknown kind"
    if not math.isfinite(value):
        return None if text == "null" else "non-finite must be null, got %s" % text
    single = kind == "F"
    expected = shortest_g(value, single)
    if text != expected:
        return "number text %s, shortest is %s" % (text, expected)
    parsed = json.loads(text)
    if single:
        if struct.unpack("<f", struct.pack("<f", float(parsed)))[0] != value:
            return "float32 does not round-trip: %s" % text
    elif float(parsed) != value:
        return "double does not round-trip: %s" % text
    return None


def main(path):
    counts = {"S": 0, "D": 0, "F": 0}
    failures = []
    with open(path, "rb") as handle:
        for number, raw in enumerate(handle, 1):
            line = raw.decode("utf-8").rstrip("\n")
            kind, hex_bits, text = line.split(" ", 2)
            counts[kind] = counts.get(kind, 0) + 1
            problem = check_line(kind, hex_bits, text)
            if problem:
                failures.append("line %d (%s %s %s): %s" % (number, kind, hex_bits, text, problem))
    for failure in failures[:20]:
        print(failure)
    print("checked", counts, "failures", len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
