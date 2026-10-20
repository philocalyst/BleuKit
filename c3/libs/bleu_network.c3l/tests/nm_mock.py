#!/usr/bin/env python3
"""Mock of org.freedesktop.NetworkManager for tests/run.sh, written with python-dbus-next.

It serves the subset of the NetworkManager D-Bus API that the bleu_network
NetworkManager backend uses (see docs/research/network.md section 2.1.1):

* the root object: GetDevices, ActivateConnection, AddAndActivateConnection2,
  DeactivateConnection; properties WirelessEnabled (read-write), Connectivity,
  PrimaryConnection, WirelessHardwareEnabled;
* one Wi-Fi device (wlan0) and one Ethernet device (eth0), with State,
  StateReason, Interface and DeviceType; Device.Disconnect; StateChanged;
* Device.Wireless: GetAllAccessPoints, RequestScan, ActiveAccessPoint, LastScan;
* access points with Ssid (ay), Strength, Frequency, HwAddress, Flags, WpaFlags, RsnFlags;
* Settings: ListConnections; Settings.Connection: GetSettings, Update2, Delete;
* active connections: Devices, Id, Type.

Activation follows NetworkManager's device state machine as signalled through
StateChanged: PREPARE(40) -> CONFIG(50) -> [NEED_AUTH(60) with NO_SECRETS(7)
when the secret is missing or wrong] -> IP_CONFIG(70) -> ACTIVATED(100).
A wrong passphrase ends in FAILED(120) with NO_SECRETS(7). An unknown SSID
ends in FAILED(120) with SSID_NOT_FOUND(53).

Environment: none. The bus address comes from DBUS_SYSTEM_BUS_ADDRESS (run.sh
sets it to a private dbus-daemon). Prints READY on stdout once the name is owned.
"""
import asyncio
import os
import sys

from dbus_next import Message, MessageType, Variant
from dbus_next.aio import MessageBus
from dbus_next.service import PropertyAccess, ServiceInterface, dbus_property, method, signal

NM_NAME = 'org.freedesktop.NetworkManager'
ROOT = '/org/freedesktop/NetworkManager'
DEVICES = ROOT + '/Devices'
ACCESS_POINTS = ROOT + '/AccessPoint'
SETTINGS = ROOT + '/Settings'
ACTIVE = ROOT + '/ActiveConnection'

NM_IFACE = 'org.freedesktop.NetworkManager'
DEVICE_IFACE = 'org.freedesktop.NetworkManager.Device'
WIRELESS_IFACE = 'org.freedesktop.NetworkManager.Device.Wireless'
AP_IFACE = 'org.freedesktop.NetworkManager.AccessPoint'
SETTINGS_IFACE = 'org.freedesktop.NetworkManager.Settings'
CONNECTION_IFACE = 'org.freedesktop.NetworkManager.Settings.Connection'
ACTIVE_IFACE = 'org.freedesktop.NetworkManager.Connection.Active'

# NM_DEVICE_STATE / NM_DEVICE_STATE_REASON values (nm-dbus-types; nmrs device.rs, state_reason.rs).
DISCONNECTED, PREPARE, CONFIG, NEED_AUTH, IP_CONFIG, ACTIVATED, DEACTIVATING, FAILED = 30, 40, 50, 60, 70, 100, 110, 120
UNAVAILABLE = 20
REASON_NO_SECRETS, REASON_SSID_NOT_FOUND, REASON_USER_REQUESTED = 7, 53, 39
TYPE_ETHERNET, TYPE_WIFI = 1, 2

# Access points: SSID octets, flags (NM80211ApFlags, NM80211ApSecurityFlags), strength, MHz, passphrase.
# The third SSID is not UTF-8 on purpose: the backend must keep its bytes.
ACCESS_POINTS_TABLE = [
    {'ssid': b'Cafe', 'flags': 0, 'wpa': 0, 'rsn': 0, 'strength': 70, 'mhz': 2437, 'psk': None},
    {'ssid': b'Office', 'flags': 1, 'wpa': 0, 'rsn': 0x100, 'strength': 90, 'mhz': 5180, 'psk': 'correct horse'},
    {'ssid': b'\xff\xfeLegacy', 'flags': 1, 'wpa': 0, 'rsn': 0x100, 'strength': 40, 'mhz': 2412, 'psk': 'legacy-pass'},
    {'ssid': b'Guest-SAE', 'flags': 1, 'wpa': 0, 'rsn': 0x400, 'strength': 60, 'mhz': 5955, 'psk': 'sae-password'},
    {'ssid': b'', 'flags': 1, 'wpa': 0, 'rsn': 0x100, 'strength': 99, 'mhz': 2462, 'psk': None},  # hidden: not listed
]


