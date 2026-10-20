#!/usr/bin/env python3
"""Black-box test of the bleu notification centre (the freedesktop server).

Run by run.sh on a private session bus. The C3 server is a child process driven
through stdin/stdout (see server_main.c3); the D-Bus side is python-dbus-next acting
as an application (Notify, CloseNotification, GetCapabilities, GetServerInformation)
and as a listener of the server's signals.

Usage: notify_server_test.py <server-binary> <sender-binary>
Every check prints PASS or FAIL; the process exits 1 if any failed.
"""
import asyncio
import os
import re
import subprocess
import sys
from asyncio.subprocess import PIPE

from dbus_next import Message, MessageType, Variant
from dbus_next.aio import MessageBus

SERVER = sys.argv[1]
SENDER = sys.argv[2]
DEST = "org.freedesktop.Notifications"
PATH = "/org/freedesktop/Notifications"
IFACE = "org.freedesktop.Notifications"
NOT_FOUND = "org.freedesktop.Notifications.Error.NotFound"

failures = []
checks = 0


def check(name, ok, detail=""):
    global checks
    checks += 1
    if ok:
        print("PASS", name)
    else:
        failures.append(name)
        print("FAIL", name, detail)


class Centre:
    """One server process, driven through its stdin."""

    def __init__(self, args=()):
        self.args = list(args)
        self.proc = None
        self.first_line = None
        self.events = []

    async def start(self):
        self.proc = await asyncio.create_subprocess_exec(
            SERVER, *self.args, stdin=PIPE, stdout=PIPE, stderr=PIPE)
        self.first_line = await self.line()
        return self.first_line

    async def line(self):
        raw = await asyncio.wait_for(self.proc.stdout.readline(), 15)
        return raw.decode().rstrip("\n")

    async def cmd(self, text):
        self.proc.stdin.write((text + "\n").encode())
        await self.proc.stdin.drain()
        lines = []
        while True:
            l = await self.line()
            if l == "END":
                return lines
            if l.startswith("EVENT "):
                self.events.append(l)
                continue
            lines.append(l)

    async def events_so_far(self):
        """Events printed up to now. The event thread may lag a reply, so wait a moment and sync."""
        await asyncio.sleep(0.1)
        await self.cmd("sync")
        return list(self.events)

    async def state(self):
        return parse_state(await self.cmd("state"))

    async def quit(self):
        await self.cmd("quit")
        return await asyncio.wait_for(self.proc.wait(), 10)


NOTE_KEYS = ["id", "urgency", "expires", "summary", "app", "icon", "category", "desktop",
             "tag", "resident", "transient", "suppress", "sound_name", "sound_file",
             "progress", "image_path"]
NOTE_SPLIT = re.compile(r" (?=(?:%s)=)" % "|".join(NOTE_KEYS))


def parse_note(line):
    head, _, rest = line.partition(" ")
    note = {"kind": head, "body": [], "actions": [], "image": None}
    for part in NOTE_SPLIT.split(rest):
        key, _, value = part.partition("=")
        note[key] = value
    note["id"] = int(note["id"])
    note["urgency"] = int(note["urgency"])
    note["expires"] = int(note["expires"])
    note["resident"] = int(note["resident"])
    note["transient"] = int(note["transient"])
    note["progress"] = int(note["progress"])
    return note


def parse_state(lines):
    st = {"header": {}, "active": [], "history": []}
    last = None
    for l in lines:
        if l.startswith("STATE "):
            st["header"] = dict(kv.split("=", 1) for kv in l.split()[1:])
        elif l.startswith(("ACTIVE ", "HISTORY ")):
            last = parse_note(l)
            st["active" if l.startswith("ACTIVE ") else "history"].append(last)
        elif l.startswith("SPAN "):
            m = re.match(r"SPAN id=(\d+) bold=(\d) italic=(\d) underline=(\d) link=(.*?) text=(.*)$", l)
            last["body"].append({"bold": m[2] == "1", "italic": m[3] == "1",
                                 "underline": m[4] == "1", "link": m[5], "text": m[6]})
        elif l.startswith("ACTION "):
            m = re.match(r"ACTION id=(\d+) key=(\S+) label=(.*)$", l)
            last["actions"].append((m[2], m[3]))
        elif l.startswith("IMAGE "):
            last["image"] = dict(kv.split("=", 1) for kv in l.split()[2:])
    return st


