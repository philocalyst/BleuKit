"""A mock of org.freedesktop.portal.Desktop for bleu_hotkey's portal backend.

Run it on a private session bus (tests/run.sh does this). It owns the well-known name and implements
the parts of the portal the backend uses, following xdg-desktop-portal's data/*.xml:

* GlobalShortcuts: CreateSession, BindShortcuts, ListShortcuts, the `version` property, and the
  Activated, Deactivated and ShortcutsChanged signals.
* Request: every call answers with a Request handle of the form
  /org/freedesktop/portal/desktop/request/SENDER/TOKEN (SENDER: the unique name without ':', '.' -> '_'),
  and the answer comes later as the Request's Response signal (response 0, 1 or 2).
* Session: Session.Close, which emits Closed. A session binds shortcuts once; a second BindShortcuts on
  the same session is answered with response 2, so a client that does it is caught.

Behaviour is driven by a control file (env BLEU_HOTKEY_CONTROL), one command per line, read as it grows:

  mode ok|cancel|other     the response code of the next BindShortcuts (default ok)
  refuse ID                the compositor refuses this shortcut when binding
  accept ID                undo `refuse`
  version N                the GlobalShortcuts `version` property (0 hides the interface)
  activate ID TS [TOKEN]   Activated for the session that bound last, with timestamp TS (ms)
  deactivate ID TS         Deactivated, likewise
  changed ID TRIGGER       ShortcutsChanged: the trigger text of ID becomes TRIGGER

Prints READY on stdout once the name is owned. Needs python3 with dbus-next.
"""
import asyncio
import os
import sys

from dbus_next import Message, MessageType, RequestNameReply, Variant, BusType
from dbus_next.aio import MessageBus
from dbus_next.errors import DBusError

PORTAL = "org.freedesktop.portal.Desktop"
ROOT = "/org/freedesktop/portal/desktop"
SHORTCUTS = "org.freedesktop.portal.GlobalShortcuts"
REQUEST = "org.freedesktop.portal.Request"
SESSION = "org.freedesktop.portal.Session"
RESPONSE_DELAY = 0.02  # seconds between the reply and the Response, as a compositor would take

state = {
    "mode": "ok",
    "refused": set(),
    "version": 2,
    "sessions": {},      # session path -> {"sender": str, "bound": bool}
    "remembered": {},    # sender -> [(id, trigger)] bound by the last successful BindShortcuts
    "last_session": None,
    "log": [],
}


def log(text):
    print(text, file=sys.stderr, flush=True)


def element(sender):
    """The SENDER element of a request or session path: ':1.42' -> '1_42'."""
    return sender[1:].replace(".", "_")


def request_path(sender, token):
    return f"{ROOT}/request/{element(sender)}/{token}"


def session_path(sender, token):
    return f"{ROOT}/session/{element(sender)}/{token}"


def options_text(options):
    """An a{sv} as a Python dict of plain values."""
    return {k: v.value for k, v in options.items()}


def respond_later(bus, path, code, results):
    """Emit Request.Response on the Request object at `path` after the method's reply."""

    async def emit():
        await asyncio.sleep(RESPONSE_DELAY)
        msg = Message(
            message_type=MessageType.SIGNAL,
            path=path,
            interface=REQUEST,
            member="Response",
            signature="ua{sv}",
            body=[code, results],
        )
        bus.send(msg)
        log(f"Response {path} code={code}")

    asyncio.get_event_loop().create_task(emit())


def handle(bus):
    def dispatch(msg):
        if msg.message_type != MessageType.METHOD_CALL or msg.destination != PORTAL:
            return None
        if msg.interface == "org.freedesktop.DBus.Properties" and msg.member == "Get":
            iface, name = msg.body
            if iface != SHORTCUTS:
                return error(msg, "org.freedesktop.DBus.Error.UnknownInterface", iface)
            if state["version"] == 0:
                return error(msg, "org.freedesktop.DBus.Error.UnknownProperty", name)
            return Message.new_method_return(msg, "v", [Variant("u", state["version"])])
        if msg.interface == SHORTCUTS and msg.path == ROOT:
            return shortcuts_method(bus, msg)
        if msg.interface == SESSION and msg.member == "Close":
            return close_session(bus, msg)
        return error(msg, "org.freedesktop.DBus.Error.UnknownMethod", msg.member)

    return dispatch


def error(msg, name, text):
    return Message.new_error(msg, name, str(text))


