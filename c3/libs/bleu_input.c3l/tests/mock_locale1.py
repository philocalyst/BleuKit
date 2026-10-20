#!/usr/bin/env python3
"""Mock org.freedesktop.locale1 for the bleu_input live tests, written with python-dbus-next.

It owns org.freedesktop.locale1 on the bus named by DBUS_SYSTEM_BUS_ADDRESS and exports the object
/org/freedesktop/locale1 (interface org.freedesktop.locale1) with the read-only X11 and console keymap
properties that systemd-localed publishes: X11Layout, X11Model, X11Variant, X11Options, VConsoleKeymap,
VConsoleKeymapToggle (all type s), and Locale (as). Names and types: systemd man page
org.freedesktop.locale1 (https://www.freedesktop.org/software/systemd/man/latest/org.freedesktop.locale1.html).

The control file (path in BLEU_LOCALE1_CONTROL) holds space-separated key=value pairs:
  layout=<X11Layout>  variant=<X11Variant>  model=<X11Model>  options=<X11Options>
The mock re-reads it every 50 ms; a changed property is announced with PropertiesChanged, emitted by
python-dbus-next itself. The test script writes the file.

Prints READY on stdout once the name is owned. Needs python-dbus-next (0.2.x).
"""
import asyncio
import os

from dbus_next import BusType
from dbus_next.aio import MessageBus
from dbus_next.constants import PropertyAccess
from dbus_next.service import ServiceInterface, dbus_property

NAME = 'org.freedesktop.locale1'
PATH = '/org/freedesktop/locale1'
IFACE = 'org.freedesktop.locale1'
CONTROL = os.environ.get('BLEU_LOCALE1_CONTROL', '')

DEFAULTS = {'layout': 'us', 'variant': '', 'model': 'pc105', 'options': ''}


def parse_control(text):
    values = dict(DEFAULTS)
    for pair in text.split():
        if '=' in pair:
            key, value = pair.split('=', 1)
            values[key] = value
    return values


def read_control():
    if not CONTROL or not os.path.exists(CONTROL):
        return dict(DEFAULTS)
    with open(CONTROL, encoding='utf-8') as source:
        return parse_control(source.read())


class Locale1(ServiceInterface):
    def __init__(self, values):
        super().__init__(IFACE)
        self.values = values

    @dbus_property(access=PropertyAccess.READ)
    def X11Layout(self) -> 's':
        return self.values['layout']

    @dbus_property(access=PropertyAccess.READ)
    def X11Model(self) -> 's':
        return self.values['model']

    @dbus_property(access=PropertyAccess.READ)
    def X11Variant(self) -> 's':
        return self.values['variant']

    @dbus_property(access=PropertyAccess.READ)
    def X11Options(self) -> 's':
        return self.values['options']

    @dbus_property(access=PropertyAccess.READ)
    def VConsoleKeymap(self) -> 's':
        return 'us'

    @dbus_property(access=PropertyAccess.READ)
    def VConsoleKeymapToggle(self) -> 's':
        return ''

    @dbus_property(access=PropertyAccess.READ)
    def Locale(self) -> 'as':
        return ['LANG=en_US.UTF-8']


PROPERTY_NAMES = {'layout': 'X11Layout', 'model': 'X11Model', 'variant': 'X11Variant', 'options': 'X11Options'}


async def main():
    bus = await MessageBus(bus_type=BusType.SYSTEM).connect()  # address from DBUS_SYSTEM_BUS_ADDRESS
    current = read_control()
    service = Locale1(dict(current))
    bus.export(PATH, service)
    await bus.request_name(NAME)
    print('READY', flush=True)
    while True:
        await asyncio.sleep(0.05)
        wanted = read_control()
        if wanted == current:
            continue
        changed = {PROPERTY_NAMES[key]: wanted[key] for key in PROPERTY_NAMES if wanted[key] != current[key]}
        service.values.update(wanted)
        if changed:
            service.emit_properties_changed(changed)
        current = wanted


if __name__ == '__main__':
    asyncio.run(main())
