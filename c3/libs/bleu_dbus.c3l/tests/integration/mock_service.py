#!/usr/bin/env python3
"""Mock D-Bus service for tests/integration.sh, written with python-dbus-next.

It owns org.bleu.Mock and exports, at /org/bleu/Mock:

* org.bleu.Mock: Echo, Add, Describe (a{sv} with nested variants), Fail (an
  error reply), PingClient (calls Peer.Ping back on the caller), Slow (replies
  after 1.5 s), Touch (emits PropertiesChanged and
  the Ping signal), AddItem / RemoveItem (object tree changes), ReadFd (reads a
  descriptor that arrived with the call), and the properties State (read-write)
  and Label (read-only);
* org.freedesktop.DBus.ObjectManager: GetManagedObjects. Exporting or
  unexporting an object under it makes python-dbus-next emit InterfacesAdded
  or InterfacesRemoved itself, from the object's path (the mock does not emit
  them a second time).

It connects with unix-fd negotiation, so descriptors can arrive with calls.
Prints READY on stdout once the name is owned.
"""
import asyncio
import os
import sys

from dbus_next import DBusError, Message, MessageType, Variant
from dbus_next.aio import MessageBus
from dbus_next.service import PropertyAccess, ServiceInterface, dbus_property, method, signal

ROOT = '/org/bleu/Mock'
ITEM_INTERFACE = 'org.bleu.Mock.Item'


class Item(ServiceInterface):
    def __init__(self, size):
        super().__init__(ITEM_INTERFACE)
        self.size = size

    @dbus_property(access=PropertyAccess.READ)
    def Size(self) -> 'u':
        return self.size


class ObjectManager(ServiceInterface):
    def __init__(self):
        super().__init__('org.freedesktop.DBus.ObjectManager')

    @method()
    def GetManagedObjects(self) -> 'a{oa{sa{sv}}}':
        return {path: {ITEM_INTERFACE: {'Size': Variant('u', item.size)}}
                for path, item in ITEMS.items()}


class Mock(ServiceInterface):
    def __init__(self):
        super().__init__('org.bleu.Mock')
        self._state = 7

    @method()
    def Echo(self, text: 's') -> 's':
        return text

    @method()
    def Add(self, a: 'i', b: 'i') -> 'i':
        return a + b

    @method()
    def Describe(self) -> 'a{sv}':
        return {
            'name': Variant('s', 'bleu'),
            'nested': Variant('a{sv}', {
                'depth': Variant('u', 2),
                'list': Variant('as', ['a', 'b']),
            }),
            'pi': Variant('d', 3.5),
        }

    @method()
    async def PingClient(self, name: 's') -> 's':
        # Peer.Ping back to the caller: the client must answer while it pumps.
        reply = await BUS.call(Message(destination=name, path='/org/bleu/Client',
                                       interface='org.freedesktop.DBus.Peer', member='Ping'))
        if reply.message_type == MessageType.ERROR:
            return 'error: ' + reply.error_name
        return 'pong'

    @method()
    def Fail(self) -> 's':
        raise DBusError('org.bleu.Mock.Error.Boom', 'the mock failed on purpose')

    @method()
    async def Slow(self) -> 's':
        await asyncio.sleep(1.5)
        return 'late'

    @method()
    def Touch(self) -> 's':
        self.emit_properties_changed({'State': self._state})
        self.Ping('touched')
        return 'touched'

    @signal()
    def Ping(self, text: 's') -> 's':
        return text

    @method()
    def AddItem(self, name: 's', size: 'u') -> 's':
        path = f'{ROOT}/{name}'
        item = Item(size)
        ITEMS[path] = item
        BUS.export(path, item)
        return path

    @method()
    def RemoveItem(self, name: 's') -> 's':
        path = f'{ROOT}/{name}'
        ITEMS.pop(path, None)
        BUS.unexport(path)
        return path

    @dbus_property(access=PropertyAccess.READWRITE)
    def State(self) -> 'u':
        return self._state

    @State.setter
    def State(self, value: 'u'):
        self._state = value

    @dbus_property(access=PropertyAccess.READ)
    def Label(self) -> 's':
        return 'read only'


ITEMS = {}
BUS = None
OBJECT_MANAGER = None


def answer_read_fd(message):
    """Replies to ReadFd with the text read from the descriptor sent with the call."""
    if message.message_type != MessageType.METHOD_CALL or message.member != 'ReadFd':
        return None
    if not message.unix_fds:
        return Message.new_error(message, 'org.freedesktop.DBus.Error.InvalidArgs', 'no descriptor')
    fd = message.unix_fds[0]
    try:
        data = os.read(fd, 4096)
    finally:
        os.close(fd)
    return Message.new_method_return(message, 's', [data.decode()])


async def main():
    global BUS, OBJECT_MANAGER
    BUS = await MessageBus(negotiate_unix_fd=True).connect()
    mock = Mock()
    OBJECT_MANAGER = ObjectManager()
    for name, size in (('item1', 11), ('item2', 22)):
        path = f'{ROOT}/{name}'
        ITEMS[path] = Item(size)
        BUS.export(path, ITEMS[path])
    BUS.export(ROOT, mock)
    BUS.export(ROOT, OBJECT_MANAGER)
    BUS.add_message_handler(answer_read_fd)
    await BUS.request_name('org.bleu.Mock')
    print('READY', flush=True)
    await asyncio.get_running_loop().create_future()


if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
