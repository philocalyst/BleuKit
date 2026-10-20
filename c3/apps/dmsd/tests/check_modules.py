#!/usr/bin/env python3
"""Drive dmsd's clipboard-less module set as the DMS shell does, and check every reply.

    check_modules.py <socket> <tests dir>

The daemon is started by modules.sh with the modules that need a bus or a display turned
off, and with a private XDG tree (golden/ and the desktop files modules.sh writes). Checked:

* the handshake: only `dgop` is advertised (clipboard is absent without a Wayland display,
  and the refused modules never advertise a capability);
* dgop.meta and dgop.modules: the field names and order of dgop's Go structs (dgop
  models/meta.go, cpu.go, memory.go, process.go; the order is the Go struct order), the
  values against /proc (CPU count, memory and swap totals, load average, process RSS and
  owners), the processes' order and limit, and the errors DMS gives;
* the mime.* methods against the XDG files modules.sh wrote (mimeapps.list and two desktop
  files, one of them a Terminal=true application that DMS's handlersForMime leaves out);
* apppicker.open and browser.open: the reply "ok", and the `browser.open_requested` frame
  a subscriber to that topic receives, with DMS's OpenEvent field order;
* every refused method: its exact `not supported: ...` text, and every DMS method of the
  no-analog modules (golden/refused_methods.json, from DMS's handler files) answers that way.

Exit status 0 when every check passed.
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dmsclient import DmsClient  # noqa: E402

FAILURES = []


def check(cond, what):
    if not cond:
        FAILURES.append(what)
        print("FAIL", what)
    else:
        print("ok  ", what)


def proc_value(path, key):
    """The first number after `key` in a /proc file, in its own unit."""
    with open(path) as f:
        for line in f:
            if line.startswith(key):
                return int(line.split()[1])
    raise KeyError(key)


def proc_meminfo_kib(key):
    return proc_value("/proc/meminfo", key + ":")


def keys_in_order(obj, expected, what):
    """The keys of `obj` are exactly `expected`, in that order."""
    check(list(obj.keys()) == expected, "%s keys in Go order: %s" % (what, list(obj.keys())))


# dgop's Go struct field order (models/meta.go SystemInfo; cpu.go CPUInfo; memory.go
# MemoryInfo; process.go ProcessInfo). Every key is written, even the ones Bleu does not
# report (as zero or empty).
CPU_KEYS = ["count", "model", "frequency", "temperature", "usage", "coreUsage", "total", "cores"]
MEMORY_KEYS = ["total", "used", "usedPercent", "free", "available", "buffers", "cached", "sreclaimable",
               "shared", "zfsArcSize", "gpuActive", "gpuReclaim", "swaptotal", "swapfree"]
PROCESS_KEYS = ["pid", "ppid", "cpu", "pticks", "memoryPercent", "memoryKB", "memoryCalculation", "rssKB",
                "rssPercent", "pssKB", "pssPercent", "username", "command", "fullCommand"]
SYSTEM_KEYS = ["loadavg", "processes", "threads", "boottime"]


def check_dgop(client, golden):
    reply = client.request("dgop.modules")
    check(reply.get("result") == {"available": ["cpu", "memory", "processes", "system"]},
          "dgop.modules lists the four modules dmsd computes")

    reply = client.request("dgop.meta", {"modules": ["cpu", "memory", "processes", "system"], "limit": 3})
    meta = reply.get("result", {})
    keys_in_order(meta, ["cpu", "memory", "processes", "system"], "dgop.meta")
    cpu = meta.get("cpu", {})
    keys_in_order(cpu, CPU_KEYS, "CPUInfo")
    with open("/proc/cpuinfo") as f:
        processors = sum(1 for line in f if line.startswith("processor"))
    check(cpu.get("count") == processors, "CPUInfo.count is the %d processors of /proc/cpuinfo" % processors)
    check(len(cpu.get("coreUsage", [])) == processors, "CPUInfo.coreUsage has one entry per processor")
    check(all(0.0 <= u <= 100.0 for u in cpu.get("coreUsage", [])), "per-core usage is a percentage")

    memory = meta.get("memory", {})
    keys_in_order(memory, MEMORY_KEYS, "MemoryInfo")
    check(memory.get("total") == proc_meminfo_kib("MemTotal") * 1024, "MemoryInfo.total equals MemTotal")
    check(memory.get("used") == memory.get("total") - memory.get("available"),
          "MemoryInfo.used is total minus available (the rule Bleu uses on every platform)")
    avail_kib = proc_meminfo_kib("MemAvailable")
    check(abs(memory.get("available", 0) - avail_kib * 1024) < 256 * 1024 * 1024,
          "MemoryInfo.available is within 256 MiB of MemAvailable (the machine moves)")
    total = memory.get("total", 0)
    check(total > 0 and abs(memory.get("usedPercent", -1) - 100.0 * memory["used"] / total) < 1e-6,
          "MemoryInfo.usedPercent is used / total")
    check(memory.get("swaptotal") == proc_meminfo_kib("SwapTotal") * 1024, "MemoryInfo.swaptotal equals SwapTotal")
    check(memory.get("swapfree") == proc_meminfo_kib("SwapFree") * 1024, "MemoryInfo.swapfree equals SwapFree")

    system = meta.get("system", {})
    keys_in_order(system, SYSTEM_KEYS, "SystemInfo")
    check(re.fullmatch(r"\d+\.\d\d \d+\.\d\d \d+\.\d\d", system.get("loadavg", "")) is not None,
          "SystemInfo.loadavg is three numbers with two decimals (%r)" % system.get("loadavg"))
    with open("/proc/loadavg") as f:
        first = float(f.read().split()[0])
    check(abs(float(system["loadavg"].split()[0]) - first) < 2.0, "SystemInfo.loadavg is near /proc/loadavg")

    procs = meta.get("processes", [])
    check(len(procs) == 3, "processes: a limit of 3 gives 3 entries (got %d)" % len(procs))
    for p in procs:
        keys_in_order(p, PROCESS_KEYS, "ProcessInfo %s" % p.get("pid"))
    cpus = [p["cpu"] for p in procs]
    check(cpus == sorted(cpus, reverse=True), "processes are sorted by CPU, busiest first")
    for p in procs:
        path = "/proc/%d/status" % p["pid"]
        if not os.path.exists(path):
            continue  # the process ended between the sample and the check
        try:
            rss = proc_value(path, "VmRSS:")
        except (KeyError, OSError):
            continue
        check(abs(p["rssKB"] - rss) <= max(rss // 5, 4096),
              "ProcessInfo %d rssKB %d is near VmRSS %d" % (p["pid"], p["rssKB"], rss))
        check(p["memoryKB"] == p["rssKB"], "ProcessInfo %d memoryKB is the RSS (Bleu's only memory figure)" % p["pid"])

    reply = client.request("dgop.meta", {"modules": ["cpu", "memory", "processes", "system"], "limit": 0})
    check("processes" not in reply.get("result", {}), "limit 0 leaves the processes out (omitempty)")

    reply = client.request("dgop.meta", {"modules": ["processes"], "noCpu": True, "limit": 2})
    check(all(p["cpu"] == 0 for p in reply.get("result", {}).get("processes", [])), "noCpu gives zero process CPU")

    reply = client.request("dgop.meta", {"modules": ["processes"], "sort": "memory", "limit": 2})
    check("processes" not in reply.get("result", {}), "a sort other than cpu leaves the processes out (not served)")

    reply = client.request("dgop.meta", {"modules": ["gpu", "cpu"]})
    check(list(reply.get("result", {}).keys()) == ["cpu"],
          "a module Bleu cannot serve is left out, as DMS leaves out a failed module")

    reply = client.request("dgop.meta", {"modules": ["all"], "limit": 1})
    check(list(reply.get("result", {}).keys()) == ["cpu", "memory", "processes", "system"],
          "'all' gives every served module, in dgop's order")

    reply = client.request("dgop.meta", {"modules": []})
    check(reply.get("error") == "modules is required", "dgop.meta with no modules: 'modules is required'")
    reply = client.request("dgop.meta", {"modules": ["bogus"]})
    check(reply.get("error") == "unknown module: bogus", "dgop.meta with an unknown module: 'unknown module: bogus'")

    for method in ["dgop.gpu", "dgop.hardware"]:
        reply = client.request(method)
        check(reply.get("error", "").startswith("not supported: "), "%s is refused with `not supported`" % method)


def check_mime(client):
    reply = client.request("mime.getDefault", {"mimeType": "text/html; charset=utf-8"})
    check(reply.get("result") == {"mimeType": "text/html", "desktopId": "firefox.desktop"},
          "mime.getDefault strips the parameters and reads mimeapps.list")
    reply = client.request("mime.getDefault", {"mimeType": "text/plain"})
    check(reply.get("result") == {"mimeType": "text/plain", "desktopId": "vim.desktop"},
          "mime.getDefault falls back to the first desktop file that declares the type")
    reply = client.request("mime.getDefault", {"mimeType": "application/x-none"})
    check(reply.get("result") == {"mimeType": "application/x-none", "desktopId": ""},
          "mime.getDefault for a type with no application is an empty desktopId")
    reply = client.request("mime.getDefault", {"path": "/tmp/page.html"})
    check(reply.get("error", "").startswith("not supported: "), "mime.getDefault by path is refused (no glob table)")
    reply = client.request("mime.getDefault", {})
    check(reply.get("error") == "missing 'mimeType' or 'path' parameter", "mime.getDefault with neither: DMS's text")
    reply = client.request("mime.getDefault", {"mimeType": "  ;x"})
    check(reply.get("error") == "invalid 'mimeType' parameter", "mime.getDefault of an empty type: invalid")

    reply = client.request("mime.appsForMime", {"mimeType": "text/html"})
    check(reply.get("result") == {"mimeType": "text/html", "desktopIds": ["firefox.desktop"]},
          "mime.appsForMime lists the associated desktop IDs")
    reply = client.request("mime.appsForMime", {"mimeType": "application/x-none"})
    check(reply.get("result") == {"mimeType": "application/x-none", "desktopIds": []},
          "mime.appsForMime with none is an empty list, not null")

    reply = client.request("mime.handlersForMime", {"mimeType": "text/html"})
    check(reply.get("result") == {"mimeType": "text/html", "apps": [
        {"id": "firefox.desktop", "name": "Firefox", "icon": "firefox"}]},
        "mime.handlersForMime gives id, name and icon from the catalogue")
    reply = client.request("mime.handlersForMime", {"mimeType": "text/plain"})
    check(reply.get("result") == {"mimeType": "text/plain", "apps": []},
          "mime.handlersForMime leaves out a Terminal=true application, as DMS does")

    reply = client.request("mime.queryDefaults", {"mimeTypes": ["text/plain", "text/html;x", "text/html", ""]})
    check(reply.get("result") == {"defaults": {"text/html": "firefox.desktop", "text/plain": "vim.desktop"}},
          "mime.queryDefaults maps each canonical type to its default")
    raw = raw_request(client, "mime.queryDefaults", {"mimeTypes": ["text/plain", "text/html"]})
    check(raw.startswith('{"id":') and '"result":{"defaults":{"text/html":"firefox.desktop","text/plain":"vim.desktop"}}' in raw,
          "mime.queryDefaults writes its keys in byte order, as Go's map encoding does (%s)" % raw[:90])
    reply = client.request("mime.queryDefaults", {"mimeTypes": "text/html"})
    check(reply.get("error") == "missing or invalid 'mimeTypes' parameter", "mime.queryDefaults: not an array")
    reply = client.request("mime.queryDefaults", {"mimeTypes": [" ", ""]})
    check(reply.get("error") == "no valid mime types provided", "mime.queryDefaults: nothing valid")

    reply = client.request("mime.setDefault", {"mimeType": "text/html", "desktopId": "vim.desktop"})
    check(reply.get("error", "").startswith("not supported: "), "mime.setDefault is refused (no writer)")
    reply = client.request("mime.setDefaults", {"mimeTypes": ["text/html"], "desktopId": "vim.desktop"})
    check(reply.get("error", "").startswith("not supported: "), "mime.setDefaults is refused (no writer)")
    reply = client.request("mime.invalidate")
    check(reply.get("result") == {"success": True}, "mime.invalidate answers success (there is no cache to drop)")


def raw_request(client, method, params):
    """The reply line exactly as dmsd wrote it (key order and spacing included)."""
    req_id = client.next_id()
    client.requests.send({"id": req_id, "method": method, "params": params})
    while True:
        line = client.requests.reader.readline().decode().strip()
        if json.loads(line).get("id") == req_id:
            return line


def check_apppicker(client):
    client.subscribe(["browser.open_requested"])
    service, data, frame_id = client.next_frame()  # the `server` frame that opens every subscription
    check(service == "server", "the subscription opens with the server frame")
    reply = client.request("apppicker.open", {"url": "https://example.org", "mimeType": "text/html; charset=utf-8",
                                              "categories": ["Network", 3]})
    check(reply.get("result") == "ok", "apppicker.open answers \"ok\"")
    service, data, frame_id = client.next_frame()
    check(service == "browser.open_requested", "the open request reaches browser.open_requested subscribers")
    check(frame_id == client.subscribe_id, "the open frame carries the subscribe id")
    keys_in_order(data, ["target", "mimeType", "categories", "requestType"], "OpenEvent")
    check(data == {"target": "https://example.org", "mimeType": "text/html", "categories": ["Network"],
                   "requestType": "url"},
          "OpenEvent carries the target, the bare mime type and the string categories")

    reply = client.request("browser.open", {"target": "/tmp/x.pdf", "requestType": "file"})
    check(reply.get("result") == "ok", "browser.open is the same method")
    service, data, frame_id = client.next_frame()
    check(data == {"target": "/tmp/x.pdf", "requestType": "file"},
          "OpenEvent omits mimeType and categories when empty")

    reply = client.request("apppicker.open", {})
    check(reply.get("error") == "invalid target parameter", "apppicker.open without a target: DMS's text")


def check_evdev_and_refusals(client, golden):
    reply = client.request("evdev.getState")
    check(reply.get("error", "").startswith("not supported: "), "evdev.getState is refused (no lock-key source)")
    check(client.request("clipboard.getState").get("error") == "unknown method: clipboard.getState",
          "clipboard methods are unknown when the clipboard is absent")
    check(client.request("location.getState").get("error") == "unknown method: location.getState",
          "location (no Bleu analog, not in this module set) is unknown, not refused")

    for module, entry in golden["modules"].items():
        bad = []
        for method in entry["methods"]:
            reply = client.request(method, None)
            if not str(reply.get("error", "")).startswith("not supported: "):
                bad.append((method, reply))
        check(not bad, "every DMS %s method answers `not supported` (%d methods)%s" % (
            module, len(entry["methods"]), "" if not bad else ": " + str(bad[:2])))


def main():
    sock, tests = sys.argv[1], sys.argv[2]
    with open(os.path.join(tests, "golden", "refused_methods.json")) as f:
        golden = json.load(f)

    client = DmsClient(sock)
    check(client.requests.handshake == {"apiVersion": 38, "capabilities": ["dgop"]},
          "handshake advertises only dgop: %s" % client.requests.handshake)

    check_dgop(client, golden)
    check_mime(client)
    check_apppicker(client)
    check_evdev_and_refusals(client, golden)

    client.close()
    if FAILURES:
        print("%d check(s) failed" % len(FAILURES))
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