def find(state, note_id):
    for n in state["active"] + state["history"]:
        if n["id"] == note_id:
            return n
    return None


def in_active(state, note_id):
    return any(n["id"] == note_id for n in state["active"])


def in_history(state, note_id):
    return any(n["id"] == note_id for n in state["history"])


class Listener:
    """Collects the server's signals as seen on the bus."""

    def __init__(self, bus):
        self.signals = []
        bus.add_message_handler(self.on_message)

    def on_message(self, msg):
        if msg.message_type == MessageType.SIGNAL and msg.interface == IFACE:
            self.signals.append((msg.member, list(msg.body)))

    def closed(self, note_id=None):
        """(id, reason) of every NotificationClosed seen, optionally for one id."""
        return [(b[0], b[1]) for m, b in self.signals if m == "NotificationClosed"
                and (note_id is None or b[0] == note_id)]

    def actions(self, note_id=None):
        return [(b[0], b[1]) for m, b in self.signals if m == "ActionInvoked"
                and (note_id is None or b[0] == note_id)]

    async def wait_for(self, predicate, timeout=5.0):
        end = asyncio.get_running_loop().time() + timeout
        while asyncio.get_running_loop().time() < end:
            if predicate():
                return True
            await asyncio.sleep(0.02)
        return predicate()


async def call(bus, member, signature="", body=None):
    msg = Message(destination=DEST, path=PATH, interface=IFACE, member=member,
                  signature=signature, body=body or [])
    return await bus.call(msg)


async def notify(bus, summary="s", body="", actions=None, hints=None, expire=-1,
                 replaces=0, app="pytest", icon="", signature_only=False):
    reply = await call(bus, "Notify", "susssasa{sv}i",
                       [app, replaces, icon, summary, body, actions or [], hints or {}, expire])
    if reply.message_type == MessageType.ERROR:
        raise RuntimeError(reply.error_name)
    return reply.body[0]


def image_payload(width, height, rowstride, alpha, bits, channels, data):
    return Variant("(iiibiiay)", [width, height, rowstride, alpha, bits, channels, bytes(data)])


def run_sender(args):
    """Run the C3 sender with `args`; returns its BACKEND, SENT id and exit status."""
    done = subprocess.run([SENDER] + args, capture_output=True, text=True, timeout=30,
                          env=os.environ.copy())
    result = {"exit": done.returncode}
    for line in done.stdout.splitlines():
        if line.startswith("BACKEND "):
            result["backend"] = line.split(" ", 1)[1]
        elif line.startswith("SENT "):
            result["id"] = int(line.split(" ", 1)[1])
        elif line.startswith("SEND err="):
            result["error"] = line
    return result


