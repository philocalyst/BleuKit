# A host written against the specification, with dbus-next: it reads the watcher, finds our own
# icon, reads its properties and menu, and acts on it. Lines start with "HOST".
import asyncio, sys
from dbus_next import Variant
from dbus_next.aio import MessageBus
from dbus_next import Message

WATCHER = 'org.kde.StatusNotifierWatcher'
WATCHER_PATH = '/StatusNotifierWatcher'
PROPS = 'org.freedesktop.DBus.Properties'
ITEM = 'org.kde.StatusNotifierItem'


async def call(bus, destination, path, interface, member, signature='', body=()):
    reply = await bus.call(Message(destination=destination, path=path, interface=interface,
                                   member=member, signature=signature, body=list(body)))
    if reply.message_type.name != 'METHOD_RETURN':
        raise RuntimeError('%s: %s' % (member, reply.body))
    return reply.body


async def main():
    bus = await MessageBus().connect()
    # The watcher is served by the probe; wait until it has our item.
    own = None
    for _ in range(100):
        (items,) = await call(bus, WATCHER, WATCHER_PATH, PROPS, 'Get', 'ss', [WATCHER, 'RegisteredStatusNotifierItems'])
        items = items.value
        own = [x for x in items if x.startswith('org.kde.StatusNotifierItem-')]
        if own:
            break
        await asyncio.sleep(0.1)
    print('HOST registered', ' '.join(items), flush=True)
    if not own:
        print('HOST own icon missing', flush=True)
        return 1
    (host,) = await call(bus, WATCHER, WATCHER_PATH, PROPS, 'Get', 'ss', [WATCHER, 'IsStatusNotifierHostRegistered'])
    print('HOST host_registered', host.value, flush=True)
    bus_name, path = own[0].split('/', 1)
    path = '/' + path
    (props,) = await call(bus, bus_name, path, PROPS, 'GetAll', 's', [ITEM])
    print('HOST own_title', props['Title'].value, flush=True)
    print('HOST own_icon', props['IconName'].value, flush=True)
    print('HOST own_menu', props['Menu'].value, flush=True)
    (layout,) = await call(bus, bus_name, '/MenuBar', 'com.canonical.dbusmenu', 'GetLayout', 'iias', [0, -1, []])
    revision, root = layout
    for child in root[2]:
        node = child.value
        print('HOST own_menu_entry', node[0], node[1].get('label', Variant('s', '')).value, flush=True)
    await call(bus, bus_name, path, ITEM, 'Activate', 'ii', [5, 6])
    print('HOST activated own icon', flush=True)
    await call(bus, bus_name, '/MenuBar', 'com.canonical.dbusmenu', 'Event', 'isvu',
               [3, 'clicked', Variant('i', 0), 0])
    print('HOST clicked own menu', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(asyncio.run(main()))
