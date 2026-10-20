#!/usr/bin/env python3
"""Drive a running dmsd with the modules of this suite, and check every reply.

    check_desktop.py <socket> <work dir> <tests dir>

The daemon runs against the fake Wayland compositor (fake_wayland.py, log in <work>/wayland.log),
the mock portal on a private session bus (mock_portal.py, changed with dbus-send), and a fake sysfs
root. What is checked:

* the handshake: the capability names of these modules, in DMS's order;
* the JSON of every reply: the key order of the DMS structs (golden/go_tags.json, from the Go tags);
* the values against the scenario (scenario.json) and the DMS formulas (dms_reference.py);
* the error texts, which are DMS's where DMS has one, and the `not supported` replies;
* what reached the compositor: the configurations, the gamma ramps (read from the fd), the releases;
* subscriptions: the first frame is `server` and the topic's snapshot follows, with its change.

Exit status 0 when every check passed.
"""
import datetime
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dmsclient import DmsClient  # noqa: E402
import dms_reference as ref  # noqa: E402

FAILURES = []
# DMS's capability order (server.go getCapabilities) for the modules this suite is about.
DMS_ORDER = ["freedesktop", "gamma", "brightness", "wlroutput", "theme.auto"]
REQUIRED = ["freedesktop", "gamma", "wlroutput", "theme.auto"]


def check(cond, what):
    if not cond:
        FAILURES.append(what)
        print("FAIL", what)
    else:
        print("ok  ", what)


def keys_are(obj, expected, what):
    check(list(obj.keys()) == expected, "%s keys in Go order: %s" % (what, list(obj.keys())))


def fnv1a32(text):
    """The head id dmsd makes for a connector name (mod_wlroutput.c3 head_id)."""
    value = 2166136261
    for byte in text.encode():
        value ^= byte
        value = (value * 16777619) & 0xFFFFFFFF
    return value


def parse_time(text):
    """A dmsd time: RFC 3339 with `Z` (the Go zero time is year 1)."""
    return datetime.datetime.fromisoformat(text)


def close_to(a, b, seconds=2.0):
    return abs((a - b).total_seconds()) <= seconds


def wayland_lines(path):
    with open(path) as handle:
        return [line.strip() for line in handle if line.strip()]


def wait_for(predicate, timeout=8.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.2)
    return None


CONFIG_KEYS = ["Outputs", "LowTemp", "HighTemp", "Latitude", "Longitude", "UseIPLocation", "ManualSunrise",
               "ManualSunset", "ManualDuration", "Gamma", "Contrast", "Enabled", "ElevationTwilight",
               "ElevationDaylight"]
GAMMA_KEYS = ["config", "currentTemp", "nextTransition", "sunriseTime", "sunsetTime", "dawnTime", "nightTime",
              "isDay", "sunPosition", "iccProfiles", "outputTemps", "outputs"]
# gammaRefused is omitted unless a display refused its ramp (omitempty); it comes last when present.
GAMMA_KEYS_REFUSED = GAMMA_KEYS + ["gammaRefused"]


def gamma_keys_ok(obj, what):
    keys = list(obj.keys())
    check(keys in (GAMMA_KEYS, GAMMA_KEYS_REFUSED), "%s keys in Go order: %s" % (what, keys))
THEME_CONFIG_KEYS = ["enabled", "mode", "startHour", "startMinute", "endHour", "endMinute", "useIPLocation",
                     "elevationTwilight", "elevationDaylight"]
OUTPUT_KEYS = ["name", "description", "make", "model", "serialNumber", "physicalWidth", "physicalHeight",
               "enabled", "x", "y", "transform", "scale", "currentMode", "modes", "adaptiveSync",
               "adaptiveSyncSupported", "id"]
MODE_KEYS = ["width", "height", "refresh", "preferred", "id"]


