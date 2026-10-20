#!/usr/bin/env python3
"""Client for the notification example (examples/notifications_server_sketch.c3).

Checks the four specified methods of org.freedesktop.Notifications, the two
signals, replacement of a notification, and the error answer to a call with the
wrong arguments. Prints PASS or FAIL per check and exits with the number of
failures. Run with -I by tests/integration.sh, with DBUS_SESSION_BUS_ADDRESS set.
"""
import asyncio
import sys

from dbus_next import DBusError, Message, MessageType, Variant
from dbus_next.aio import MessageBus

NAME = 'org.freedesktop.Notifications'
PATH = '/org/freedesktop/Notifications'
INTERFACE = 'org.freedesktop.Notifications'

failures = 0


def check(ok, what):
    global failures
    print(('PASS ' if ok else 'FAIL ') + what, flush=True)
    if not ok:
        failures += 1


async def main():
    bus = await MessageBus().connect()
    intro = await bus.introspect(NAME, PATH)
    obj = bus.get_proxy_object(NAME, PATH, intro)
    daemon = obj.get_interface(INTERFACE)

    name, vendor, version, spec = await daemon.call_get_server_information()
    check((name, vendor) == ('bleu', 'Bleu') and spec == '1.2', 'GetServerInformation returns the daemon identity')
    check(await daemon.call_get_capabilities() == ['body', 'actions'], 'GetCapabilities lists body and actions')

    closed = []
    actions = []
    daemon.on_notification_closed(lambda nid, reason: closed.append((nid, reason)))
    daemon.on_action_invoked(lambda nid, key: actions.append((nid, key)))

    hints = {'urgency': Variant('y', 1)}
    first = await daemon.call_notify('test-app', 0, '', 'Summary', 'Body', ['default', 'Open'], hints, -1)
    check(isinstance(first, int) and first > 0, f'Notify returns an identifier ({first})')
    again = await daemon.call_notify('test-app', first, '', 'Replaced', 'Body', [], hints, -1)
    check(again == first, 'Notify with replaces_id answers with the same identifier')

    await daemon.call_simulate_action(first, 'default')
    check(actions == [(first, 'default')], 'ActionInvoked reaches a subscriber with the key')

    await daemon.call_close_notification(first)
    check(closed == [(first, 3)], 'CloseNotification emits NotificationClosed with reason 3')
    await daemon.call_close_notification(first)
    await asyncio.sleep(0.1)
    check(len(closed) == 1, 'closing an unknown notification emits nothing')

    msg = Message(destination=NAME, path=PATH, interface=INTERFACE, member='CloseNotification',
                  signature='s', body=['not a number'])
    reply = await bus.call(msg)
    check(reply.message_type == MessageType.ERROR and reply.error_name == 'org.freedesktop.DBus.Error.InvalidArgs',
          'a call with the wrong arguments gets InvalidArgs')

    print(f'FAILURES {failures}', flush=True)
    bus.disconnect()
    return failures


if __name__ == '__main__':
    sys.exit(asyncio.run(main()))
