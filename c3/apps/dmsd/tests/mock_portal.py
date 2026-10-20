#!/usr/bin/env python3
"""A mock of the xdg-desktop-portal Settings interface, for apps/dmsd/tests/desktop.sh.

Runs on the private session bus named by DBUS_SESSION_BUS_ADDRESS (python-dbus-next). It owns
org.freedesktop.portal.Desktop and exports:

* org.freedesktop.portal.Settings at /org/freedesktop/portal/desktop: ReadAll(as) -> a{sa{sv}},
  Read(ss) -> v, and the SettingChanged(sssv) signal, for the org.freedesktop.appearance namespace;
* org.bleu.PortalMock.Set(ssv) at /org/bleu/PortalMock: stores a value and emits SettingChanged,
  so a test can change the colour scheme "from outside" (the way the desktop does).

Prints READY on stdout once the name is owned. The colour scheme starts as 1 (prefer dark).
"""
import asyncio
import os
import sys

from dbus_next import DBusError, Variant
from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, method, signal

NAMESPACE = "org.freedesktop.appearance"
PORTAL_NAME = "org.freedesktop.portal.Desktop"
PORTAL_PATH = "/org/freedesktop/portal/desktop"
CONTROL_NAME = "org.bleu.PortalMock"
CONTROL_PATH = "/org/bleu/PortalMock"

VALUES = {"color-scheme": Variant("u", 1)}


class Settings(ServiceInterface):
    def __init__(self):
        super().__init__("org.freedesktop.portal.Settings")

    @method()
    def ReadAll(self, namespaces: "as") -> "a{sa{sv}}":
        return {ns: dict(VALUES) for ns in namespaces if ns == NAMESPACE}

    @method()
    def Read(self, namespace: "s", key: "s") -> "v":
        if namespace != NAMESPACE or key not in VALUES:
            raise DBusError("org.freedesktop.portal.Error.NotFound", f"{namespace} {key} is not set")
        return Variant("v", VALUES[key])

    @signal()
    def SettingChanged(self, namespace: "s", key: "s", value: "v") -> "ssv":
        return [namespace, key, value]


class Control(ServiceInterface):
    def __init__(self, settings):
        super().__init__("org.bleu.PortalMock")
        self.settings = settings

    @method()
    def Set(self, namespace: "s", key: "s", value: "v"):
        VALUES[key] = value
        self.settings.SettingChanged(namespace, key, value)


async def main():
    bus = await MessageBus(bus_address=os.environ["DBUS_SESSION_BUS_ADDRESS"]).connect()
    settings = Settings()
    bus.export(PORTAL_PATH, settings)
    bus.export(CONTROL_PATH, Control(settings))
    await bus.request_name(PORTAL_NAME)
    await bus.request_name(CONTROL_NAME)
    print("READY", flush=True)
    await asyncio.Future()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
