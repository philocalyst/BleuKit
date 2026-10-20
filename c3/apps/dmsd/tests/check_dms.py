#!/usr/bin/env python3
"""Drive a running dmsd like the DMS shell does, and check every reply.

    check_dms.py <socket> <fake sysfs root> <tests dir>

Checks, all against the files in golden/ and the Go sources the tag list was taken from
(golden/go_tags.json, see extract_go_tags.py):

* the handshake line and getServerInfo: the protocol version, the capability names, and
  the field order of ServerInfo;
* replies: the exact text of every error (golden/errors.json), the exact result of
  the golden states, and the field names and order of every DMS struct against its Go tags;
* brightness writes: the raw values written to the fake sysfs file and the percentages
  reported, computed here from DMS's formulas (sysfs.go, handlers.go), independently of dmsd;
* subscriptions: the first frame is `server`, every later frame carries the subscribe id,
  a write publishes `brightness` and `brightness.update`, and `loginctl` sends its snapshot.

Exit status 0 when every check passed; otherwise the failed checks are printed.
"""
import json
import math
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dmsclient import DmsClient  # noqa: E402

FAILURES = []


def check(cond, what):
    if not cond:
        FAILURES.append(what)
        print("FAIL", what)
    else:
        print("ok  ", what)


def go_round(x):
    """math.Round: halves away from zero (sysfs.go uses it)."""
    return math.floor(x + 0.5) if x >= 0 else -math.floor(-x + 0.5)


def dms_sysfs_value(percent, minimum, maximum, exponential=False, exponent=1.2):
    """sysfs.go PercentToValueWithExponent."""
    if percent == 0:
        return minimum
    usable = maximum - minimum
    if exponential:
        value = minimum + go_round(((percent - 1) / 99.0) ** exponent * usable)
    else:
        value = minimum + ((percent - 1) * usable) // 99
    return min(max(value, minimum), maximum)


def dms_sysfs_percent(value, minimum, maximum):
    """sysfs.go ValueToPercentWithExponent, linear."""
    if value <= minimum:
        return 0 if (minimum == 0 and value == 0) else 1
    usable = maximum - minimum
    if usable == 0:
        return 100
    return min(1 + go_round((value - minimum) * 99.0 / usable), 100)


def read_raw(root):
    with open(os.path.join(root, "sys/class/backlight/intel_backlight/brightness")) as f:
        return int(f.read().strip())


def keys_match(obj, tags, what, optional=()):
    """Keys of `obj` are exactly `tags` in order, except the omitempty ones that are absent."""
    keys = list(obj.keys())
    expected = [t for t in tags if t not in optional or t in keys]
    check(keys == expected, "%s keys in Go order: %s" % (what, keys))


