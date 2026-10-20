#!/usr/bin/env python3
"""Drive dmsd's `network` module as the DMS shell does, against the NetworkManager mock.

    network_check.py <socket> <tests dir>

The daemon runs on a private system bus with libs/bleu_network.c3l/tests/nm_mock.py on it,
and a fake sysfs tree (tests/network.sh sets both up). Every expectation comes from one of:

* golden/network_state_initial.json, golden/network_errors.json, golden/network_unsupported.json;
* golden/network_tags.json: the field names and order of DMS's Go structs (types.go);
* the mock's access point table (nm_mock.py ACCESS_POINTS_TABLE, lines 73-77), checked here
  field by field, so a wrong value in the daemon is not hidden by the golden.

Exit status 0 when every check passed; otherwise the failed checks are printed.
"""
import json
import os
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dmsclient import DmsClient  # noqa: E402

FAILURES = []

# The mock's visible access points (nm_mock.py ACCESS_POINTS_TABLE). The hidden one is not listed.
# Each: SSID (as Bleu labels it), strength (signal percent), MHz, secured, BSSID (the mock numbers them).
MOCK_NETWORKS = [
    ("Cafe", 70, 2437, False, "02:00:00:00:00:01"),
    ("Office", 90, 5180, True, "02:00:00:00:00:02"),
    ("", 40, 2412, True, "02:00:00:00:00:03"),  # b'\xff\xfeLegacy': not UTF-8, so no label
    ("Guest-SAE", 60, 5955, True, "02:00:00:00:00:04"),
]


def check(cond, what):
    if not cond:
        FAILURES.append(what)
        print("FAIL", what)
    else:
        print("ok  ", what)


def keys_match(obj, tags, optional, what):
    """The keys of `obj` are the Go tags in order, leaving out the omitempty ones that are absent."""
    keys = list(obj.keys())
    expected = [t for t in tags if t not in optional or t in keys]
    check(keys == expected, "%s keys in Go order" % what)


def load(tests, *parts):
    with open(os.path.join(tests, "golden", *parts)) as f:
        return json.load(f)


class Net:
    """One client for requests, one for subscriptions, as the shell has."""

    def __init__(self, sock):
        self.sock = sock
        self.req = DmsClient(sock)
        self.sub = None

    def call(self, method, params=None):
        return self.req.request(method, params)

    def result(self, method, params=None):
        return self.call(method, params).get("result")

    def state(self):
        return self.result("network.getState")

    def subscribe(self, services):
        """Open a subscription to `services`; returns the service of its first frame (`server`)."""
        if self.sub is not None:
            self.sub.close()
        self.sub = DmsClient(self.sock)
        self.sub.subscribe(services)
        self.sub.subscriptions.sock.settimeout(0.5)
        service, _, _ = self.sub.next_frame()
        return service

    def frame(self, timeout=10.0):
        """The next frame as (service, data), or None when none came in `timeout` seconds."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                service, data, _ = self.sub.next_frame()
                return service, data
            except socket.timeout:
                continue
        return None

    def prompt(self, timeout=15.0):
        """The next `network.credentials` frame; other frames are skipped."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            got = self.frame(timeout=1.0)
            if got and got[0] == "network.credentials":
                return got[1]
        return None

    def wait_state(self, predicate, timeout=15.0):
        deadline = time.time() + timeout
        last = None
        while time.time() < deadline:
            last = self.state()
            if predicate(last):
                return last
            time.sleep(0.2)
        return last

    def close(self):
        self.req.close()
        if self.sub is not None:
            self.sub.close()


def check_mock_networks(state):
    nets = state["wifiNetworks"]
    check([(n["ssid"], n["signal"], n["frequency"], n["secured"], n["bssid"]) for n in nets] == MOCK_NETWORKS,
          "wifiNetworks are the mock's visible access points (SSID, signal, MHz, secured, BSSID)")