async def main():
    bus = await MessageBus().connect()
    listener = Listener(bus)
    await bus.call(Message(destination="org.freedesktop.DBus", path="/org/freedesktop/DBus",
                           interface="org.freedesktop.DBus", member="AddMatch", signature="s",
                           body=["type='signal',interface='org.freedesktop.Notifications'"]))

    centre = Centre()
    first = await centre.start()
    check("server opens and names itself", first == "READY fdo", first)

    info = await call(bus, "GetServerInformation")
    check("GetServerInformation answers name, vendor, version, spec",
          list(info.body) == ["bleu", "Bleu", "0.1", "1.3"], str(info.body))
    caps = await call(bus, "GetCapabilities")
    check("GetCapabilities advertises actions and body markup",
          set(caps.body[0]) == {"actions", "body", "body-markup"}, str(caps.body))

    # 1. Every standard hint, one notification.
    pixels = [0x10] * 12
    hints = {
        "urgency": Variant("y", 1),
        "category": Variant("s", "im.received"),
        "desktop-entry": Variant("s", "chat"),
        "image-data": image_payload(2, 2, 6, False, 8, 3, pixels),
        "image-path": Variant("s", "file:///x.png"),
        "sound-name": Variant("s", "message-new-instant"),
        "sound-file": Variant("s", "/x.oga"),
        "value": Variant("i", 42),
        "x-canonical-private-synchronous": Variant("s", "stack-a"),
        "x-vendor-foo": Variant("s", "ignored"),
        "x": Variant("i", 10),
        "y": Variant("i", 20),
        "action-icons": Variant("b", True),
        "resident": Variant("b", False),
        "transient": Variant("b", False),
        "suppress-sound": Variant("b", False),
    }
    body = "x <i>it</i> &amp; <a href='https://e.org'>link</a> <img alt='pic'>"
    a = await notify(bus, "Hello", body, ["default", "Open", "dismiss", "Dismiss"], hints, -1, icon="dialog-information")
    check("Notify returns a non-zero id", a > 0, str(a))
    st = await centre.state()
    note = find(st, a)
    check("every hint reaches the state", note is not None and note["urgency"] == 1
          and note["category"] == "im.received" and note["desktop"] == "chat"
          and note["sound_name"] == "message-new-instant" and note["sound_file"] == "/x.oga"
          and note["progress"] == 42 and note["tag"] == "stack-a" and note["image_path"] == "file:///x.png"
          and note["app"] == "pytest" and note["icon"] == "dialog-information", str(note))
    check("normal urgency with -1 expires by the server default", note is not None and note["expires"] == 1)
    check("body becomes plain runs with bold/italic/link and alt text",
          note is not None and [(r["text"], r["italic"], r["link"]) for r in note["body"]] ==
          [("x ", False, ""), ("it", True, ""), (" & ", False, ""), ("link", False, "https://e.org"),
           (" pic", False, "")], str(note and note["body"]))
    check("actions keep their order", note is not None and note["actions"] ==
          [("default", "Open"), ("dismiss", "Dismiss")], str(note and note["actions"]))
    check("image-data is decoded into pixels", note is not None and note["image"] is not None
          and note["image"]["width"] == "2" and note["image"]["bytes"] == "12"
          and note["image"]["sum"] == str(12 * 0x10), str(note and note["image"]))

    # 2. Critical never expires, whatever is asked.
    b = await notify(bus, "Critical", hints={"urgency": Variant("y", 2)}, expire=1000)
    note = find(await centre.state(), b)
    check("critical notification does not expire", note is not None and note["urgency"] == 2
          and note["expires"] == 0, str(note))

    # 3. Expiry: a 300 ms notification closes itself with reason 1 (expired).
    c = await notify(bus, "Short", expire=300)
    ok = await listener.wait_for(lambda: (c, 1) in listener.closed(c), 5)
    st = await centre.state()
    check("timeout closes with reason 1 (expired)", ok, str(listener.closed(c)))
    events = await centre.events_so_far()
    check("the subscription reports the expiry as CLOSED reason 1",
          f"EVENT CLOSED id={c} replaced=0 reason=1 key=" in events, str(events))
    check("expired notification moves to history", in_history(st, c) and not in_active(st, c))

    # 4. Replacement by id keeps the id and sends no close for the old one.
    d = await notify(bus, "first")
    d2 = await notify(bus, "second", replaces=d)
    st = await centre.state()
    check("replaces_id returns the same id", d2 == d, f"{d} {d2}")
    check("replacement shows the new text in place", find(st, d)["summary"] == "second")
    check("replacement sends no NotificationClosed for the old one", listener.closed(d) == [])
    events = await centre.events_so_far()
    check("the subscription reports the replacement as POSTED replaced=1",
          f"EVENT POSTED id={d} replaced=1 reason=0 key=" in events, str(events))

    # 5. Stack tags: the second notification takes the first one's place.
    e = await notify(bus, "stack one", hints={"x-dunst-stack-tag": Variant("s", "grp")})
    f = await notify(bus, "stack two", hints={"x-dunst-stack-tag": Variant("s", "grp")})
    st = await centre.state()
    check("a matching stack tag replaces the open notification", e == f and find(st, e)["summary"] == "stack two")

    # 6. CloseNotification from the bus: reason 3, and NotFound for an unknown id.
    g = await notify(bus, "to close")
    reply = await call(bus, "CloseNotification", "u", [g])
    ok = await listener.wait_for(lambda: (g, 3) in listener.closed(g))
    check("CloseNotification closes with reason 3", reply.message_type == MessageType.METHOD_RETURN and ok)
    reply = await call(bus, "CloseNotification", "u", [999999])
    check("CloseNotification of an unknown id is an error", reply.message_type == MessageType.ERROR
          and reply.error_name == NOT_FOUND, str(reply.error_name))

    # 7. Actions from the shell: ActionInvoked, then close unless resident.
    h = await notify(bus, "actionable", actions=["default", "Open", "dismiss", "Dismiss"])
    out = await centre.cmd(f"invoke {h} dismiss")
    ok = await listener.wait_for(lambda: (h, 3) in listener.closed(h))
    check("invoke emits ActionInvoked with the key", (h, "dismiss") in listener.actions(h), str(listener.actions(h)))
    check("a non-resident notification closes after its action (reason 3)", ok and out == ["INVOKE ok"], str(out))
    order = [m for m, b in listener.signals if b and b[0] == h]
    check("ActionInvoked comes before NotificationClosed", order == ["ActionInvoked", "NotificationClosed"], str(order))
    events = await centre.events_so_far()
    check("the shell's subscription hears ACTION_INVOKED and the close",
          f"EVENT ACTION_INVOKED id={h} replaced=0 reason=0 key=dismiss" in events
          and f"EVENT CLOSED id={h} replaced=0 reason=3 key=" in events, str(events))

    r = await notify(bus, "resident", actions=["default", "Open"], hints={"resident": Variant("b", True)})
    out = await centre.cmd(f"invoke {r} default")
    await asyncio.sleep(0.2)
    check("a resident notification stays open after its action", out == ["INVOKE ok"] and
          in_active(await centre.state(), r) and not listener.closed(r))

    out = await centre.cmd(f"invoke {r} nothere")
    check("an unknown action key is refused", out and out[0].startswith("INVOKE err="), str(out))

    # 8. Shell close with an explicit reason.
    j = await notify(bus, "dismissed by user")
    out = await centre.cmd(f"close {j} 2")
    ok = await listener.wait_for(lambda: (j, 2) in listener.closed(j))
    check("the shell's close emits the given reason (2, dismissed)", out == ["CLOSE ok"] and ok, str(out))
    events = await centre.events_so_far()
    check("the subscription reports the shell's close with reason 2",
          f"EVENT CLOSED id={j} replaced=0 reason=2 key=" in events, str(events))

    # 9. Do-not-disturb: normal notifications are recorded, critical ones show.
    await centre.cmd("dnd 1")
    quiet = await notify(bus, "quiet")
    loud = await notify(bus, "loud", hints={"urgency": Variant("y", 2)})
    st = await centre.state()
    check("do-not-disturb keeps normal notifications out of view", in_history(st, quiet) and not in_active(st, quiet))
    check("do-not-disturb lets critical notifications through", in_active(st, loud))
    check("the state reports do-not-disturb", st["header"].get("dnd") == "1", str(st["header"]))
    await centre.cmd("dnd 0")

    before_clear = len((await centre.state())["history"])
    out = await centre.cmd("clear")
    after_clear = len((await centre.state())["history"])
    check("clear drops the history and keeps open notifications",
          out == ["CLEAR ok"] and before_clear > 0 and after_clear == 0 and in_active(await centre.state(), loud),
          f"before={before_clear} after={after_clear}")

    # 10. Malformed hint types and invalid images are ignored, not fatal.
    m = await notify(bus, "malformed", hints={
        "urgency": Variant("s", "urgent"),
        "image-data": image_payload(2, 2, 6, False, 16, 3, [0] * 12),
    })
    note = find(await centre.state(), m)
    check("a malformed hint is skipped and the notification still shows",
          m > 0 and note is not None and note["urgency"] == 1 and note["image"] is None, str(note))

    # 11. Long bodies are bounded, and long summaries too.
    big = await notify(bus, "long", body="a" * 10000)
    note = find(await centre.state(), big)
    total = sum(len(r["text"]) for r in note["body"])
    check("the body is cut to the 8192-byte limit", total == 8192, str(total))

    # 12. Eviction: a full centre closes its oldest normal notification with reason 4.
    before = len((await centre.state())["active"])
    for k in range(25):
        await notify(bus, f"flood {k}")
    st = await centre.state()
    evicted = [i for i, reason in listener.closed() if reason == 4]
    check("the open count is capped and eviction uses reason 4", len(st["active"]) <= 20 and len(evicted) > 0,
          f"active={len(st['active'])} before={before} evicted={evicted}")

    # 13. No ActivationToken is ever sent: the capability is absent.
    check("no ActivationToken signal is emitted", all(m != "ActivationToken" for m, _ in listener.signals))

    # 16. The C3 sender sends through the same interface: send, replace, expire.
    sent = run_sender(["Sent by C3", "from the sender", "--action", "open", "Open"])
    sid = sent.get("id")
    st = await centre.state()
    note = find(st, sid) if sid else None
    check("the C3 sender posts through Notify and the centre shows it",
          sent.get("backend") == "fdo" and note is not None and note["summary"] == "Sent by C3"
          and note["app"] == "notify-send-test" and note["expires"] == 1
          and [r["text"] for r in note["body"]] == ["from the sender"] and note["actions"] == [("open", "Open")],
          str(sent) + " " + str(note))
    again = run_sender(["Replaced by C3", "--replace", str(sid)])
    st = await centre.state()
    check("a replacing send returns the replaced id", again.get("id") == sid and find(st, sid)["summary"] == "Replaced by C3",
          str(again))
    short = run_sender(["Short by C3", "--expire", "250"])
    ok = await listener.wait_for(lambda: (short.get("id"), 1) in listener.closed(short.get("id")), 5)
    check("a sender's expiry closes with reason 1", ok, str(short))
    bad = run_sender(["Bad urgency", "--replace", "not-a-number"])
    check("the sender reports a bad option instead of sending", "error" in bad or bad.get("exit", 0) != 0, str(bad))

    # 14. Name ownership: a second daemon is refused and told who owns the name.
    second = Centre()
    line = await second.start()
    check("a second daemon is refused with the owner's pid and process named",
          line.startswith("OPEN_FAILED") and "owned by" in line
          and f"pid {centre.proc.pid}, notify_test_ser" in line, line)
    await second.proc.wait()

    # 15. Replace takes the name over; the first server loses it.
    third = Centre(["--replace"])
    line = await third.start()
    check("--replace takes the name over", line == "READY fdo", line)
    await asyncio.sleep(0.5)
    st = parse_state(await centre.cmd("state"))
    check("the displaced server reports it is no longer serving", st["header"].get("serving") == "0", str(st["header"]))
    await third.quit()

    check("the centre quits cleanly", await centre.quit() == 0)
    bus.disconnect()

    print(f"{checks - len(failures)} of {checks} checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