def section_wlroutput(client, work):
    print("== wlroutput (bleu_display on the fake compositor)")
    reply = client.request("wlroutput.getState")
    state = reply.get("result", {})
    keys_are(state, ["outputs", "serial"], "wlroutput State")
    outputs = {o["name"]: o for o in state.get("outputs", [])}
    check(sorted(outputs) == ["DP-1", "HDMI-A-1"], "both scenario outputs are listed (got %s)" % sorted(outputs))
    dp = outputs.get("DP-1", {})
    keys_are(dp, OUTPUT_KEYS, "Output DP-1")
    check(dp.get("physicalWidth") == 600 and dp.get("physicalHeight") == 340, "DP-1 physical size from the scenario")
    check(dp.get("currentMode") == {"width": 1920, "height": 1080, "refresh": 60000, "preferred": True, "id": 1},
          "DP-1 current mode is the scenario's, with the id of its list position")
    check([m["id"] for m in dp.get("modes", [])] == [1, 2], "DP-1 mode ids are 1-based list positions")
    keys_are(dp["modes"][0], MODE_KEYS, "OutputMode")
    check(dp.get("id") == fnv1a32("DP-1"), "DP-1 head id is FNV-1a of the connector name")
    check(dp.get("adaptiveSyncSupported") is True and dp.get("adaptiveSync") == 0, "adaptive sync read from the compositor")

    # A test of an unchanged layout is answered without the compositor (bleu_display completes it locally),
    # so the test below moves HDMI-A-1 to make the compositor see it.
    reply = client.request("wlroutput.testConfiguration", {"heads": [{"name": "DP-1", "enabled": True,
                                                                      "position": {"x": 0, "y": 0}}]})
    check(reply.get("result") == {"success": True, "message": "configuration test succeeded"}, "test of an unchanged layout succeeds")
    reply = client.request("wlroutput.testConfiguration", {"heads": [{"name": "HDMI-A-1", "enabled": True,
                                                                      "position": {"x": 1920, "y": 50}}]})
    check(reply.get("result") == {"success": True, "message": "configuration test succeeded"}, "test of a valid layout succeeds")
    check("config.test ok" in wayland_lines(os.path.join(work, "wayland.log")), "the compositor saw the test and accepted it")

    reply = client.request("wlroutput.applyConfiguration", {"heads": [{"name": "HDMI-A-1", "enabled": True,
                                                                      "position": {"x": 1920, "y": 100}}]})
    check(reply.get("result") == {"success": True, "message": "configuration applied"}, "apply moves HDMI-A-1")
    moved = wait_for(lambda: next((o for o in client.request("wlroutput.getState")["result"]["outputs"]
                                   if o["name"] == "HDMI-A-1" and o["y"] == 100), None))
    check(moved is not None and moved["x"] == 1920, "the new position is reported after the compositor's update")
    check("config.set_position HDMI-A-1 1920 100" in wayland_lines(os.path.join(work, "wayland.log")),
          "the compositor received the position of HDMI-A-1")

    reply = client.request("wlroutput.applyConfiguration", {"heads": [{"name": "HDMI-A-1", "enabled": False}]})
    check(reply.get("result") == {"success": True, "message": "configuration applied"},
          "apply disables HDMI-A-1 (got %s)" % json.dumps(reply.get("result", reply.get("error"))))
    off = wait_for(lambda: next((o for o in client.request("wlroutput.getState")["result"]["outputs"]
                                 if o["name"] == "HDMI-A-1" and not o["enabled"]), None))
    check(off is not None, "HDMI-A-1 reports disabled after the compositor's update")

    errors = [
        ({"heads": [{"name": "NOPE"}]}, "head not found: NOPE"),
        ({"heads": [{"name": "DP-1", "enabled": True, "modeId": 9}]}, "mode not found: 9"),
        ({"heads": [{"name": "DP-1", "enabled": True, "transform": 9}]}, "invalid transform: 9"),
        ({"heads": [{"name": "DP-1", "enabled": True, "adaptiveSync": 1}]},
         "not supported: bleu_display does not write adaptive sync (a layout change has no field for it)"),
        ({}, "missing 'heads' parameter"),
        ({"heads": 5}, "invalid 'heads' parameter format"),
    ]
    for params, text in errors:
        reply = client.request("wlroutput.applyConfiguration", params)
        check(reply.get("error") == text, "applyConfiguration %s -> %r (got %r)" % (json.dumps(params), text, reply.get("error")))
    reply = client.request("wlroutput.subscribe")
    check(str(reply.get("error", "")).startswith("not supported: a streaming method"), "wlroutput.subscribe is refused")

    client.subscribe(["wlroutput"])
    service, data, frame_id = client.next_frame()
    check(service == "server", "subscription starts with the `server` frame")
    service, data, frame_id = client.next_frame()
    check(service == "wlroutput" and frame_id == client.subscribe_id, "subscription gets the wlroutput snapshot")
    keys_are(data, ["outputs", "serial"], "wlroutput snapshot")
    client.request("wlroutput.applyConfiguration", {"heads": [{"name": "HDMI-A-1", "enabled": True,
                                                              "position": {"x": 1920, "y": 200}}]})
    seen = None
    deadline = time.time() + 8
    while time.time() < deadline:
        service, data, frame_id = client.next_frame()
        if service == "wlroutput":
            hdmi = next((o for o in data["outputs"] if o["name"] == "HDMI-A-1"), {})
            if hdmi.get("y") == 200:
                seen = data
                break
    check(seen is not None, "a change is published on the wlroutput topic")