def check_shapes(state, go):
    keys_match(state, go["NetworkState"]["fields"], go["NetworkState"]["omitempty"], "NetworkState")
    for n in state["wifiNetworks"] + state["savedWifiNetworks"]:
        keys_match(n, go["WiFiNetwork"]["fields"], go["WiFiNetwork"]["omitempty"], "WiFiNetwork " + repr(n["ssid"]))
    for d in state["ethernetDevices"]:
        keys_match(d, go["EthernetDevice"]["fields"], go["EthernetDevice"]["omitempty"], "EthernetDevice " + d["name"])
    for d in state["wifiDevices"]:
        keys_match(d, go["WiFiDevice"]["fields"], go["WiFiDevice"]["omitempty"], "WiFiDevice " + d["name"])
        for n in d["networks"]:
            keys_match(n, go["WiFiNetwork"]["fields"], go["WiFiNetwork"]["omitempty"], "WiFiDevice network " + repr(n["ssid"]))


def check_errors(net, tests):
    for method, params, text in load(tests, "network_errors.json"):
        reply = net.call(method, params)
        check(reply.get("error") == text, "error for %s %s is %r (got %r)" % (method, json.dumps(params), text, reply.get("error")))


def check_unsupported(net, tests):
    for method, text in load(tests, "network_unsupported.json"):
        reply = net.call(method, {"ssid": "x", "uuid": "x", "device": "x", "preference": "x"})
        check(reply.get("error") == text, "%s answers its reason" % method)


def check_initial(net, tests, go):
    state = net.state()
    golden = load(tests, "network_state_initial.json")
    check(state == golden, "network.getState before any change equals the golden state")
    check_shapes(state, go)
    check_mock_networks(state)
    check(state["ethernetDevices"] == [{"name": "eth0", "hwAddress": "", "state": "connected", "connected": True, "speed": 1000}],
          "eth0 is up at 1000 Mbit/s (sysfs speed and carrier)")
    check(state["wifiEnabled"] is True and state["wifiDevice"] == "wlan0", "wlan0 is the Wi-Fi device, radio on")
    check(state["networkStatus"] == "disconnected" and state["wifiConnected"] is False,
          "nothing is connected at the start")
    check(state["lastError"] == "" and state["isConnecting"] is False, "no error and no connection in progress")
    check(state["savedWifiNetworks"] == [], "no visible network has a saved profile at the start")
    check([d["name"] for d in state["wifiDevices"]] == ["wlan0"], "wifiDevices lists the one Wi-Fi interface")
    check(state["cellularDevices"] == [] and state["vpnProfiles"] == [] and state["hotspotSupported"] is False,
          "cellular, VPN and hotspot are empty, as Bleu does not report them")


def check_subscriptions(net, go):
    net.subscribe(["network"])
    service, data = net.frame()
    check(service == "network", "the first frame of `network` is its snapshot")
    check(data == net.state(), "the `network` snapshot equals network.getState")
    check_shapes(data, go)


