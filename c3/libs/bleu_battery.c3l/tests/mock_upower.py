#!/usr/bin/env python3
"""Mock org.freedesktop.UPower for the bleu_battery live tests, written with python-dbus-next.

It owns org.freedesktop.UPower on the bus named by DBUS_SYSTEM_BUS_ADDRESS and exports:

* /org/freedesktop/UPower (org.freedesktop.UPower): EnumerateDevices() -> ao, DaemonVersion,
  OnBattery, and the signals DeviceAdded(o) and DeviceRemoved(o);
* /org/freedesktop/UPower/devices/line_power_AC (org.freedesktop.UPower.Device, Type 1):
  Online (b) and NativePath "AC";
* /org/freedesktop/UPower/devices/battery_BAT0 (Type 2): the battery properties that
  bleu_battery reads (State, Percentage, Energy*, EnergyRate, TimeTo*, ChargeCycles, ...);
* /org/freedesktop/UPower/devices/mouse_M1 (Type 5), present only while the control says so,
  announced with DeviceAdded and withdrawn with DeviceRemoved.

Property changes are PropertiesChanged signals, emitted by python-dbus-next itself.

The control file (path in BLEU_UPOWER_CONTROL) holds space-separated key=value pairs:
  online=0|1  state=<UPower State>  percentage=<0..100>  rate=<W, + when discharging>
  energy=<Wh>  mouse=0|1
The mock re-reads it every 50 ms and applies every change. The test writes it.

Prints READY on stdout once the name is owned. Needs python-dbus-next (0.2.x).
"""
import asyncio
import os
import sys

from dbus_next import BusType
from dbus_next.aio import MessageBus
from dbus_next.constants import PropertyAccess
from dbus_next.service import ServiceInterface, dbus_property, method, signal

NAME = 'org.freedesktop.UPower'
ROOT = '/org/freedesktop/UPower'
DEVICES = ROOT + '/devices'
DEVICE_IFACE = 'org.freedesktop.UPower.Device'
MOUSE = DEVICES + '/mouse_M1'
CONTROL = os.environ.get('BLEU_UPOWER_CONTROL', '')

BATTERY_NATIVE_PATH = 'BAT0'
DEFAULTS = {'online': '0', 'state': '2', 'percentage': '50', 'rate': '15.0', 'energy': '25.0', 'mouse': '0'}


def parse_control(text):
    values = dict(DEFAULTS)
    for pair in text.split():
        if '=' in pair:
            key, value = pair.split('=', 1)
            values[key] = value
    return values


class Root(ServiceInterface):
    def __init__(self):
        super().__init__('org.freedesktop.UPower')
        self.devices = [DEVICES + '/line_power_AC', DEVICES + '/battery_BAT0']

    @method()
    def EnumerateDevices(self) -> 'ao':
        return list(self.devices)

    @method()
    def GetDisplayDevice(self) -> 'o':
        return DEVICES + '/DisplayDevice'

    @dbus_property(access=PropertyAccess.READ)
    def DaemonVersion(self) -> 's':
        return '2.0.0-mock'

    @dbus_property(access=PropertyAccess.READ)
    def OnBattery(self) -> 'b':
        return False

    @signal()
    def DeviceAdded(self, path) -> 'o':
        return path

    @signal()
    def DeviceRemoved(self, path) -> 'o':
        return path


