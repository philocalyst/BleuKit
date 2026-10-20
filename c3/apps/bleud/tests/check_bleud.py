#!/usr/bin/env python3
"""End-to-end checks for bleud, driven over its Unix socket (stdlib only).

usage: check_bleud.py BLEUD BLEUCTL WORKDIR

Starts bleud on a fake sysfs tree (battery), and a second bleud on the real
system (sysinfo), then checks the protocol: handshake, every built-in method,
command results and error strings, a watch that sees a new generation when the
fake tree changes, concurrent clients, and a client that disconnects mid-request.
Exit status 0 when every check passes.
"""
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time

BLEUD, BLEUCTL, WORK = sys.argv[1], sys.argv[2], sys.argv[3]
FAKE = os.path.join(WORK, "fakeroot")
SUPPLY = os.path.join(FAKE, "sys/class/power_supply")
ERROR_SHAPE = re.compile(r"^[A-Z_]+: .+$")  # "<STATUS>: <message>"
failures = []


def check(name, condition, detail=""):
    print(("ok   " if condition else "FAIL ") + name + ("" if condition else f"  [{detail}]"))
    if not condition:
        failures.append(name)


def make_fake_tree():
    """A battery on mains-less discharge, an empty mains adapter and one backlight."""
    os.makedirs(os.path.join(SUPPLY, "BAT0"))
    os.makedirs(os.path.join(SUPPLY, "AC"))
    values = {
        "BAT0/type": "Battery", "BAT0/present": "1", "BAT0/status": "Discharging",
        "BAT0/capacity": "80", "BAT0/energy_now": "40000000", "BAT0/energy_full": "50000000",
        "BAT0/energy_full_design": "60000000", "BAT0/power_now": "10000000",
        "BAT0/cycle_count": "120", "BAT0/technology": "Li-ion",
        "AC/type": "Mains", "AC/online": "0",
    }
    for rel, text in values.items():
        with open(os.path.join(SUPPLY, rel), "w") as f:
            f.write(text + "\n")
    backlight = os.path.join(FAKE, "sys/class/backlight/intel_backlight")
    os.makedirs(backlight)
    for rel, text in {"brightness": "400", "max_brightness": "1000",
                      "actual_brightness": "400", "type": "firmware"}.items():
        with open(os.path.join(backlight, rel), "w") as f:
            f.write(text + "\n")


def set_battery(name, text):
    with open(os.path.join(SUPPLY, "BAT0", name), "w") as f:
        f.write(text + "\n")


def start_daemon(sock, services, root=None):
    args = [BLEUD, "--services", services, "--socket", sock]
    if root:
        args += ["--fake-root", root]
    log = open(sock + ".log", "w")
    proc = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT)
    for _ in range(300):
        if os.path.exists(sock):
            break
        if proc.poll() is not None:
            break
        time.sleep(0.02)
    time.sleep(0.1)
    return proc


def connect(sock):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(20)
    s.connect(sock)
    return s, s.makefile("rb")


def call(sock, method, params=None, rid=1):
    """One request on a fresh connection: returns (handshake, reply dict)."""
    s, f = connect(sock)
    handshake = json.loads(f.readline())
    body = {"id": rid, "method": method, "params": params if params is not None else {}}
    s.sendall((json.dumps(body) + "\n").encode())
    reply = json.loads(f.readline())
    s.close()
    return handshake, reply


def main():
    shutil.rmtree(FAKE, ignore_errors=True)
    make_fake_tree()
    sock = os.path.join(WORK, "bleud.sock")
    daemon = start_daemon(sock, "battery,brightness", FAKE)
    try:
        run_checks(sock)
    finally:
        daemon.terminate()
        daemon.wait(10)
    print_log(sock)
    run_real_sysinfo()
    print("\n%d failure(s)" % len(failures))
    return 1 if failures else 0


def print_log(sock):
    with open(sock + ".log") as f:
        text = f.read().strip()
    if text:
        print("bleud log:\n" + text)