def check_wifi_flow(net, go):
    before = net.state()
    check(before["wifiEnabled"] is True, "the radio is on before the flow")

    reply = net.call("network.wifi.connect", {"ssid": "Cafe"})
    check(reply.get("result") == {"success": True, "message": "connecting"}, "wifi.connect Cafe is queued: connecting")
    state = net.wait_state(lambda s: s["wifiConnected"])
    check(state["wifiConnected"] and state["wifiSSID"] == "Cafe", "Cafe connects (open network, no passphrase)")
    check(state["networkStatus"] == "wifi" and state["lastError"] == "", "the status is wifi and no error is kept")
    check(state["wifiDevices"][0]["state"] == "connected" and state["wifiDevices"][0]["ssid"] == "Cafe",
          "the Wi-Fi device reports connected to Cafe")
    check([n["ssid"] for n in state["wifiNetworks"] if n["connected"]] == ["Cafe"], "exactly Cafe is marked connected")
    check([n["ssid"] for n in state["savedWifiNetworks"]] == ["Cafe"], "the new Cafe profile is saved")
    keys_match(state, go["NetworkState"]["fields"], go["NetworkState"]["omitempty"], "NetworkState while connected")

    reply = net.call("network.wifi.disconnect")
    check(reply.get("result") == {"success": True, "message": "disconnected"}, "wifi.disconnect answers disconnected")
    state = net.wait_state(lambda s: not s["wifiConnected"])
    check(not state["wifiConnected"] and state["networkStatus"] == "disconnected", "the disconnect shows in the state")

    check(net.result("network.wifi.toggle") == {"enabled": False}, "wifi.toggle turns the radio off and says so")
    check(net.state()["wifiEnabled"] is False, "the state shows the radio off")
    check(net.result("network.wifi.toggle") == {"enabled": True}, "wifi.toggle turns it on again")
    check(net.result("network.wifi.disable") == {"enabled": False}, "wifi.disable answers enabled false")
    check(net.state()["wifiEnabled"] is False, "wifi.disable switches the radio off")
    check(net.result("network.wifi.enable") == {"enabled": True}, "wifi.enable answers enabled true")
    check(net.state()["wifiEnabled"] is True, "wifi.enable switches the radio on")

    check(net.result("network.wifi.setAutoconnect", {"ssid": "Cafe", "autoconnect": False})
          == {"success": True, "message": "autoconnect updated"}, "setAutoconnect Cafe answers success")
    state = net.wait_state(lambda s: [n["autoconnect"] for n in s["savedWifiNetworks"] if n["ssid"] == "Cafe"] == [False])
    saved = [n for n in state["savedWifiNetworks"] if n["ssid"] == "Cafe"]
    check(len(saved) == 1 and saved[0]["autoconnect"] is False, "Cafe is saved with autoconnect off")

    check(net.result("network.wifi.forget", {"ssid": "Twin"}) == {"success": True, "message": "forgotten"},
          "forget Twin answers forgotten (two saved profiles, both removed)")
    reply = net.call("network.wifi.forget", {"ssid": "Twin"})
    check(reply.get("error") == "no saved network has this name", "a second forget of Twin is refused")

    check(net.result("network.wifi.scan") == {"success": True, "message": "scanning"}, "wifi.scan answers scanning")
    networks = net.result("network.wifi.networks")
    check(networks == net.state()["wifiNetworks"], "wifi.networks equals the networks of the state")
    for n in networks:
        keys_match(n, go["WiFiNetwork"]["fields"], go["WiFiNetwork"]["omitempty"], "wifi.networks entry " + repr(n["ssid"]))

    info = net.result("network.info", {"ssid": "Office"})
    check(list(info.keys()) == ["ssid", "bands"], "network.info keys are NetworkInfoResponse's, in order")
    check(info["bands"] == [n for n in networks if n["ssid"] == "Office"], "network.info Office bands are its one entry")