class Device(ServiceInterface):
    """One device object. `props` holds the current values; the getters read them."""

    def __init__(self, props):
        super().__init__(DEVICE_IFACE)
        self.props = props

    @dbus_property(access=PropertyAccess.READ)
    def NativePath(self) -> 's':
        return self.props['NativePath']

    @dbus_property(access=PropertyAccess.READ)
    def Vendor(self) -> 's':
        return self.props.get('Vendor', '')

    @dbus_property(access=PropertyAccess.READ)
    def Model(self) -> 's':
        return self.props.get('Model', '')

    @dbus_property(access=PropertyAccess.READ)
    def Serial(self) -> 's':
        return self.props.get('Serial', '')

    @dbus_property(access=PropertyAccess.READ)
    def Type(self) -> 'u':
        return self.props['Type']

    @dbus_property(access=PropertyAccess.READ)
    def Online(self) -> 'b':
        return self.props.get('Online', False)

    @dbus_property(access=PropertyAccess.READ)
    def IsPresent(self) -> 'b':
        return self.props.get('IsPresent', True)

    @dbus_property(access=PropertyAccess.READ)
    def State(self) -> 'u':
        return self.props.get('State', 0)

    @dbus_property(access=PropertyAccess.READ)
    def Percentage(self) -> 'd':
        return self.props.get('Percentage', 0.0)

    @dbus_property(access=PropertyAccess.READ)
    def Energy(self) -> 'd':
        return self.props.get('Energy', 0.0)

    @dbus_property(access=PropertyAccess.READ)
    def EnergyFull(self) -> 'd':
        return self.props.get('EnergyFull', 0.0)

    @dbus_property(access=PropertyAccess.READ)
    def EnergyFullDesign(self) -> 'd':
        return self.props.get('EnergyFullDesign', 0.0)

    @dbus_property(access=PropertyAccess.READ)
    def EnergyRate(self) -> 'd':
        return self.props.get('EnergyRate', 0.0)

    @dbus_property(access=PropertyAccess.READ)
    def TimeToEmpty(self) -> 'x':
        return self.props.get('TimeToEmpty', 0)

    @dbus_property(access=PropertyAccess.READ)
    def TimeToFull(self) -> 'x':
        return self.props.get('TimeToFull', 0)

    @dbus_property(access=PropertyAccess.READ)
    def ChargeCycles(self) -> 'i':
        return self.props.get('ChargeCycles', -1)

    @dbus_property(access=PropertyAccess.READ)
    def Technology(self) -> 'u':
        return self.props.get('Technology', 1)

    @dbus_property(access=PropertyAccess.READ)
    def Temperature(self) -> 'd':
        return self.props.get('Temperature', 31.5)


def battery_props(v):
    state = int(v['state'])
    rate = float(v['rate'])
    energy = float(v['energy'])
    percentage = float(v['percentage'])
    return {
        'NativePath': BATTERY_NATIVE_PATH,
        'Vendor': 'ACME',
        'Model': 'Cell9',
        'Serial': 'SN-42',
        'Type': 2,
        'IsPresent': True,
        'State': state,
        'Percentage': percentage,
        'Energy': energy,
        'EnergyFull': 40.0,
        'EnergyFullDesign': 50.0,
        'EnergyRate': rate,
        'TimeToEmpty': 5400 if state == 2 else 0,
        'TimeToFull': 1800 if state == 1 else 0,
        'ChargeCycles': 212,
        'Technology': 1,
        'Temperature': 31.5,
    }


def line_props(v):
    return {'NativePath': 'AC', 'Type': 1, 'Online': v['online'] == '1'}


def mouse_props():
    return {'NativePath': 'hid-M1', 'Type': 5, 'IsPresent': True, 'Percentage': 80.0, 'Vendor': 'Logi'}


def changed_values(old, new):
    return {k: new[k] for k in new if old.get(k) != new[k]}


async def main():
    bus = await MessageBus(bus_type=BusType.SYSTEM).connect()  # address from DBUS_SYSTEM_BUS_ADDRESS
    root = Root()
    bus.export(ROOT, root)
    initial = parse_control(open(CONTROL).read()) if CONTROL and os.path.exists(CONTROL) else dict(DEFAULTS)
    ac = Device(line_props(initial))
    battery = Device(battery_props(initial))
    bus.export(DEVICES + '/line_power_AC', ac)
    bus.export(DEVICES + '/battery_BAT0', battery)
    await bus.request_name(NAME)
    print('READY', flush=True)

    current = initial
    mouse_present = False
    while True:
        await asyncio.sleep(0.05)
        if not CONTROL or not os.path.exists(CONTROL):
            continue
        wanted = parse_control(open(CONTROL).read())
        if wanted == current:
            continue
        line_changes = changed_values(line_props(current), line_props(wanted))
        bat_changes = changed_values(battery_props(current), battery_props(wanted))
        if line_changes:
            ac.props.update(line_props(wanted))
            ac.emit_properties_changed(line_changes)
        if bat_changes:
            battery.props.update(battery_props(wanted))
            battery.emit_properties_changed(bat_changes)
        if wanted['mouse'] == '1' and not mouse_present:
            mouse = Device(mouse_props())
            bus.export(MOUSE, mouse)
            root.devices.append(MOUSE)
            mouse_present = True
            root.DeviceAdded(MOUSE)
        if wanted['mouse'] == '0' and mouse_present:
            bus.unexport(MOUSE)
            root.devices.remove(MOUSE)
            mouse_present = False
            root.DeviceRemoved(MOUSE)
        current = wanted


if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
