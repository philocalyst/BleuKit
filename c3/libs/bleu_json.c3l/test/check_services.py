#!/usr/bin/env python3
"""Verify services_main output: every line is JSON and has the declared members.

Usage: python3 -I check_services.py services.txt [golden.txt]

With a second argument the output must also equal the golden file byte for byte.

The member lists below are copied from the `struct` declarations in
libs/bleu_battery.c3l/src/model.c3, libs/bleu_brightness.c3l/src/model.c3 and
libs/bleu_network.c3l/src/model.c3, so a field added there must be added here.
"""
import json
import sys

SOURCE = ["id", "kind", "present", "state", "charge", "power", "time_to_empty", "time_to_full",
          "energy", "energy_full", "energy_design", "health", "cycles", "temperature",
          "chemistry", "vendor", "model", "serial"]
CONTROL = ["mechanism", "readable", "writable", "availability", "level", "raw", "raw_min", "raw_max"]
DEVICE = ["id", "name", "kind", "controls"]
WIFI = ["present", "interface_name", "radio_enabled", "hardware_blocked", "scanning", "ssid_visible",
        "phase", "failure", "connected_ssid", "signal", "networks"]
ACCESS_POINT = ["ssid", "bssid", "frequency", "signal", "quality", "band", "security", "in_use",
                "known", "autoconnect"]
INTERFACE = ["name", "kind", "link", "carrier", "speed", "rx_bytes", "tx_bytes"]
NETWORK_STATE = ["connectivity", "location", "primary_interface", "wifi", "interfaces"]
BATTERY_STATE = ["on_mains", "sources", "adapter_watts"]
BRIGHTNESS_STATE = ["devices"]


def expect_keys(obj, keys, where):
    if not isinstance(obj, dict):
        raise AssertionError("%s is not an object" % where)
    if list(obj.keys()) != keys:
        raise AssertionError("%s keys %s, expected %s" % (where, list(obj.keys()), keys))


def check_battery(state):
    expect_keys(state, BATTERY_STATE, "battery")
    assert isinstance(state["on_mains"], bool)
    for index, source in enumerate(state["sources"]):
        expect_keys(source, SOURCE, "source %d" % index)
        for key in ("time_to_empty", "time_to_full", "energy"):
            value = source[key]
            assert value is None or (isinstance(value, int) and not isinstance(value, bool)), key
        for key in ("charge", "health"):
            value = source[key]
            assert value is None or (isinstance(value, float) or isinstance(value, int)), key
            assert value is None or 0.0 <= value <= 1.0, "%s out of range: %r" % (key, value)


def check_brightness(state):
    expect_keys(state, BRIGHTNESS_STATE, "brightness")
    for device in state["devices"]:
        expect_keys(device, DEVICE, "device")
        for control in device["controls"]:
            expect_keys(control, CONTROL, "control")
            expect_keys(control["availability"], ["reason", "note"], "availability")
            assert isinstance(control["raw"], (int, type(None)))


def check_network(state):
    expect_keys(state, NETWORK_STATE, "network")
    wifi = state["wifi"]
    expect_keys(wifi, WIFI, "wifi")
    expect_keys(wifi["connected_ssid"], ["bytes", "label"], "connected_ssid")
    for point in wifi["networks"]:
        expect_keys(point, ACCESS_POINT, "access point")
        expect_keys(point["ssid"], ["bytes", "label"], "ssid")
    for interface in state["interfaces"]:
        expect_keys(interface, INTERFACE, "interface")


CHECKERS = {"battery": check_battery, "brightness": check_brightness, "network": check_network}


def main(path, golden=None):
    if golden is not None:
        with open(path, "rb") as produced, open(golden, "rb") as expected:
            if produced.read() != expected.read():
                print("output differs from", golden)
                return 1
    seen = set()
    with open(path, "rb") as handle:
        for line in handle:
            text = line.decode("utf-8").rstrip("\n")
            if not text:
                continue
            name, payload = text.split(" ", 1)
            state = json.loads(payload)
            CHECKERS[name](state)
            seen.add(name)
    missing = set(CHECKERS) - seen
    if missing:
        print("missing services:", sorted(missing))
        return 1
    print("services ok:", sorted(seen))
    return 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:3]))
