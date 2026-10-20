#!/usr/bin/env python3
"""A mock of org.bluez for tests/run.sh, written with python-dbus-next.

It owns org.bluez on the bus given by DBUS_SESSION_BUS_ADDRESS and serves:

* /org/bluez/hci0 (org.bluez.Adapter1): Powered, Discoverable, DiscoverableTimeout,
  Pairable, Discovering, Address, Name, Alias, PowerState; StartDiscovery adds the
  scanned devices (InterfacesAdded); StopDiscovery; SetDiscoveryFilter;
  RemoveDevice removes a device (InterfacesRemoved).
* /org/bluez/hci0/dev_AA_BB_CC_DD_EE_0x (org.bluez.Device1, and Battery1 on
  device 01): Pair, CancelPairing, Connect, Disconnect, ConnectProfile,
  DisconnectProfile; the properties Paired, Bonded, Connected, Trusted, Blocked,
  Alias (rw), Address, Class, Icon, UUIDs, Adapter, RSSI, Modalias.
* org.freedesktop.DBus.ObjectManager at / (GetManagedObjects).

Scripted behaviour, so the C3 test can check each path:
  device 01 (headset):   Pair succeeds after 0.2 s; Connect succeeds after 0.3 s;
                         Disconnect emits Disconnected("org.bluez.Reason.Local", ...).
  device 02 (mouse):     Pair fails with org.bluez.Error.Failed.
  device 03 (keyboard):  Pair waits until CancelPairing, then fails with
                         org.bluez.Error.Canceled.
  device 04 (phone):     Connect fails with org.bluez.Error.Failed.

Prints READY on stdout once it owns the name.
"""
import asyncio
import sys

from dbus_next import DBusError, Message, MessageType, Variant
from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, method

ADAPTER_PATH = '/org/bluez/hci0'
ADAPTER_IFACE = 'org.bluez.Adapter1'
DEVICE_IFACE = 'org.bluez.Device1'
BATTERY_IFACE = 'org.bluez.Battery1'
PROPERTIES_IFACE = 'org.freedesktop.DBus.Properties'
OBJECT_MANAGER_IFACE = 'org.freedesktop.DBus.ObjectManager'
ADAPTER_ADDRESS = '00:1A:7D:DA:71:13'
A2DP_SINK = '0000110b-0000-1000-8000-00805f9b34fb'
HFP_HANDSFREE = '0000111e-0000-1000-8000-00805f9b34fb'
HSP_HEADSET = '00001108-0000-1000-8000-00805f9b34fb'

BUS = None
OBJECTS = {}  # path -> {interface name: {property: (signature, value)}}
SERVICES = {}  # path -> the exported ServiceInterface objects of that path
WRITABLE = {
    ADAPTER_IFACE: {'Powered', 'Discoverable', 'DiscoverableTimeout', 'Pairable', 'Alias'},
    DEVICE_IFACE: {'Trusted', 'Blocked', 'Alias'},
}
SCAN_DEVICES = []  # addresses that StartDiscovery adds, in order
CANCEL_EVENTS = {}  # device path -> asyncio.Event for a pending Pair
FILTER = {}


def device_path(index):
    return f'{ADAPTER_PATH}/dev_AA_BB_CC_DD_EE_{index:02X}'


def device_props(index, name, cls, icon, uuids, rssi=None, modalias=None):
    props = {
        'Address': ('s', f'AA:BB:CC:DD:EE:{index:02X}'),
        'AddressType': ('s', 'public'),
        'Name': ('s', name),
        'Alias': ('s', name),
        'Icon': ('s', icon),
        'Class': ('u', cls),
        'UUIDs': ('as', uuids),
        'Paired': ('b', False),
        'Bonded': ('b', False),
        'Connected': ('b', False),
        'Trusted': ('b', False),
        'Blocked': ('b', False),
        'Adapter': ('o', ADAPTER_PATH),
        'ServicesResolved': ('b', False),
    }
    if rssi is not None:
        props['RSSI'] = ('n', rssi)
    if modalias is not None:
        props['Modalias'] = ('s', modalias)
    return {DEVICE_IFACE: props}


def adapter_objects():
    return {
        ADAPTER_IFACE: {
            'Address': ('s', ADAPTER_ADDRESS),
            'Name': ('s', 'bleu-mock-host'),
            'Alias': ('s', 'bleu-mock-host'),
            'Powered': ('b', False),
            'Discoverable': ('b', False),
            'DiscoverableTimeout': ('u', 180),
            'Pairable': ('b', True),
            'PairableTimeout': ('u', 0),
            'Discovering': ('b', False),
            'Class': ('u', 0x10C),
            'UUIDs': ('as', []),
            'PowerState': ('s', 'off'),
        }
    }