class State:
    """Everything the mock changes over time, shared by the interfaces."""

    def __init__(self, bus):
        self.bus = bus
        self.agent_name = None  # the unique name of the secret agent that registered, if any
        self.radio = True
        self.last_scan = 1000
        self.wifi_state = DISCONNECTED
        self.wifi_reason = 0
        self.active_path = '/'
        self.active_counter = 0
        self.profiles = {}      # path -> settings dict (plain python)
        self.profile_counter = 0
        self.connections = {}   # path -> ConnectionIface
        self.ap_ifaces = []
        self.device = None
        self.wireless = None
        self.root = None
        self.active_iface = None
        self.connected_ap_path = '/'
        self.generation = 0

    def set_wifi_state(self, state, reason):
        old = self.wifi_state
        self.wifi_state, self.wifi_reason = state, reason
        if self.device is not None:
            self.device.emit_properties_changed({'State': state, 'StateReason': [state, reason]})
            self.device.StateChanged(state, old, reason)
        if state == DISCONNECTED:
            self.connected_ap_path = '/'
            if self.active_path != '/':
                self.drop_active()

    def drop_active(self):
        if self.active_iface is not None:
            self.bus.unexport(self.active_path, ACTIVE_IFACE)
        self.active_iface = None
        self.active_path = '/'
        if self.root is not None:
            self.root.emit_properties_changed({'PrimaryConnection': '/'})

    def make_active(self, profile_path):
        self.active_counter += 1
        self.active_path = '%s/%d' % (ACTIVE, self.active_counter)
        self.active_iface = ActiveIface(self, profile_path)
        self.bus.export(self.active_path, self.active_iface)
        self.root.emit_properties_changed({'PrimaryConnection': self.active_path})
        return self.active_path


def ap_for_ssid(ssid):
    for index, ap in enumerate(ACCESS_POINTS_TABLE):
        if ap['ssid'] == ssid and ssid:
            return index, ap
    return None, None


class ActiveIface(ServiceInterface):
    def __init__(self, state, profile_path):
        super().__init__(ACTIVE_IFACE)
        self.state = state
        self.profile_path = profile_path

    @dbus_property(access=PropertyAccess.READ)
    def Devices(self) -> 'ao':
        return [DEVICES + '/1']

    @dbus_property(access=PropertyAccess.READ)
    def Connection(self) -> 'o':
        return self.profile_path

    @dbus_property(access=PropertyAccess.READ)
    def Id(self) -> 's':
        return 'profile'

    @dbus_property(access=PropertyAccess.READ)
    def Type(self) -> 's':
        return '802-11-wireless'


class ConnectionIface(ServiceInterface):
    def __init__(self, state, path):
        super().__init__(CONNECTION_IFACE)
        self.state = state
        self.path = path

    @method()
    def GetSettings(self) -> 'a{sa{sv}}':
        return self.state.profiles[self.path]

    @method()
    def Update2(self, settings: 'a{sa{sv}}', flags: 'u', args: 'a{sv}') -> 'a{sv}':
        self.state.profiles[self.path] = settings
        return {}

    @method()
    def Delete(self):
        self.state.profiles.pop(self.path, None)
        self.state.bus.unexport(self.path, CONNECTION_IFACE)
        self.state.connections.pop(self.path, None)


class SettingsIface(ServiceInterface):
    def __init__(self, state):
        super().__init__(SETTINGS_IFACE)
        self.state = state

    @method()
    def ListConnections(self) -> 'ao':
        return list(self.state.profiles.keys())


class APIface(ServiceInterface):
    def __init__(self, index, ap):
        super().__init__(AP_IFACE)
        self.ap = ap
        self.index = index

    @dbus_property(access=PropertyAccess.READ)
    def Ssid(self) -> 'ay':
        return self.ap['ssid']

    @dbus_property(access=PropertyAccess.READ)
    def Strength(self) -> 'y':
        return self.ap['strength']

    @dbus_property(access=PropertyAccess.READ)
    def Frequency(self) -> 'u':
        return self.ap['mhz']

    @dbus_property(access=PropertyAccess.READ)
    def HwAddress(self) -> 's':
        return '02:00:00:00:00:%02x' % (self.index + 1)

    @dbus_property(access=PropertyAccess.READ)
    def Flags(self) -> 'u':
        return self.ap['flags']

    @dbus_property(access=PropertyAccess.READ)
    def WpaFlags(self) -> 'u':
        return self.ap['wpa']

    @dbus_property(access=PropertyAccess.READ)
    def RsnFlags(self) -> 'u':
        return self.ap['rsn']


