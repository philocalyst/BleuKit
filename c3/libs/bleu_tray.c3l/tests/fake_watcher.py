# A StatusNotifierWatcher written for the test, on the session bus: it owns org.kde.StatusNotifierWatcher
# so that the tray host under test must follow it rather than serve it. It normalises registrations as
# the specification says (a bare bus name gets /StatusNotifierItem) and announces them with signals.
# Lines start with "WATCHER".
import asyncio
from dbus_next import PropertyAccess
from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, method, dbus_property, signal

WATCHER = 'org.kde.StatusNotifierWatcher'
WATCHER_PATH = '/StatusNotifierWatcher'
DEFAULT_PATH = '/StatusNotifierItem'


class Watcher(ServiceInterface):
    def __init__(self):
        super().__init__(WATCHER)
        self.items = []
        self.hosts = []

    @method()
    def RegisterStatusNotifierItem(self, service: 's'):
        canonical = service if '/' in service else service + DEFAULT_PATH
        print('WATCHER item', canonical, flush=True)
        if canonical not in self.items:
            self.items.append(canonical)
            self.StatusNotifierItemRegistered(canonical)

    @method()
    def RegisterStatusNotifierHost(self, service: 's'):
        print('WATCHER host', service, flush=True)
        self.hosts.append(service)
        self.StatusNotifierHostRegistered()

    @dbus_property(access=PropertyAccess.READ)
    def RegisteredStatusNotifierItems(self) -> 'as':
        return list(self.items)

    @dbus_property(access=PropertyAccess.READ)
    def IsStatusNotifierHostRegistered(self) -> 'b':
        return len(self.hosts) > 0

    @dbus_property(access=PropertyAccess.READ)
    def ProtocolVersion(self) -> 'i':
        return 0

    @signal()
    def StatusNotifierItemRegistered(self, service: 's') -> 's':
        return service

    @signal()
    def StatusNotifierHostRegistered(self):
        return


async def main():
    bus = await MessageBus().connect()
    bus.export(WATCHER_PATH, Watcher())
    await bus.request_name(WATCHER)
    print('WATCHER ready', flush=True)
    await bus.wait_for_disconnect()


if __name__ == '__main__':
    asyncio.run(main())
