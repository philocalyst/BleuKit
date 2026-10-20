# A fake StatusNotifierItem with a dbusmenu, on the session bus, for tests/run.sh.
#
#   fake_item.py <watcher-bus> : registers org.test.FakeItem/StatusNotifierItem with the watcher,
#   changes its title and icon (NewTitle, NewIcon), waits for the menu click, then disconnects,
#   which makes the item vanish. Every action is printed with a "FAKE" prefix.
import asyncio
from dbus_next import Variant, PropertyAccess
from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, method, dbus_property, signal
from dbus_next import Message

WATCHER = 'org.kde.StatusNotifierWatcher'
WATCHER_PATH = '/StatusNotifierWatcher'
ITEM_NAME = 'org.test.FakeItem'
REGISTRATION = 'org.test.FakeItem/StatusNotifierItem'


def pixels_argb(width, height):
    # Pixel i: alpha 0x80, then red 0x11, green 0x22, blue 0x33 for the first pixel; the rest count up.
    out = bytearray()
    for i in range(width * height):
        if i == 0:
            out += bytes([0x80, 0x11, 0x22, 0x33])
        else:
            out += bytes([0xFF, i, i, i])
    return bytes(out)


class Item(ServiceInterface):
    def __init__(self):
        super().__init__('org.kde.StatusNotifierItem')
        self.title = 'Probe Item'
        self.icon = 'face-smile'

    @dbus_property(access=PropertyAccess.READ)
    def Category(self) -> 's':
        return 'ApplicationStatus'

    @dbus_property(access=PropertyAccess.READ)
    def Id(self) -> 's':
        return 'probe-item'

    @dbus_property(access=PropertyAccess.READ)
    def Title(self) -> 's':
        return self.title

    @dbus_property(access=PropertyAccess.READ)
    def Status(self) -> 's':
        return 'Active'

    @dbus_property(access=PropertyAccess.READ)
    def IconName(self) -> 's':
        return self.icon

    @dbus_property(access=PropertyAccess.READ)
    def IconPixmap(self) -> 'a(iiay)':
        return [[3, 2, pixels_argb(3, 2)]]

    @dbus_property(access=PropertyAccess.READ)
    def ItemIsMenu(self) -> 'b':
        return False

    @dbus_property(access=PropertyAccess.READ)
    def Menu(self) -> 'o':
        return '/MenuBar'

    @dbus_property(access=PropertyAccess.READ)
    def IconThemePath(self) -> 's':
        return ''

    @dbus_property(access=PropertyAccess.READ)
    def ToolTip(self) -> '(sa(iiay)ss)':
        return ['', [], 'Tip title', 'Tip body']

    @method()
    def Activate(self, x: 'i', y: 'i'):
        print('FAKE activate', x, y, flush=True)

    @method()
    def SecondaryActivate(self, x: 'i', y: 'i'):
        print('FAKE secondary', x, y, flush=True)

    @method()
    def ContextMenu(self, x: 'i', y: 'i'):
        print('FAKE context', x, y, flush=True)

    @method()
    def Scroll(self, delta: 'i', orientation: 's'):
        print('FAKE scroll', delta, orientation, flush=True)

    @signal()
    def NewTitle(self):
        return

    @signal()
    def NewIcon(self):
        return


def entry(node_id, props, children=()):
    return [node_id, props, [Variant('(ia{sv}av)', c) for c in children]]


class Menu(ServiceInterface):
    def __init__(self):
        super().__init__('com.canonical.dbusmenu')

    def node(self, node_id):
        # The root has a mnemonic label, a submenu whose children come only on AboutToShow, a
        # separator and a disabled entry. The submenu has a double underscore and a checkmark.
        if node_id == 0:
            return entry(0, {}, [
                entry(1, {'label': Variant('s', '_Open'), 'enabled': Variant('b', True)}),
                entry(2, {'label': Variant('s', 'Recent'), 'children-display': Variant('s', 'submenu')}),
                entry(4, {'type': Variant('s', 'separator')}),
                entry(6, {'label': Variant('s', 'Quit'), 'enabled': Variant('b', False)}),
            ])
        if node_id == 2:
            return entry(2, {'label': Variant('s', 'Recent'), 'children-display': Variant('s', 'submenu')}, [
                entry(5, {
                    'label': Variant('s', 'Item __one'),
                    'toggle-type': Variant('s', 'checkmark'),
                    'toggle-state': Variant('i', 1),
                    'shortcut': Variant('aas', [['Control', 's']]),
                }),
                entry(7, {'label': Variant('s', 'Two')}),
            ])
        return entry(node_id, {})

    @method()
    def GetLayout(self, parentId: 'i', recursionDepth: 'i', propertyNames: 'as') -> 'u(ia{sv}av)':
        print('FAKE getlayout', parentId, recursionDepth, flush=True)
        return [1, self.node(parentId)]

    @method()
    def Event(self, id: 'i', eventId: 's', data: 'v', timestamp: 'u'):
        print('FAKE event', eventId, id, flush=True)
        if eventId == 'clicked':
            self.clicked.set()

    @method()
    def AboutToShow(self, id: 'i') -> 'b':
        print('FAKE abouttoshow', id, flush=True)
        return id == 2

    @dbus_property(access=PropertyAccess.READ)
    def Version(self) -> 'u':
        return 3

    @dbus_property(access=PropertyAccess.READ)
    def TextDirection(self) -> 's':
        return 'ltr'

    @dbus_property(access=PropertyAccess.READ)
    def Status(self) -> 's':
        return 'normal'

    @dbus_property(access=PropertyAccess.READ)
    def IconThemePath(self) -> 'as':
        return []


async def wait_for_watcher(bus):
    while True:
        owned = await bus.call(Message(destination='org.freedesktop.DBus', path='/org/freedesktop/DBus',
                                       interface='org.freedesktop.DBus', member='NameHasOwner',
                                       signature='s', body=[WATCHER]))
        if owned.body[0]:
            return
        await asyncio.sleep(0.05)


async def main():
    bus = await MessageBus().connect()
    item = Item()
    menu = Menu()
    menu.clicked = asyncio.Event()
    bus.export('/StatusNotifierItem', item)
    bus.export('/MenuBar', menu)
    await bus.request_name(ITEM_NAME)
    await wait_for_watcher(bus)
    reply = await bus.call(Message(destination=WATCHER, path=WATCHER_PATH, interface=WATCHER,
                                   member='RegisterStatusNotifierItem', signature='s', body=[REGISTRATION]))
    print('FAKE registered', reply.message_type, flush=True)
    await asyncio.sleep(3)
    item.title = 'Renamed Item'
    item.NewTitle()
    print('FAKE newtitle', flush=True)
    await asyncio.sleep(2)
    item.icon = 'face-wink'
    item.NewIcon()
    print('FAKE newicon', flush=True)
    try:
        await asyncio.wait_for(menu.clicked.wait(), 20)
    except asyncio.TimeoutError:
        print('FAKE no click', flush=True)
    await asyncio.sleep(1)
    print('FAKE vanishing', flush=True)
    bus.disconnect()
    await bus.wait_for_disconnect()


if __name__ == '__main__':
    asyncio.run(main())
