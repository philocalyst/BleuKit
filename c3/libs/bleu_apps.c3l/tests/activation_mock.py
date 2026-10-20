#!/usr/bin/env python3
"""Mock D-Bus Application service for tests/run.sh, written with python-dbus-next.

It owns org.example.Activatable and exports org.freedesktop.Application at
/org/example/Activatable. It also owns org.example.Hang, whose Activate never
answers, so a launch must time out instead of running the Exec line. Every call is
appended to the file named by the BLEU_MOCK_LOG environment variable, one line per
call, so the test can check which method was called with which arguments.
"""
import asyncio
import os
import sys

from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, method

PATH = '/org/example/Activatable'
NAME = 'org.example.Activatable'
HANG_PATH = '/org/example/Hang'
HANG_NAME = 'org.example.Hang'
LOG = os.environ['BLEU_MOCK_LOG']


def log(line):
    with open(LOG, 'a', encoding='utf-8') as handle:
        handle.write(line + '\n')


def platform_value(platform_data, key):
    entry = platform_data.get(key)
    return entry.value if entry is not None else ''


class Application(ServiceInterface):
    def __init__(self):
        super().__init__('org.freedesktop.Application')

    @method()
    def Activate(self, platform_data: 'a{sv}'):
        log(f"Activate startup={platform_value(platform_data, 'desktop-startup-id')} "
            f"token={platform_value(platform_data, 'activation-token')}")

    @method()
    def Open(self, uris: 'as', platform_data: 'a{sv}'):
        log('Open ' + ' '.join(uris))

    @method()
    def ActivateAction(self, action_name: 's', parameter: 'av', platform_data: 'a{sv}'):
        log(f'ActivateAction {action_name}')


class Hanging(ServiceInterface):
    def __init__(self):
        super().__init__('org.freedesktop.Application')

    @method()
    async def Activate(self, platform_data: 'a{sv}'):
        log('Hang Activate')
        # Accepted, never answered: the client's call must time out.
        await asyncio.get_running_loop().create_future()


async def main():
    bus = await MessageBus(negotiate_unix_fd=True).connect()
    bus.export(PATH, Application())
    bus.export(HANG_PATH, Hanging())
    await bus.request_name(NAME)
    await bus.request_name(HANG_NAME)
    print('READY', flush=True)
    await asyncio.get_running_loop().create_future()


if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