def section_gamma(client, work):
    print("== gamma (bleu_color on the fake compositor)")
    reply = client.request("wayland.gamma.getState")
    state = reply.get("result", {})
    gamma_keys_ok(state, "gamma State")
    keys_are(state.get("config", {}), CONFIG_KEYS, "gamma Config")
    config = state.get("config", {})
    check(config.get("LowTemp") == 4500 and config.get("HighTemp") == 6500 and config.get("Enabled") is False,
          "defaults: 4500 K night, 6500 K day, disabled")
    check(config.get("ManualSunrise") is None and config.get("Latitude") is None, "no manual times and no location at start")
    check(state.get("nextTransition") == "0001-01-01T00:00:00Z", "nextTransition is Go's zero time (not computed)")

    log = os.path.join(work, "wayland.log")
    reply = client.request("wayland.gamma.setEnabled", {"enabled": True})
    check(reply.get("result") == {"success": True, "message": "enabled state set"}, "setEnabled true succeeds")
    reply = client.request("wayland.gamma.setTemperature", {"temp": 3500})
    check(reply.get("result") == {"success": True, "message": "temperature set"}, "setTemperature 3500 succeeds")
    sets = [line for line in wayland_lines(log) if line.startswith("gamma.set DP-1")]
    check(bool(sets), "the compositor received a ramp for DP-1")
    if sets:
        parts = dict(p.split("=") for p in sets[-1].split()[2:])
        red_end = int(parts["red"].split(",")[1])
        blue_end = int(parts["blue"].split(",")[1])
        check(red_end == 65535 and blue_end < red_end, "a 3500 K ramp is warm: red at the top, blue below it (%s)" % sets[-1])
    # At the neutral 6500 K bleu_color writes no ramp: it releases the display's control instead.
    destroys = wayland_lines(log).count("gamma.destroy DP-1")
    reply = client.request("wayland.gamma.setTemperature", {"temp": 6500})
    check(reply.get("result") == {"success": True, "message": "temperature set"}, "setTemperature 6500 succeeds")
    check(wait_for(lambda: wayland_lines(log).count("gamma.destroy DP-1") > destroys) is not None,
          "the neutral 6500 K releases DP-1's ramp (no ramp is written)")

    for params, text in [({"low": 3000}, "missing temperature parameters (provide 'temp' or both 'low' and 'high')"),
                         ({}, "missing temperature parameters (provide 'temp' or both 'low' and 'high')")]:
        reply = client.request("wayland.gamma.setTemperature", params)
        check(reply.get("error") == text, "setTemperature %s -> %r" % (json.dumps(params), text))
    reply = client.request("wayland.gamma.setTemperature", {"low": 900, "high": 6500})
    check(str(reply.get("error", "")) == "day and night must be 1000 to 25000 K", "a temperature out of range is refused (%s)" % reply.get("error"))

    reply = client.request("wayland.gamma.setLocation", {"latitude": 95.0, "longitude": 13.4})
    check(reply.get("error") == "latitude must be -90 to 90 degrees", "setLocation with latitude 95 is refused")
    reply = client.request("wayland.gamma.setLocation", {"latitude": 52.52, "longitude": 13.405})
    check(reply.get("result") == {"success": True, "message": "location set"}, "setLocation succeeds")
    state = client.request("wayland.gamma.getState")["result"]
    check(state["config"]["Latitude"] == 52.52 and state["config"]["Longitude"] == 13.405, "the location is in the config")
    today = datetime.datetime.now().astimezone()
    _, times = ref.sun_times(52.52, 13.405, today, -6.0, 3.0)
    check(close_to(parse_time(state["sunriseTime"]), times["sunrise"], 1.5), "sunriseTime is DMS's sun model for the location")
    check(close_to(parse_time(state["dawnTime"]), times["dawn"], 1.5), "dawnTime is DMS's sun model for the location")

    reply = client.request("wayland.gamma.setManualTimes", {"sunrise": "06:30", "sunset": "18:00", "durationMinutes": 30})
    check(reply.get("result") == {"success": True, "message": "manual times set"}, "setManualTimes succeeds")
    state = client.request("wayland.gamma.getState")["result"]
    check(state["config"]["ManualSunrise"] == "0000-01-01T06:30:00Z", "ManualSunrise is Go's time.Parse of 06:30")
    check(state["config"]["ManualDuration"] == 1800000000000, "ManualDuration is 30 minutes in nanoseconds")
    local = datetime.datetime.now().astimezone().date()
    sunrise = ref.local_at(local, 6, 30)
    check(close_to(parse_time(state["sunriseTime"]), sunrise, 1.5), "manual sunriseTime is 06:30 local today")
    check(close_to(parse_time(state["dawnTime"]), sunrise - datetime.timedelta(minutes=30), 1.5),
          "manual dawnTime is sunrise minus the duration")
    check(close_to(parse_time(state["sunsetTime"]), ref.local_at(local, 18, 0), 1.5), "manual sunsetTime is 18:00 local")
    check(state["isDay"] == (sunrise <= today < ref.local_at(local, 18, 0)), "isDay follows the manual times")
    # Manual times with now inside the night window: the night temperature (4500 K) is written as a warm ramp.
    # A schedule needs low and high to differ (DMS applies a constant when they are equal).
    reply = client.request("wayland.gamma.setTemperature", {"low": 4500, "high": 6500})
    check(reply.get("result") == {"success": True, "message": "temperature set"}, "setTemperature low 4500 high 6500")
    minute = today.hour * 60 + today.minute
    rise = (minute + 120) % 1440
    fall = (minute + 240) % 1440
    before = len([line for line in wayland_lines(log) if line.startswith("gamma.set DP-1")])
    reply = client.request("wayland.gamma.setManualTimes", {"sunrise": "%02d:%02d" % divmod(rise, 60),
                                                           "sunset": "%02d:%02d" % divmod(fall, 60),
                                                           "durationMinutes": 30})
    check(reply.get("result") == {"success": True, "message": "manual times set"}, "setManualTimes for the night window")
    fresh = wait_for(lambda: len([line for line in wayland_lines(log) if line.startswith("gamma.set DP-1")]) > before)
    check(fresh is not None, "the manual schedule writes a ramp to the compositor")
    if fresh:
        last = [line for line in wayland_lines(log) if line.startswith("gamma.set DP-1")][-1]
        parts = dict(p.split("=") for p in last.split()[2:])
        check(int(parts["blue"].split(",")[1]) < int(parts["red"].split(",")[1]), "the night temperature is a warm ramp (%s)" % last)

    for params, text in [({"sunrise": "6:3x", "sunset": "18:00"}, "invalid sunrise format (use HH:MM)"),
                         ({"sunrise": "06:30", "sunset": "25:00"}, "invalid sunset format (use HH:MM)")]:
        reply = client.request("wayland.gamma.setManualTimes", params)
        check(reply.get("error") == text, "setManualTimes %s -> %r (got %r)" % (json.dumps(params), text, reply.get("error")))
    reply = client.request("wayland.gamma.setManualTimes", {"sunrise": "06:00", "sunset": "18:00", "durationMinutes": 90})
    check("transition must be 0 to one hour" in str(reply.get("error", "")), "a 90 minute ramp is refused by bleu_color")
    state = client.request("wayland.gamma.getState")["result"]
    check(state["config"]["ManualDuration"] == 1800000000000, "a refused ramp leaves the previous settings in place")

    reply = client.request("wayland.gamma.setManualTimes", {})
    check(reply.get("result") == {"success": True, "message": "manual times cleared"}, "setManualTimes with no times clears them")
    state = client.request("wayland.gamma.getState")["result"]
    check(state["config"]["ManualSunrise"] is None and state["config"]["ManualDuration"] is None, "cleared manual times and duration are null")

    reply = client.request("wayland.gamma.setUseIPLocation", {"use": True})
    check(str(reply.get("error", "")).startswith("not supported: IP geolocation"), "setUseIPLocation true is not supported")
    reply = client.request("wayland.gamma.setUseIPLocation", {"use": False})
    check(reply.get("result") == {"success": True, "message": "IP location preference set"}, "setUseIPLocation false succeeds")
    reply = client.request("wayland.gamma.setGamma", {"gamma": 1.2})
    check(str(reply.get("error", "")) == "not supported: bleu_color writes gamma 1.0 and contrast 1.0 only", "setGamma 1.2 is not supported")
    reply = client.request("wayland.gamma.setGamma", {"gamma": 1.0})
    check(reply.get("result") == {"success": True, "message": "gamma set"}, "setGamma 1.0 succeeds (the neutral value)")

    reply = client.request("wayland.icc.listOutputs")
    check(reply.get("result") == ["DP-1", "HDMI-A-1"], "icc.listOutputs lists the connected outputs, sorted")
    for method in ["wayland.gamma.subscribe", "wayland.icc.apply", "wayland.icc.getStatus", "wayland.icc.setTemp"]:
        reply = client.request(method, {"output": "DP-1", "path": "/x", "temp": 3000})
        check(str(reply.get("error", "")).startswith("not supported: "), "%s is refused" % method)

    fresh_client = DmsClient(client.path, timeout=15)
    fresh_client.subscribe(["gamma"])
    service, data, frame_id = fresh_client.next_frame()
    check(service == "server", "gamma subscription starts with `server`")
    service, data, frame_id = fresh_client.next_frame()
    check(service == "gamma" and frame_id == fresh_client.subscribe_id, "gamma subscription gets the snapshot")
    gamma_keys_ok(data, "gamma snapshot")
    fresh_client.close()

    # A warm ramp first, then disabling: the release is what the compositor sees.
    client.request("wayland.gamma.setTemperature", {"temp": 3500})
    wait_for(lambda: any(line.startswith("gamma.set DP-1") for line in wayland_lines(log)))
    destroys_before = wayland_lines(log).count("gamma.destroy DP-1")
    reply = client.request("wayland.gamma.setEnabled", {"enabled": False})
    check(reply.get("result") == {"success": True, "message": "enabled state set"}, "setEnabled false succeeds")
    check(wait_for(lambda: wayland_lines(log).count("gamma.destroy DP-1") > destroys_before) is not None,
          "disabling releases DP-1's gamma control (the compositor restores its ramp)")