class WirelessIface(ServiceInterface):
    def __init__(self, state):
        super().__init__(WIRELESS_IFACE)
        self.state = state

    @method()
    def GetAllAccessPoints(self) -> 'ao':
        return [ACCESS_POINTS + '/%d' % (i + 1) for i in range(len(ACCESS_POINTS_TABLE))]

    @method()
    def RequestScan(self, options: 'a{sv}'):
        loop = asyncio.get_running_loop()
        loop.call_later(0.2, self.finish_scan)

    def finish_scan(self):
        self.state.last_scan += 1
        self.emit_properties_changed({'LastScan': self.state.last_scan})

    @dbus_property(access=PropertyAccess.READ)
    def LastScan(self) -> 'x':
        return self.state.last_scan

    @dbus_property(access=PropertyAccess.READ)
    def ActiveAccessPoint(self) -> 'o':
        return self.state.connected_ap_path


class DeviceIface(ServiceInterface):
    def __init__(self, state):
        super().__init__(DEVICE_IFACE)
        self.state = state

    @method()
    def Disconnect(self):
        if self.state.wifi_state in (DISCONNECTED, UNAVAILABLE):
            return
        self.state.set_wifi_state(DEACTIVATING, REASON_USER_REQUESTED)
        loop = asyncio.get_running_loop()
        loop.call_later(0.05, lambda: self.state.set_wifi_state(DISCONNECTED, REASON_USER_REQUESTED))

    @signal()
    def StateChanged(self, new_state: 'u', old_state: 'u', reason: 'u') -> 'uuu':
        return [new_state, old_state, reason]

    @dbus_property(access=PropertyAccess.READ)
    def State(self) -> 'u':
        return self.state.wifi_state

    @dbus_property(access=PropertyAccess.READ)
    def StateReason(self) -> '(uu)':
        return [self.state.wifi_state, self.state.wifi_reason]

    @dbus_property(access=PropertyAccess.READ)
    def Interface(self) -> 's':
        return 'wlan0'

    @dbus_property(access=PropertyAccess.READ)
    def DeviceType(self) -> 'u':
        return TYPE_WIFI


class EthernetIface(ServiceInterface):
    def __init__(self):
        super().__init__(DEVICE_IFACE)

    @dbus_property(access=PropertyAccess.READ)
    def State(self) -> 'u':
        return ACTIVATED

    @dbus_property(access=PropertyAccess.READ)
    def StateReason(self) -> '(uu)':
        return [ACTIVATED, 0]

    @dbus_property(access=PropertyAccess.READ)
    def Interface(self) -> 's':
        return 'eth0'

    @dbus_property(access=PropertyAccess.READ)
    def DeviceType(self) -> 'u':
        return TYPE_ETHERNET


class AgentManagerIface(ServiceInterface):
    """Register and Unregister. The sender of Register is recorded by the bus message handler."""

    def __init__(self, state):
        super().__init__('org.freedesktop.NetworkManager.AgentManager')
        self.state = state

    @method()
    def Register(self, identifier: 's'):
        pass

    @method()
    def Unregister(self):
        self.state.agent_name = None


def on_message(state, msg):
    if msg.message_type == MessageType.METHOD_CALL and msg.interface == 'org.freedesktop.NetworkManager.AgentManager' and msg.member == 'Register':
        state.agent_name = msg.sender
    return None


class RootIface(ServiceInterface):
    def __init__(self, state):
        super().__init__(NM_IFACE)
        self.state = state

    @method()
    def GetDevices(self) -> 'ao':
        return [DEVICES + '/1', DEVICES + '/2']

    @method()
    def DeactivateConnection(self, active: 'o'):
        if active == self.state.active_path:
            self.state.set_wifi_state(DISCONNECTED, REASON_USER_REQUESTED)

    @method()
    def ActivateConnection(self, connection: 'o', device: 'o', specific: 'o') -> 'o':
        return self.state.activate(connection)

    @method()
    def AddAndActivateConnection2(self, connection: 'a{sa{sv}}', device: 'o', specific: 'o', options: 'a{sv}') -> 'ooa{sv}':
        try:
            return self._add_and_activate(connection)
        except Exception:
            import traceback
            traceback.print_exc()
            raise

    def _add_and_activate(self, connection):
        self.state.profile_counter += 1
        path = '%s/%d' % (SETTINGS + '/Connection', self.state.profile_counter)
        self.state.profiles[path] = connection
        self.state.connections[path] = self.state.export_connection(path)
        active = self.state.activate(path)
        return [path, active, {}]

    @dbus_property(access=PropertyAccess.READWRITE)
    def WirelessEnabled(self) -> 'b':
        return self.state.radio

    @WirelessEnabled.setter
    def WirelessEnabled(self, value: 'b'):
        self.state.radio = value
        self.emit_properties_changed({'WirelessEnabled': value})

    @dbus_property(access=PropertyAccess.READ)
    def WirelessHardwareEnabled(self) -> 'b':
        return True

    @dbus_property(access=PropertyAccess.READ)
    def Connectivity(self) -> 'u':
        return 4

    @dbus_property(access=PropertyAccess.READ)
    def PrimaryConnection(self) -> 'o':
        return self.state.active_path