def run_checks(sock):
    hs, reply = call(sock, "battery.state")
    check("handshake lists the capabilities",
          hs.get("apiVersion") == 1 and "commands" in hs.get("capabilities", []), hs)
    check("battery.state is ok with a generation and a state",
          reply.get("result", {}).get("ok") is True and "generation" in reply["result"]
          and reply["result"]["state"]["sources"][1]["id"] == "BAT0", reply)
    bat = reply["result"]["state"]["sources"][1]
    check("battery charge is the fake 0.8", abs(bat["charge"] - 0.8) < 1e-6, bat.get("charge"))
    check("battery power is negative when discharging", bat["power"] == -10000, bat.get("power"))

    _, reply = call(sock, "battery.capabilities")
    caps = reply.get("result", {}).get("capabilities", [])
    check("capabilities list every Cap with a reason",
          caps and all("cap" in c and "reason" in c and "note" in c for c in caps), reply)

    _, reply = call(sock, "battery.backend")
    check("backend names sysfs", reply.get("result") == {"ok": True, "backend": "sysfs"}, reply)

    _, reply = call(sock, "battery.refresh")
    check("a command returns ok", reply.get("result") == {"ok": True}, reply)

    _, reply = call(sock, "battery.nope")
    check("an unknown method is an error line", "error" in reply and "unknown method" in reply["error"], reply)

    _, reply = call(sock, "network.state")
    err = reply.get("error", "")
    check("a service that is not open is an UNAVAILABLE error string",
          err.startswith("UNAVAILABLE: ") and ERROR_SHAPE.match(err) is not None, reply)

    _, reply = call(sock, "brightness.set", {"device": "nope", "level": 0.5})
    err = reply.get("error", "")
    check("a missing device is NOT_FOUND with the message",
          err.startswith("NOT_FOUND: ") and "nope" in err, reply)

    _, reply = call(sock, "brightness.set", {"device": "intel_backlight"})
    err = reply.get("error", "")
    check("a missing parameter is INVALID_ARGUMENT", err.startswith("INVALID_ARGUMENT: "), reply)

    _, reply = call(sock, "services")
    names = [s["name"] for s in reply.get("result", {}).get("services", [])]
    check("services lists all 20 services in table order",
          len(names) == 20 and names[0] == "battery", names)
    check("services reports the unselected services as not selected",
          any(s.get("reason") == "not selected" for s in reply["result"]["services"]), reply)

    check_watch(sock)
    check_concurrency(sock)
    check_dropped_client(sock)


def check_watch(sock):
    """A watch gets the current state, then a new generation after the fake tree changes."""
    s, f = connect(sock)
    s.sendall(b'{"id":7,"method":"subscribe","params":{"services":["battery"]}}\n')
    generations = []
    deadline = time.time() + 25
    changed = False
    while time.time() < deadline and len(generations) < 2:
        line = f.readline()
        if not line:
            break
        frame = json.loads(line)
        result = frame.get("result", {})
        if result.get("service") == "battery":
            generations.append(result["data"]["generation"])
            if not changed:
                set_battery("energy_now", "20000000")
                changed = True
    s.close()
    check("a watch sees the current state and then a newer generation",
          len(generations) == 2 and generations[1] > generations[0], generations)


def check_concurrency(sock):
    """Many clients at once, each asking several things; every reply must be right."""
    results = []
    lock = threading.Lock()

    def worker(n):
        ok = True
        for k in range(5):
            # Ids start at 1: the server leaves a zero id out of its replies.
            rid = n * 10 + k + 1
            _, reply = call(sock, "battery.state", rid=rid)
            if reply.get("id") != rid or reply.get("result", {}).get("ok") is not True:
                print("   battery.state for client %d, call %d: %s" % (n, k, str(reply)[:160]))
                ok = False
            _, reply = call(sock, "network.state", rid=rid)
            if not reply.get("error", "").startswith("UNAVAILABLE: "):
                print("   network.state for client %d, call %d: %s" % (n, k, str(reply)[:160]))
                ok = False
        with lock:
            results.append(ok)
            if not ok:
                print("   concurrent client %d got a wrong reply" % n)

    threads = [threading.Thread(target=worker, args=(n,)) for n in range(25)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(60)
    check("25 concurrent clients get correct replies", len(results) == 25 and all(results),
          "%d of 25 finished, %d right" % (len(results), sum(results)))


def check_dropped_client(sock):
    """A client that sends a request and hangs up does not stop the daemon."""
    s, f = connect(sock)
    f.readline()
    s.sendall(b'{"id":9,"method":"battery.state","params":{}}\n')
    s.close()
    time.sleep(0.2)
    _, reply = call(sock, "battery.backend")
    check("the daemon survives a client that hangs up", reply.get("result", {}).get("ok") is True, reply)


def run_real_sysinfo():
    """sysinfo on the real system: no fake root, so the numbers are the machine's own."""
    sock = os.path.join(WORK, "real.sock")
    daemon = start_daemon(sock, "sysinfo")
    try:
        _, reply = call(sock, "sysinfo.state")
        state = reply.get("result", {}).get("state", {})
        check("sysinfo state is read from the real system",
              reply.get("result", {}).get("ok") is True and state.get("cpu", {}).get("cores"), reply)
    finally:
        daemon.terminate()
        daemon.wait(10)


if __name__ == "__main__":
    sys.exit(main())