SCAN = {
    2: ('Bleu Mouse', 0x580, 'input-mouse', [HFP_HANDSFREE], -70, None),
    3: ('Bleu Keyboard', 0x540, 'input-keyboard', [], -48, None),
    4: ('Bleu Phone', 0x20C, 'phone', [HSP_HEADSET], -80, None),
}


def dict_entry_for(index):
    name, cls, icon, uuids, rssi, modalias = SCAN[index]
    return device_props(index, name, cls, icon, uuids, rssi, modalias)


class Properties(ServiceInterface):
    """org.freedesktop.DBus.Properties for one object path, backed by OBJECTS."""

    def __init__(self, path):
        super().__init__(PROPERTIES_IFACE)
        self.path = path

    def _props(self, iface):
        ifaces = OBJECTS.get(self.path, {})
        if iface not in ifaces:
            raise DBusError('org.freedesktop.DBus.Error.UnknownInterface', f'no {iface} on {self.path}')
        return ifaces[iface]

    @method()
    def Get(self, interface: 's', name: 's') -> 'v':
        props = self._props(interface)
        if name not in props:
            raise DBusError('org.freedesktop.DBus.Error.UnknownProperty', name)
        sig, value = props[name]
        return Variant(sig, value)

    @method()
    def GetAll(self, interface: 's') -> 'a{sv}':
        return {k: Variant(sig, v) for k, (sig, v) in self._props(interface).items()}

    @method()
    def Set(self, interface: 's', name: 's', value: 'v'):
        props = self._props(interface)
        if name not in props:
            raise DBusError('org.freedesktop.DBus.Error.UnknownProperty', name)
        if name not in WRITABLE.get(interface, set()):
            raise DBusError('org.freedesktop.DBus.Error.PropertyReadOnly', name)
        sig = props[name][0]
        new = value.value
        if name == 'Alias' and new == '':
            new = props.get('Name', (None, ''))[1]
        props[name] = (sig, new)
        changed = {name: Variant(sig, new)}
        emit_properties_changed(self.path, interface, changed)
        if interface == ADAPTER_IFACE and name == 'Powered':
            props_pw = OBJECTS[self.path][ADAPTER_IFACE]
            props_pw['PowerState'] = ('s', 'on' if new else 'off')
            emit_properties_changed(self.path, interface, {'PowerState': Variant('s', props_pw['PowerState'][1])})


def emit_properties_changed(path, interface, changed):
    BUS.send(Message.new_signal(path, PROPERTIES_IFACE, 'PropertiesChanged', 'sa{sv}as',
                                [interface, changed, []]))


def emit_interfaces_added(path):
    ifaces = {name: {k: Variant(sig, v) for k, (sig, v) in props.items()}
              for name, props in OBJECTS[path].items()}
    BUS.send(Message.new_signal('/', OBJECT_MANAGER_IFACE, 'InterfacesAdded', 'oa{sa{sv}}', [path, ifaces]))


def emit_interfaces_removed(path):
    BUS.send(Message.new_signal('/', OBJECT_MANAGER_IFACE, 'InterfacesRemoved', 'oas',
                                [path, list(OBJECTS[path].keys())]))


def unexport(path):
    emit_interfaces_removed(path)
    for service in SERVICES[path]:
        BUS.unexport(path, service)
    del OBJECTS[path]
    del SERVICES[path]


class Adapter(ServiceInterface):
    def __init__(self):
        super().__init__(ADAPTER_IFACE)

    @method()
    def StartDiscovery(self):
        OBJECTS[ADAPTER_PATH][ADAPTER_IFACE]['Discovering'] = ('b', True)
        emit_properties_changed(ADAPTER_PATH, ADAPTER_IFACE, {'Discovering': Variant('b', True)})
        for index in sorted(SCAN):
            path = device_path(index)
            if path not in OBJECTS:
                export(path, dict_entry_for(index))

    @method()
    def StopDiscovery(self):
        OBJECTS[ADAPTER_PATH][ADAPTER_IFACE]['Discovering'] = ('b', False)
        emit_properties_changed(ADAPTER_PATH, ADAPTER_IFACE, {'Discovering': Variant('b', False)})

    @method()
    def SetDiscoveryFilter(self, filter: 'a{sv}'):
        FILTER.clear()
        FILTER.update({k: v.value for k, v in filter.items()})

    @method()
    def RemoveDevice(self, device: 'o'):
        if device in OBJECTS and device.startswith(ADAPTER_PATH + '/'):
            unexport(device)
        else:
            raise DBusError('org.bluez.Error.DoesNotExist', 'Does Not Exist')