def settings_value(settings, group, key):
    group_dict = settings.get(group)
    if group_dict is None or key not in group_dict:
        return None
    return group_dict[key].value


def _activate(self, profile_path):
    """Start an activation of a stored profile; returns the active connection path.

    Every activation has a generation. Timers of an older activation do nothing,
    as a real device would not report the failure of an attempt it has left.
    """
    self.generation += 1
    generation = self.generation
    loop = asyncio.get_running_loop()

    def later(delay, action):
        loop.call_later(delay, lambda: action() if self.generation == generation else None)

    settings = self.profiles[profile_path]
    ssid = settings_value(settings, '802-11-wireless', 'ssid')
    index, ap = ap_for_ssid(bytes(ssid) if ssid is not None else b'')
    if index is None:
        self.set_wifi_state(PREPARE, 0)
        later(0.05, lambda: self.set_wifi_state(FAILED, REASON_SSID_NOT_FOUND))
        return '/'
    self.connected_ap_path = ACCESS_POINTS + '/%d' % (index + 1)
    secured = ap['psk'] is not None
    key_mgmt = settings_value(settings, '802-11-wireless-security', 'key-mgmt')
    psk = settings_value(settings, '802-11-wireless-security', 'psk')
    active = self.make_active(profile_path)
    self.set_wifi_state(PREPARE, 0)

    def configure():
        self.set_wifi_state(CONFIG, 0)
        if secured and (key_mgmt is None or psk != ap['psk']):
            self.set_wifi_state(NEED_AUTH, REASON_NO_SECRETS)
            if psk is None and self.agent_name is not None:
                # No passphrase stored: NetworkManager asks its secret agent, which may answer or refuse.
                asyncio.ensure_future(ask_agent(self, generation, profile_path, settings, ap))
            else:
                # A wrong or missing passphrase with no agent to ask: the device fails.
                later(0.05, lambda: self.set_wifi_state(FAILED, REASON_NO_SECRETS))
            return
        self.set_wifi_state(IP_CONFIG, 0)
        later(0.05, lambda: self.set_wifi_state(ACTIVATED, 0))

    later(0.05, configure)
    return active


async def ask_agent(self, generation, profile_path, settings, ap):
    """GetSecrets on the registered agent (as NetworkManager does), then continue or fail the activation."""
    request = Message(destination=self.agent_name, path='/org/freedesktop/NetworkManager/SecretAgent',
                      interface='org.freedesktop.NetworkManager.SecretAgent', member='GetSecrets',
                      signature='a{sa{sv}}osasu', body=[settings, profile_path, '802-11-wireless-security', [], 1])
    reply = await self.bus.call(request)
    if self.generation != generation:
        return
    if reply.message_type == MessageType.ERROR:
        self.set_wifi_state(FAILED, REASON_NO_SECRETS)
        return
    secret = reply.body[0]['802-11-wireless-security']['psk'].value
    if secret == ap['psk']:
        self.set_wifi_state(IP_CONFIG, 0)
        asyncio.get_running_loop().call_later(0.05, lambda: self.set_wifi_state(ACTIVATED, 0) if self.generation == generation else None)
    else:
        self.set_wifi_state(FAILED, REASON_NO_SECRETS)


def _export_connection(self, path):
    iface = ConnectionIface(self, path)
    self.bus.export(path, iface)
    return iface


def main():
    asyncio.run(run())
    return 0


async def run():
    bus = await MessageBus(bus_address=os.environ['DBUS_SYSTEM_BUS_ADDRESS']).connect()
    state = State(bus)
    state.activate = lambda profile: _activate(state, profile)
    state.export_connection = lambda path: _export_connection(state, path)
    state.device = DeviceIface(state)
    state.wireless = WirelessIface(state)
    state.root = RootIface(state)
    ethernet = EthernetIface()
    settings = SettingsIface(state)
    bus.export(ROOT, state.root)
    bus.export(DEVICES + '/1', state.device)
    bus.export(DEVICES + '/1', state.wireless)
    bus.export(DEVICES + '/2', ethernet)
    bus.export(SETTINGS, settings)
    bus.export(ROOT + '/AgentManager', AgentManagerIface(state))
    bus.add_message_handler(lambda msg: on_message(state, msg))
    for index, ap in enumerate(ACCESS_POINTS_TABLE):
        bus.export(ACCESS_POINTS + '/%d' % (index + 1), APIface(index, ap))
    await bus.request_name(NM_NAME)
    print('READY', flush=True)
    await asyncio.get_running_loop().create_future()


if __name__ == '__main__':
    sys.exit(main())