def section_theme(client):
    print("== theme.auto and matugen (DMS's thememode, no Bleu backend)")
    reply = client.request("theme.auto.getState")
    state = reply.get("result", {})
    keys_are(state, ["config", "isLight", "nextTransition"], "theme.auto State")
    keys_are(state.get("config", {}), THEME_CONFIG_KEYS, "theme.auto Config")
    config = state.get("config", {})
    check(config.get("enabled") is False and config.get("mode") == "time" and config.get("startHour") == 18
          and config.get("endHour") == 6, "defaults: disabled, time mode, 18:00 to 06:00")

    reply = client.request("theme.auto.setEnabled", {"enabled": True})
    check(reply.get("result") == {"success": True, "message": "theme auto enabled set"}, "setEnabled true succeeds")
    state = client.request("theme.auto.getState")["result"]
    light, nxt = ref.time_schedule(datetime.datetime.now().astimezone(), 18, 0, 6, 0)
    check(state["isLight"] == light, "isLight of the default time schedule matches DMS's rule (%s)" % light)
    check(close_to(parse_time(state["nextTransition"]), nxt, 2.0), "nextTransition of the time schedule matches DMS's rule")

    reply = client.request("theme.auto.setSchedule", {"startHour": 9, "startMinute": 0, "endHour": 17, "endMinute": 30})
    keys_are(reply.get("result", {}), ["config", "isLight", "nextTransition"], "setSchedule reply (the state)")
    check(reply["result"]["config"]["startHour"] == 9 and reply["result"]["config"]["endMinute"] == 30,
          "setSchedule stores the new times")
    light, nxt = ref.time_schedule(datetime.datetime.now().astimezone(), 9, 0, 17, 30)
    check(reply["result"]["isLight"] == light and close_to(parse_time(reply["result"]["nextTransition"]), nxt, 2.0),
          "the 09:00 to 17:30 schedule matches DMS's rule")
    reply = client.request("theme.auto.setSchedule", {"startHour": 25, "startMinute": 0, "endHour": 17, "endMinute": 0})
    check(reply.get("error") == "invalid schedule time", "a start hour of 25 is refused")

    reply = client.request("theme.auto.setMode", {"mode": "dusk"})
    check(reply.get("error") == "invalid mode", "an unknown mode is refused")
    reply = client.request("theme.auto.setMode", {"mode": "location"})
    check(reply.get("result") == {"success": True, "message": "theme auto mode set"}, "setMode location succeeds")
    reply = client.request("theme.auto.setLocation", {"latitude": "north"})
    check(reply.get("error") == "missing or invalid 'latitude' parameter", "a non-numeric latitude is refused")
    reply = client.request("theme.auto.setLocation", {"latitude": 52.52, "longitude": 13.405})
    check(reply.get("result") == {"success": True, "message": "theme auto location set"}, "setLocation succeeds")
    state = client.request("theme.auto.getState")["result"]
    check(state["config"]["latitude"] == 52.52 and state["config"]["longitude"] == 13.405, "the location is in the config")
    now = datetime.datetime.now().astimezone()
    light, nxt = ref.location_schedule(now, 52.52, 13.405, -6.0, 3.0)
    check(state["isLight"] == light, "isLight at Berlin matches DMS's sun model (%s)" % light)
    check(close_to(parse_time(state["nextTransition"]), nxt, 2.0), "nextTransition at Berlin matches DMS's sun model")
    reply = client.request("theme.auto.setLocation", {"latitude": -33.87, "longitude": 151.21})
    state = client.request("theme.auto.getState")["result"]
    light, nxt = ref.location_schedule(now, -33.87, 151.21, -6.0, 3.0)
    check(state["isLight"] == light and close_to(parse_time(state["nextTransition"]), nxt, 2.0),
          "the same at Sydney (southern hemisphere) matches DMS's sun model")

    reply = client.request("theme.auto.setUseIPLocation", {"use": True})
    check(str(reply.get("error", "")).startswith("not supported: IP geolocation"), "setUseIPLocation true is not supported")
    reply = client.request("theme.auto.setUseIPLocation", {"use": False})
    check(reply.get("result") == {"success": True, "message": "theme auto IP location set"}, "setUseIPLocation false succeeds")
    reply = client.request("theme.auto.trigger")
    check(reply.get("result") == {"success": True, "message": "theme auto update triggered"}, "trigger succeeds")

    reply = client.request("matugen.status")
    check(reply.get("result") == {"pending": False, "running": False, "smartSupported": False}, "matugen.status: nothing queued")
    reply = client.request("matugen.queue", {"kind": "image", "value": "/x.png"})
    check(str(reply.get("error", "")).startswith("not supported: matugen palettes"), "matugen.queue is refused")
    reply = client.request("theme.auto.subscribe")
    check(str(reply.get("error", "")).startswith("not supported: a streaming method"), "theme.auto.subscribe is refused")

    fresh_client = DmsClient(client.path, timeout=15)
    fresh_client.subscribe(["theme.auto"])
    service, data, frame_id = fresh_client.next_frame()
    check(service == "server", "theme.auto subscription starts with `server`")
    service, data, frame_id = fresh_client.next_frame()
    check(service == "theme.auto" and frame_id == fresh_client.subscribe_id, "theme.auto subscription gets the snapshot")
    keys_are(data, ["config", "isLight", "nextTransition"], "theme.auto snapshot")
    fresh_client.close()
    client.request("theme.auto.setEnabled", {"enabled": False})