def main():
    sock, root, tests = sys.argv[1], sys.argv[2], sys.argv[3]
    with open(os.path.join(tests, "golden", "go_tags.json")) as f:
        go = json.load(f)["structs"]
    with open(os.path.join(tests, "golden", "errors.json")) as f:
        errors = json.load(f)
    golden = {}
    for name in ["handshake", "server_info", "ping", "brightness_state_initial", "loginctl_state"]:
        with open(os.path.join(tests, "golden", name + ".json")) as f:
            golden[name] = json.load(f)

    client = DmsClient(sock)
    check(client.requests.handshake == golden["handshake"], "handshake line equals golden: %s" % client.requests.handshake)

    reply = client.request("ping")
    check(reply.get("result") == golden["ping"], "ping -> {pong:true}")

    reply = client.request("getServerInfo")
    check(reply.get("result") == golden["server_info"], "getServerInfo equals golden")
    keys_match(reply["result"], go["ServerInfo"]["fields"], "ServerInfo", go["ServerInfo"]["omitempty"])

    reply = client.request("brightness.getState")
    check(reply.get("result") == golden["brightness_state_initial"], "brightness.getState equals golden")
    state = reply["result"]
    keys_match(state, go["State"]["fields"], "brightness State")
    for device in state["devices"]:
        keys_match(device, go["Device"]["fields"], "brightness Device " + device["id"])

    reply = client.request("loginctl.getState")
    check(reply.get("result") == golden["loginctl_state"], "loginctl.getState equals golden")
    keys_match(reply["result"], go["SessionState"]["fields"], "SessionState")

    for method, params, text in errors:
        reply = client.request(method, params)
        check(reply.get("error") == text, "error for %s %s is %r (got %r)" % (method, json.dumps(params), text, reply.get("error")))

    # Brightness writes: the file must hold the raw value DMS's formula gives.
    minimum, maximum = 1, 96000
    reply = client.request("brightness.setBrightness", {"device": "backlight:intel_backlight", "percent": 50})
    want = dms_sysfs_value(50, minimum, maximum)
    check(read_raw(root) == want, "setBrightness 50 wrote raw %d (file %d)" % (want, read_raw(root)))
    dev = reply["result"]["devices"][0]
    check(dev["current"] == want and dev["currentPercent"] == dms_sysfs_percent(want, minimum, maximum),
          "setBrightness reply shows the new raw value and percent")
    check(reply["result"]["devices"][1]["id"] == "leds:input5::kbd_backlight", "setBrightness reply keeps the LED device")

    before = dms_sysfs_percent(read_raw(root), minimum, maximum)
    reply = client.request("brightness.increment", {"device": "backlight:intel_backlight", "step": 10})
    want = dms_sysfs_value(min(before + 10, 100), minimum, maximum)
    check(read_raw(root) == want, "increment by 10 from %d%% wrote raw %d" % (before, want))

    before = dms_sysfs_percent(read_raw(root), minimum, maximum)
    reply = client.request("brightness.decrement", {"device": "backlight:intel_backlight", "step": 20})
    want = dms_sysfs_value(max(before - 20, 0), minimum, maximum)
    check(read_raw(root) == want, "decrement by 20 from %d%% wrote raw %d" % (before, want))

    reply = client.request("brightness.setBrightness", {"device": "backlight:intel_backlight", "percent": 50, "exponential": True, "exponent": 2.0})
    want = dms_sysfs_value(50, minimum, maximum, True, 2.0)
    check(read_raw(root) == want, "exponential setBrightness 50 (exponent 2.0) wrote raw %d" % want)

    reply = client.request("brightness.rescan")
    check(reply.get("result", {}).get("devices", [{}])[0].get("current") == want, "rescan reports the current raw value")

    # Subscriptions: the shell's second connection.
    client.subscribe(["brightness", "brightness.update", "loginctl"])
    sub_id = client.subscribe_id
    service, data, frame_id = client.next_frame()
    check(service == "server" and frame_id == sub_id, "first subscription frame is `server` with the subscribe id")
    keys_match(data, go["ServerInfo"]["fields"], "server frame ServerInfo", go["ServerInfo"]["omitempty"])
    snapshots = {}
    for _ in range(2):
        service, data, frame_id = client.next_frame()
        snapshots[service] = data
        check(frame_id == sub_id, "snapshot frame %s carries the subscribe id" % service)
    check(set(snapshots) == {"brightness", "loginctl"}, "snapshots for brightness and loginctl (got %s)" % sorted(snapshots))
    check(snapshots.get("loginctl") == golden["loginctl_state"], "loginctl snapshot equals golden state")

    reply = client.request("brightness.setBrightness", {"device": "backlight:intel_backlight", "percent": 30})
    want = dms_sysfs_value(30, minimum, maximum)
    seen = {}
    deadline = time.time() + 10
    while len(seen) < 2 and time.time() < deadline:
        service, data, frame_id = client.next_frame()
        if service in ("brightness", "brightness.update"):
            seen[service] = data
            check(frame_id == sub_id, "%s frame carries the subscribe id" % service)
    check("brightness" in seen and "brightness.update" in seen, "a write publishes brightness and brightness.update")
    if "brightness.update" in seen:
        update = seen["brightness.update"]
        check(list(update.keys()) == ["device"], "brightness.update is {device}")
        keys_match(update["device"], go["Device"]["fields"], "brightness.update Device")
        check(update["device"]["current"] == want, "brightness.update carries the written raw value")
    if "brightness" in seen:
        check(seen["brightness"]["devices"][0]["current"] == want, "brightness frame carries the written raw value")

    # Session actions: each answers the DMS success result (handlers.go, SuccessResult).
    expect = [
        ("shell.ready", {"pid": 4242}, {"success": True}),
        ("loginctl.lock", None, {"success": True, "message": "locked"}),
        ("loginctl.unlock", None, {"success": True, "message": "unlocked"}),
        ("loginctl.setLockBeforeSuspend", {"enabled": True}, {"success": True, "message": "lock before suspend set"}),
        ("loginctl.setSleepInhibitorEnabled", {"enabled": True}, {"success": True, "message": "sleep inhibitor setting updated"}),
        ("loginctl.lockerReady", None, {"success": True, "message": "ok"}),
        ("loginctl.terminate", None, {"success": True, "message": "terminated"}),
    ]
    for method, params, result in expect:
        reply = client.request(method, params)
        check(reply.get("result") == result, "%s -> %s" % (method, json.dumps(result)))
        if "result" in reply:
            keys_match(reply["result"], go["SuccessResult"]["fields"], method + " SuccessResult", go["SuccessResult"]["omitempty"])

    client.close()

    if FAILURES:
        print("%d check(s) failed" % len(FAILURES))
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
