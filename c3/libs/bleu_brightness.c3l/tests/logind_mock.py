#!/usr/bin/env python3
"""A logind stand-in for the bleu_brightness integration test.

It serves `org.freedesktop.login1` on the bus at the given address and exports
`/org/freedesktop/login1/session/auto` as `org.freedesktop.login1.Session`.

  logind_mock.py ADDRESS ROOT MODE

MODE `ok`: SetBrightness(ssu) is implemented. It writes the brightness file under
ROOT the way the kernel would and appends `subsystem name value` to
ROOT/mock-calls.log, so the test can tell that logind carried the write.
MODE `unknown`: the interface has no SetBrightness method (older systemd), so the
bus answers org.freedesktop.DBus.Error.UnknownMethod.
"""
import asyncio
import os
import sys

from dbus_next import BusType
from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, method

SERVICE = "org.freedesktop.login1"
PATH = "/org/freedesktop/login1/session/auto"


class SessionOk(ServiceInterface):
    def __init__(self, root):
        super().__init__("org.freedesktop.login1.Session")
        self.root = root

    @method()
    def SetBrightness(self, subsystem: "s", name: "s", brightness: "u"):
        directory = "backlight" if subsystem == "backlight" else "leds"
        path = os.path.join(self.root, "sys/class", directory, name, "brightness")
        with open(path, "w") as f:
            f.write(str(brightness))
        with open(os.path.join(self.root, "mock-calls.log"), "a") as log:
            log.write(f"{subsystem} {name} {brightness}\n")


class SessionUnknown(ServiceInterface):
    def __init__(self):
        super().__init__("org.freedesktop.login1.Session")

    @method()
    def Ping(self):
        return


async def main():
    address, root, mode = sys.argv[1], sys.argv[2], sys.argv[3]
    bus = await MessageBus(bus_address=address).connect()
    await bus.request_name(SERVICE)
    iface = SessionOk(root) if mode == "ok" else SessionUnknown()
    bus.export(PATH, iface)
    print("ready", flush=True)
    await asyncio.Event().wait()


if __name__ == "__main__":
    asyncio.run(main())