def section_freedesktop(client):
    print("== freedesktop (bleu_appearance over the portal mock)")
    state = client.request("freedesktop.getState")["result"]
    keys_are(state, ["accounts", "settings", "screensaver"], "FreedeskState")
    keys_are(state["accounts"], ["available", "userPath", "iconFile", "realName", "userName", "accountType",
                                 "homeDirectory", "shell", "email", "language", "location", "locked",
                                 "passwordMode", "uid"], "AccountsState")
    keys_are(state["settings"], ["available", "colorScheme"], "SettingsState")
    check(state["settings"] == {"available": True, "colorScheme": 1}, "the portal's colour scheme (1, prefer dark) is read")
    check(state["screensaver"] == {"available": False, "active": False, "inhibited": False, "inhibitors": []},
          "screensaver: not available (no ScreenSaver service in Bleu)")
    reply = client.request("freedesktop.settings.getColorScheme")
    check(reply.get("result") == {"colorScheme": 1}, "settings.getColorScheme answers {colorScheme: 1}")

    subprocess.run(["dbus-send", "--session", "--print-reply", "--dest=org.bleu.PortalMock", "/org/bleu/PortalMock",
                    "org.bleu.PortalMock.Set", "string:org.freedesktop.appearance", "string:color-scheme",
                    "variant:uint32:2"], check=True, capture_output=True, env=os.environ)
    changed = wait_for(lambda: client.request("freedesktop.getState")["result"]["settings"]["colorScheme"] == 2, timeout=10)
    check(changed is not None, "a change of the desktop's scheme (to 2, prefer light) is seen by the daemon")
    client.request("freedesktop.settings.getColorScheme")

    for method, params, text in [
        ("freedesktop.accounts.setRealName", {"name": "x"}, "not supported: user accounts are managed by AccountsService, which Bleu does not use"),
        ("freedesktop.accounts.getUserIconFile", {"username": "x"}, "not supported: user accounts are managed by AccountsService, which Bleu does not use"),
        ("freedesktop.settings.setIconTheme", {"iconTheme": "x"}, "not supported: bleu_appearance has no icon theme setter (it writes the colour scheme and the wallpaper)"),
    ]:
        reply = client.request(method, params)
        check(reply.get("error") == text, "%s is refused with its reason" % method)

    fresh_client = DmsClient(client.path, timeout=15)
    fresh_client.subscribe(["freedesktop.screensaver"])
    service, data, frame_id = fresh_client.next_frame()
    check(service == "server", "freedesktop.screensaver subscription starts with `server`")
    service, data, frame_id = fresh_client.next_frame()
    check(service == "freedesktop.screensaver" and data == {"available": False, "active": False, "inhibited": False,
                                                           "inhibitors": []}, "the screensaver snapshot is sent")
    fresh_client.close()


def main():
    sock, work, tests = sys.argv[1], sys.argv[2], sys.argv[3]
    client = DmsClient(sock, timeout=15)
    caps = client.requests.handshake.get("capabilities", [])
    present = [c for c in DMS_ORDER if c in caps]
    check(all(c in caps for c in REQUIRED), "handshake advertises freedesktop, gamma, wlroutput and theme.auto (got %s)" % caps)
    check(present == [c for c in caps if c in DMS_ORDER], "the advertised modules are in DMS's capability order (got %s)" % caps)

    section_wlroutput(client, work)
    section_gamma(client, work)
    section_theme(client)
    section_freedesktop(client)
    client.close()

    if FAILURES:
        print("%d check(s) failed" % len(FAILURES))
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
