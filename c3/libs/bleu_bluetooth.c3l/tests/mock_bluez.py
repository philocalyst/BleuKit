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
  device 01 (headset):   Pair asks the agent RequestConfirmation(123456); succeeds when
                         the agent accepts. Connect succeeds after 0.3 s; Disconnect
                         emits Disconnected("org.bluez.Reason.Local", ...).
  device 02 (mouse):     Pair asks the agent RequestPinCode; succeeds only with the
                         PIN "4321" (the agent's answer), otherwise fails.
  device 03 (keyboard):  Pair waits until CancelPairing, then fails with
                         org.bluez.Error.Canceled.
  device 04 (phone):     Pair asks the agent RequestPasskey; a refusal from the agent
                         fails the Pair. Connect fails with org.bluez.Error.Failed.

BlueZ's AgentManager1 (RegisterAgent, RequestDefaultAgent, UnregisterAgent) is
served at /org/bluez; the agent's sender and path are kept for the callbacks.

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
AGENT = {}  # the registered agent: 'sender' (its bus name) and 'path'
MANAGER_IFACE = 'org.bluez.AgentManager1'
AGENT_IFACE = 'org.bluez.Agent1'
PIN_ACCEPTED = '4321'
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


def set_property(path, interface, name, value):
    """Properties.Set, with the writable check and BlueZ's PowerState kept in step with Powered."""
    props = OBJECTS[path][interface]
    if name not in props:
        raise DBusError('org.freedesktop.DBus.Error.UnknownProperty', name)
    if name not in WRITABLE.get(interface, set()):
        raise DBusError('org.freedesktop.DBus.Error.PropertyReadOnly', name)
    sig = props[name][0]
    if name == 'Alias' and value == '':
        value = props.get('Name', (None, ''))[1]
    props[name] = (sig, value)
    emit_properties_changed(path, interface, {name: Variant(sig, value)})
    if interface == ADAPTER_IFACE and name == 'Powered':
        props['PowerState'] = ('s', 'on' if value else 'off')
        emit_properties_changed(path, interface, {'PowerState': Variant('s', props['PowerState'][1])})


def answer_properties(msg):
    """Serves org.freedesktop.DBus.Properties (Get, GetAll, Set) for every exported object by hand."""
    if msg.message_type != MessageType.METHOD_CALL or msg.interface != PROPERTIES_IFACE or msg.path not in OBJECTS:
        return None
    try:
        if msg.member == 'Get':
            interface, name = msg.body
            props = OBJECTS[msg.path].get(interface)
            if props is None or name not in props:
                raise DBusError('org.freedesktop.DBus.Error.UnknownProperty', name)
            sig, value = props[name]
            return Message.new_method_return(msg, 'v', [Variant(sig, value)])
        if msg.member == 'GetAll':
            interface = msg.body[0]
            props = OBJECTS[msg.path].get(interface, {})
            return Message.new_method_return(msg, 'a{sv}', [{k: Variant(sig, v) for k, (sig, v) in props.items()}])
        if msg.member == 'Set':
            interface, name, variant = msg.body
            set_property(msg.path, interface, name, variant.value)
            return Message.new_method_return(msg, '', [])
    except DBusError as error:
        return Message.new_error(msg, error.type, error.text)
    return None


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


async def agent_call(member, signature, body):
    """Calls the registered agent and returns its reply body; an agent refusal raises its error."""
    if not AGENT:
        raise DBusError('org.bluez.Error.Failed', 'no agent is registered')
    reply = await BUS.call(Message(destination=AGENT['sender'], path=AGENT['path'], interface=AGENT_IFACE,
                                   member=member, signature=signature, body=body))
    if reply.message_type == MessageType.ERROR:
        raise DBusError('org.bluez.Error.Rejected', reply.error_name)
    return reply.body


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
        if index == 1:
            await agent_call('RequestConfirmation', 'ou', [self.path, 123456])
        elif index == 2:
            pin = (await agent_call('RequestPinCode', 'o', [self.path]))[0]
            if pin != PIN_ACCEPTED:
                raise DBusError('org.bluez.Error.Failed', f'PIN {pin!r} is not the one expected')
        elif index == 4:
            await agent_call('RequestPasskey', 'o', [self.path])
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


def managed_objects():
    """The GetManagedObjects reply: every object with its interfaces and their properties."""
    return {path: {name: {k: Variant(sig, v) for k, (sig, v) in props.items()}
                   for name, props in ifaces.items()}
            for path, ifaces in OBJECTS.items()}


def answer_object_manager(msg):
    """Serves GetManagedObjects at / by hand: dbus-next's own ObjectManager ignores undecorated properties."""
    if (msg.message_type == MessageType.METHOD_CALL and msg.path == '/'
            and msg.interface == OBJECT_MANAGER_IFACE and msg.member == 'GetManagedObjects'):
        return Message.new_method_return(msg, 'a{oa{sa{sv}}}', [managed_objects()])
    return None


def answer_agent_manager(msg):
    """AgentManager1 at /org/bluez: records the agent and its bus name (the sender of RegisterAgent)."""
    if msg.message_type != MessageType.METHOD_CALL or msg.interface != MANAGER_IFACE or msg.path != '/org/bluez':
        return None
    if msg.member == 'RegisterAgent':
        AGENT.update({'sender': msg.sender, 'path': msg.body[0]})
        return Message.new_method_return(msg, '', [])
    if msg.member == 'RequestDefaultAgent':
        return Message.new_method_return(msg, '', [])
    if msg.member == 'UnregisterAgent':
        AGENT.clear()
        return Message.new_method_return(msg, '', [])
    return None


def answer_standard(msg):
    return answer_properties(msg) or answer_object_manager(msg) or answer_agent_manager(msg)


async def main():
    global BUS
    BUS = await MessageBus().connect()
    OBJECTS[ADAPTER_PATH] = adapter_objects()
    SERVICES[ADAPTER_PATH] = [Adapter()]
    for service in SERVICES[ADAPTER_PATH]:
        BUS.export(ADAPTER_PATH, service)
    first = device_props(1, 'Bleu Headset', 0x418, 'audio-headset', [A2DP_SINK, HFP_HANDSFREE],
                         None, 'usb:v1D6Bp0246d0533')
    first[BATTERY_IFACE] = {'Percentage': ('y', 75)}
    OBJECTS[device_path(1)] = first
    SERVICES[device_path(1)] = [Device(1)]
    for service in SERVICES[device_path(1)]:
        BUS.export(device_path(1), service)
    # Devices 2-4 are created by StartDiscovery, through the scan, not at start.
    BUS.add_message_handler(answer_standard)
    await BUS.request_name('org.bluez')
    print('READY', flush=True)
    await asyncio.Future()


def export(path, props):
    """Exports a scanned device with its Properties and Device1 methods, and announces it."""
    OBJECTS[path] = props
    index = int(path[-2:], 16)
    SERVICES[path] = [Device(index)]
    for service in SERVICES[path]:
        BUS.export(path, service)
    emit_interfaces_added(path)


if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