def shortcuts_method(bus, msg):
    sender = msg.sender
    if msg.member == "CreateSession":
        options = options_text(msg.body[0])
        token = options["handle_token"]
        sess = session_path(sender, options["session_handle_token"])
        state["sessions"][sess] = {"sender": sender, "bound": False}
        state["last_session"] = sess
        req = request_path(sender, token)
        respond_later(bus, req, 0, {"session_handle": Variant("s", sess)})
        return Message.new_method_return(msg, "o", [req])
    if msg.member == "ListShortcuts":
        session, options = msg.body[0], options_text(msg.body[1])
        req = request_path(sender, options["handle_token"])
        listed = state["remembered"].get(sender, [])
        results = {"shortcuts": Variant("a(sa{sv})", [(sid, {"trigger_description": Variant("s", trig)}) for sid, trig in listed])}
        respond_later(bus, req, 0, results)
        return Message.new_method_return(msg, "o", [req])
    if msg.member == "BindShortcuts":
        session, shortcuts, _parent, options = msg.body
        options = options_text(options)
        req = request_path(sender, options["handle_token"])
        entry = state["sessions"].get(session)
        if entry is None or entry["sender"] != sender:
            return error(msg, "org.freedesktop.DBus.Error.InvalidArgs", "no such session")
        if entry["bound"]:
            log("BindShortcuts on an already bound session")
            respond_later(bus, req, 2, {})
            return Message.new_method_return(msg, "o", [req])
        entry["bound"] = True
        code = {"ok": 0, "cancel": 1}.get(state["mode"], 2)
        if code != 0:
            respond_later(bus, req, code, {})
        else:
            accepted = []
            for sid, props in shortcuts:
                if sid in state["refused"]:
                    continue
                trigger = props.get("preferred_trigger", Variant("s", "")).value
                accepted.append((sid, trigger))
            state["remembered"][sender] = accepted
            results = {
                "shortcuts": Variant(
                    "a(sa{sv})",
                    [(sid, {"description": Variant("s", ""), "trigger_description": Variant("s", trig)}) for sid, trig in accepted],
                )
            }
            respond_later(bus, req, 0, results)
        return Message.new_method_return(msg, "o", [req])
    return error(msg, "org.freedesktop.DBus.Error.UnknownMethod", msg.member)


def close_session(bus, msg):
    sess = msg.path
    if state["sessions"].pop(sess, None) is None:
        return error(msg, "org.freedesktop.DBus.Error.UnknownObject", sess)
    bus.send(Message(message_type=MessageType.SIGNAL, path=sess, interface=SESSION, member="Closed", signature="a{sv}", body=[{}]))
    return Message.new_method_return(msg, "", [])


def emit_shortcut(bus, member, ident, timestamp, token):
    sess = state["last_session"]
    options = {"activation_token": Variant("s", token)} if token else {}
    bus.send(
        Message(
            message_type=MessageType.SIGNAL,
            path=ROOT,
            interface=SHORTCUTS,
            member=member,
            signature="osta{sv}",
            body=[sess, ident, timestamp, options],
        )
    )


def apply(bus, line):
    parts = line.split()
    if not parts:
        return
    cmd, args = parts[0], parts[1:]
    if cmd == "mode":
        state["mode"] = args[0]
    elif cmd == "refuse":
        state["refused"].add(args[0])
    elif cmd == "accept":
        state["refused"].discard(args[0])
    elif cmd == "version":
        state["version"] = int(args[0])
    elif cmd == "activate":
        emit_shortcut(bus, "Activated", args[0], int(args[1]), args[2] if len(args) > 2 else "")
    elif cmd == "deactivate":
        emit_shortcut(bus, "Deactivated", args[0], int(args[1]), "")
    elif cmd == "changed":
        sess = state["last_session"]
        bus.send(
            Message(
                message_type=MessageType.SIGNAL,
                path=ROOT,
                interface=SHORTCUTS,
                member="ShortcutsChanged",
                signature="oa(sa{sv})",
                body=[sess, [(args[0], {"trigger_description": Variant("s", args[1])})]],
            )
        )
    else:
        log(f"unknown control command: {line}")
    log(f"applied: {line}")


async def watch_control(bus, path):
    offset = 0
    pending = ""
    while True:
        try:
            with open(path, "r", encoding="utf-8") as fh:
                fh.seek(offset)
                chunk = fh.read()
                offset = fh.tell()
        except FileNotFoundError:
            chunk = ""
        if chunk:
            pending += chunk
            while "\n" in pending:
                line, pending = pending.split("\n", 1)
                apply(bus, line.strip())
        await asyncio.sleep(0.05)


async def main():
    control = os.environ.get("BLEU_HOTKEY_CONTROL")
    if not control:
        sys.exit("BLEU_HOTKEY_CONTROL must name the control file")
    bus = await MessageBus(bus_type=BusType.SESSION).connect()
    bus.add_message_handler(handle(bus))
    reply = await bus.request_name(PORTAL)
    if reply != RequestNameReply.PRIMARY_OWNER:
        sys.exit(f"could not own {PORTAL}: {reply}")
    print("READY", flush=True)
    await watch_control(bus, control)


if __name__ == "__main__":
    asyncio.run(main())