class Device(ServiceInterface):
    def __init__(self, index):
        super().__init__(DEVICE_IFACE)
        self.index = index
        self.path = device_path(index)

    def _set(self, name, value):
        props = OBJECTS[self.path][DEVICE_IFACE]
        props[name] = (props[name][0], value)
        emit_properties_changed(self.path, DEVICE_IFACE, {name: Variant(props[name][0], value)})

    @method()
    async def Pair(self):
        index = self.index
        if index == 2:
            await asyncio.sleep(0.1)
            raise DBusError('org.bluez.Error.Failed', 'pairing refused by mock')
        if index == 3:
            event = CANCEL_EVENTS.setdefault(self.path, asyncio.Event())
            event.clear()
            try:
                await asyncio.wait_for(event.wait(), 20)
            except asyncio.TimeoutError:
                raise DBusError('org.bluez.Error.Failed', 'mock timed out waiting for cancel')
            raise DBusError('org.bluez.Error.Canceled', 'Canceled')
        if OBJECTS[self.path][DEVICE_IFACE]['Paired'][1]:
            raise DBusError('org.bluez.Error.AlreadyExists', 'Already Exists')
        await asyncio.sleep(0.2)
        self._set('Paired', True)
        self._set('Bonded', True)
        self._set('ServicesResolved', True)

    @method()
    def CancelPairing(self):
        event = CANCEL_EVENTS.get(self.path)
        if event is None:
            raise DBusError('org.bluez.Error.DoesNotExist', 'no pairing in progress')
        event.set()

    @method()
    async def Connect(self):
        if self.index == 4:
            await asyncio.sleep(0.1)
            raise DBusError('org.bluez.Error.Failed', 'page timeout (mock)')
        if OBJECTS[self.path][DEVICE_IFACE]['Connected'][1]:
            raise DBusError('org.bluez.Error.AlreadyConnected', 'Already Connected')
        await asyncio.sleep(0.3)
        self._set('Connected', True)

    @method()
    def Disconnect(self):
        if not OBJECTS[self.path][DEVICE_IFACE]['Connected'][1]:
            raise DBusError('org.bluez.Error.NotConnected', 'Not Connected')
        self._set('Connected', False)
        BUS.send(Message.new_signal(self.path, DEVICE_IFACE, 'Disconnected', 'ss',
                                    ['org.bluez.Reason.Local', 'Disconnected by mock']))

    @method()
    def ConnectProfile(self, uuid: 's'):
        if uuid not in OBJECTS[self.path][DEVICE_IFACE]['UUIDs'][1]:
            raise DBusError('org.bluez.Error.NotAvailable', 'profile not offered')
        self._set('Connected', True)

    @method()
    def DisconnectProfile(self, uuid: 's'):
        if not OBJECTS[self.path][DEVICE_IFACE]['Connected'][1]:
            raise DBusError('org.bluez.Error.NotConnected', 'Not Connected')
        self._set('Connected', False)


class ObjectManager(ServiceInterface):
    def __init__(self):
        super().__init__(OBJECT_MANAGER_IFACE)

    @method()
    def GetManagedObjects(self) -> 'a{oa{sa{sv}}}':
        out = {}
        for path, ifaces in OBJECTS.items():
            out[path] = {name: {k: Variant(sig, v) for k, (sig, v) in props.items()}
                         for name, props in ifaces.items()}
        return out


async def main():
    global BUS
    BUS = await MessageBus().connect()
    OBJECTS[ADAPTER_PATH] = adapter_objects()
    SERVICES[ADAPTER_PATH] = [Properties(ADAPTER_PATH), Adapter()]
    for service in SERVICES[ADAPTER_PATH]:
        BUS.export(ADAPTER_PATH, service)
    first = device_props(1, 'Bleu Headset', 0x418, 'audio-headset', [A2DP_SINK, HFP_HANDSFREE],
                         None, 'usb:v1D6Bp0246d0533')
    first[BATTERY_IFACE] = {'Percentage': ('y', 75)}
    OBJECTS[device_path(1)] = first
    SERVICES[device_path(1)] = [Properties(device_path(1)), Device(1)]
    for service in SERVICES[device_path(1)]:
        BUS.export(device_path(1), service)
    # Devices 2-4 are created by StartDiscovery, through the scan, not at start.
    root = ObjectManager()
    SERVICES['/'] = [root]
    BUS.export('/', root)
    await BUS.request_name('org.bluez')
    print('READY', flush=True)
    await asyncio.Future()


def export(path, props):
    """Exports a scanned device with its Properties and Device1 methods, and announces it."""
    OBJECTS[path] = props
    index = int(path[-2:], 16)
    SERVICES[path] = [Properties(path), Device(index)]
    for service in SERVICES[path]:
        BUS.export(path, service)
    emit_interfaces_added(path)


if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