def check_credentials(net, go):
    check(net.subscribe(["network.credentials"]) == "server", "the credentials subscription opens with its server frame")

    reply = net.call("network.wifi.connect", {"ssid": "Office"})
    check(reply.get("result") == {"success": True, "message": "connecting"}, "connect Office (no password) is queued")
    prompt = net.prompt()
    check(prompt is not None, "a passphrase prompt arrives on network.credentials")
    if prompt is None:
        return
    keys_match(prompt, go["CredentialPrompt"]["fields"], go["CredentialPrompt"]["omitempty"], "CredentialPrompt")
    keys_match(prompt["fieldsInfo"][0], go["FieldInfo"]["fields"], go["FieldInfo"]["omitempty"], "FieldInfo")
    check(prompt["ssid"] == "Office" and prompt["name"] == "Office", "the prompt names Office")
    check(prompt["connType"] == "802-11-wireless" and prompt["setting"] == "802-11-wireless-security",
          "the prompt is for a Wi-Fi passphrase")
    check(prompt["fields"] == ["psk"] and prompt["fieldsInfo"] == [{"name": "psk", "label": "Password", "isSecret": True}],
          "the prompt asks for the psk field, labelled Password and secret")
    check(prompt["token"].isdigit(), "the token is the prompt's request id")
    token = prompt["token"]

    check(net.result("network.credentials.submit", {"token": token, "secrets": {"psk": "wrong"}})
          == {"success": True, "message": "credentials submitted"}, "a wrong passphrase is delivered")
    state = net.wait_state(lambda s: s["lastError"] == "The password was rejected" and not s["isConnecting"])
    check(state["lastError"] == "The password was rejected" and not state["wifiConnected"],
          "the wrong passphrase is reported as rejected")
    reply = net.call("network.credentials.submit", {"token": token, "secrets": {"psk": "correct horse"}})
    check(reply.get("error") == "no pending prompt has this token", "a token is used once")

    net.call("network.wifi.disconnect")
    time.sleep(0.5)
    net.call("network.wifi.connect", {"ssid": "Office"})
    prompt = net.prompt()
    check(prompt is not None, "a second connect asks for the passphrase again")
    if prompt is not None:
        check(net.result("network.credentials.submit", {"token": prompt["token"], "secrets": {"psk": "correct horse"}})
              == {"success": True, "message": "credentials submitted"}, "the right passphrase is delivered")
        state = net.wait_state(lambda s: s["wifiConnected"])
        check(state["wifiConnected"] and state["wifiSSID"] == "Office" and state["networkStatus"] == "wifi",
              "Office connects with the right passphrase")
        check(state["lastError"] == "", "the error is cleared once connected")
        net.call("network.wifi.disconnect")
        net.wait_state(lambda s: not s["wifiConnected"])

    net.call("network.wifi.connect", {"ssid": "Guest-SAE"})
    prompt = net.prompt()
    check(prompt is not None and prompt["ssid"] == "Guest-SAE", "Guest-SAE asks for its passphrase")
    if prompt is not None:
        reply = net.call("network.credentials.cancel", {"token": prompt["token"]})
        check(reply.get("result") == {"success": True, "message": "credentials cancelled"}, "the prompt is cancelled")
        # "A password is required" shows while the prompt is pending; the final reason comes after the cancel.
        state = net.wait_state(lambda s: s["lastError"] not in ("", "A password is required") and not s["isConnecting"])
        check(state["lastError"] == "The network did not get its password" and not state["wifiConnected"],
              "a cancelled prompt fails the connection with its reason")
        reply = net.call("network.credentials.cancel", {"token": prompt["token"]})
        check(reply.get("error") == "no pending prompt has this token", "a cancelled token is not answered twice")
    net.sub.close()
    net.sub = None


def check_stream_frames(net, go):
    """A connection event reaches the `network` subscription after the state changes."""
    net.subscribe(["network"])
    net.frame()  # the snapshot
    net.call("network.wifi.connect", {"ssid": "Cafe"})
    seen = None
    deadline = time.time() + 15
    while time.time() < deadline:
        got = net.frame(timeout=2.0)
        if got and got[0] == "network" and got[1]["wifiConnected"]:
            seen = got[1]
            break
    check(seen is not None and seen["wifiSSID"] == "Cafe", "a state change is published on `network`")
    if seen is not None:
        keys_match(seen, go["NetworkState"]["fields"], go["NetworkState"]["omitempty"], "published NetworkState")
    net.call("network.wifi.disconnect")
    net.wait_state(lambda s: not s["wifiConnected"])
    net.sub.close()
    net.sub = None


def check_handshake(sock):
    c = DmsClient(sock)
    caps = c.requests.handshake["capabilities"]
    c.close()
    check("network" in caps, "the handshake advertises network (capabilities %s)" % caps)


def main():
    sock, tests = sys.argv[1], sys.argv[2]
    go = load(tests, "network_tags.json")["structs"]
    net = Net(sock)
    check_handshake(sock)
    check_initial(net, tests, go)
    check_errors(net, tests)
    check_unsupported(net, tests)
    check_subscriptions(net, go)
    check_wifi_flow(net, go)
    check_credentials(net, go)
    check_stream_frames(net, go)
    net.close()
    if FAILURES:
        print("%d check(s) failed" % len(FAILURES))
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
