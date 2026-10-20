#!/usr/bin/env python3
"""Client side of the server suite in tests/integration.sh (see server_main.c3).

Calls every method that the C3 ObjectServer exports at /org/bleu/ServerTest,
reads and writes its properties, introspects it (python-dbus-next builds its
proxy objects from the XML, so a parse is a validity check), and checks the
signals: PropertiesChanged (changed and invalidated), the custom Notice signal,
InterfacesAdded and InterfacesRemoved. It sends descriptors both ways, checks
the standard errors, and a deferred reply. It prints PASS or FAIL per check and
exits with the number of failures. It leaves Count at 9 for server_client.c3,
and does not stop the server.

Run with -I, by tests/integration.sh, with DBUS_SESSION_BUS_ADDRESS set.
"""
import asyncio
import os
import sys

from dbus_next import DBusError, Message, MessageType, Variant
from dbus_next.aio import MessageBus

NAME = 'org.bleu.ServerTest'
PATH = '/org/bleu/ServerTest'
TEST = 'org.bleu.Test'
PROPERTIES = 'org.freedesktop.DBus.Properties'
MANAGER = 'org.freedesktop.DBus.ObjectManager'
PEER = 'org.freedesktop.DBus.Peer'
ITEM = 'org.bleu.Item'

failures = 0


def check(ok, what):
    global failures
    print(('PASS ' if ok else 'FAIL ') + what, flush=True)
    if not ok:
        failures += 1


async def raw(bus, member, sig='', body=(), iface=TEST, path=PATH, fds=(), name=NAME):
    """A method call written by hand, so that errors and descriptors can be inspected."""
    msg = Message(destination=name, path=path, interface=iface, member=member,
                  signature=sig, body=list(body), unix_fds=list(fds))
    return await bus.call(msg)


def is_error(reply, name):
    return reply.message_type == MessageType.ERROR and reply.error_name == name


async def main():
    bus = await MessageBus(negotiate_unix_fd=True).connect()

    # Introspection: dbus-next parses the XML into a Node, and builds proxies from it.
    intro = await bus.introspect(NAME, PATH)
    names = [i.name for i in intro.interfaces]
    check(TEST in names and MANAGER in names, 'introspection lists org.bleu.Test and ObjectManager')
    check(PROPERTIES in names and PEER in names, 'introspection lists the standard interfaces')
    obj = bus.get_proxy_object(NAME, PATH, intro)
    test = obj.get_interface(TEST)
    props = obj.get_interface(PROPERTIES)
    om = obj.get_interface(MANAGER)

    # Methods.
    check(await test.call_echo('from python') == 'from python', 'Echo round-trips a string')
    check(await test.call_add(40, 2) == 42, 'Add returns the sum')
    try:
        await test.call_fail()
        check(False, 'Fail raises')
    except DBusError as e:
        check(e.type == 'org.freedesktop.DBus.Error.AccessDenied', f'a fault becomes AccessDenied (got {e.type})')
    try:
        await test.call_named()
        check(False, 'Named raises')
    except DBusError as e:
        check(e.type == 'org.bleu.ServerTest.Error.Named', f'reply_error sends its own name (got {e.type})')

    reply = await raw(bus, 'Add', 's', ['not two numbers'])
    check(is_error(reply, 'org.freedesktop.DBus.Error.InvalidArgs'), 'a body of the wrong signature gets InvalidArgs')
    reply = await raw(bus, 'Nope')
    check(is_error(reply, 'org.freedesktop.DBus.Error.UnknownMethod'), 'an unknown method gets UnknownMethod')
    reply = await raw(bus, 'Echo', 's', ['x'], path='/org/bleu/nothing')
    check(is_error(reply, 'org.freedesktop.DBus.Error.UnknownObject'), 'an unknown path gets UnknownObject')
    reply = await raw(bus, 'Echo', 's', ['x'], iface='org.bleu.Missing')
    check(is_error(reply, 'org.freedesktop.DBus.Error.UnknownInterface'), 'an unknown interface gets UnknownInterface')
    reply = await raw(bus, 'Ping', iface=PEER)
    check(reply.message_type == MessageType.METHOD_RETURN, 'Peer.Ping is answered')

    # Properties. PropertiesChanged is collected for the rest of the run.
    changes = []
    props.on_properties_changed(lambda i, changed, invalidated: changes.append((i, changed, invalidated)))
    check((await props.call_get(TEST, 'Count')).value == 0, 'Count starts at 0')
    await props.call_set(TEST, 'Count', Variant('u', 9))
    check(changes and changes[-1][1]['Count'].value == 9, 'a Set announces the new value in PropertiesChanged')
    check((await props.call_get(TEST, 'Count')).value == 9, 'the set value is read back')
    everything = await props.call_get_all(TEST)
    check(everything['Label'].value == 'label' and everything['Count'].value == 9, 'GetAll returns the readable properties')
    reply = await raw(bus, 'Set', 'ssv', [TEST, 'Label', Variant('s', 'x')], iface=PROPERTIES)
    check(is_error(reply, 'org.freedesktop.DBus.Error.PropertyReadOnly'), 'Set on a read-only property is refused')
    reply = await raw(bus, 'Set', 'ssv', [TEST, 'Count', Variant('s', 'nine')], iface=PROPERTIES)
    check(is_error(reply, 'org.freedesktop.DBus.Error.InvalidArgs'), 'Set with the wrong type is refused')
    await test.call_touch()
    await asyncio.sleep(0.1)
    check(any(inv == ['Label'] for _, _, inv in changes), 'an INVALIDATES property is named without its value')

    # Signals. The server emits Notice before it answers Emit, so it has arrived by then.
    notices = []
    test.on_notice(lambda text: notices.append(text))
    await test.call_emit('hello signal')
    check(notices == ['hello signal'], 'a signal the interface declares reaches a subscriber')

    # A deferred reply: pending until Complete answers it.
    task = asyncio.ensure_future(test.call_defer('later'))
    await asyncio.sleep(0.1)
    check(not task.done(), 'a deferred call is not answered before its handler completes it')
    await test.call_complete('the answer')
    check(await asyncio.wait_for(task, 5) == 'the answer', 'a deferred reply arrives once completed')

    # Descriptors, both ways.
    reply = await raw(bus, 'MakeFd')
    check(reply.message_type == MessageType.METHOD_RETURN and len(reply.unix_fds) == 1, 'MakeFd sends a descriptor')
    if reply.unix_fds:
        fd = reply.unix_fds[0]
        data = os.read(fd, 64)
        os.close(fd)
        check(data == b'from-server', 'the descriptor from the server reads its data')
    read_end, write_end = os.pipe()
    os.write(write_end, b'from python')
    os.close(write_end)
    reply = await raw(bus, 'ReadFd', 'h', [0], fds=[read_end])
    os.close(read_end)
    check(reply.message_type == MessageType.METHOD_RETURN and reply.body == ['from python'],
          'a descriptor sent to the server is read by it')

    # ObjectManager: a child exported at run time is announced, listed, and withdrawn.
    added = []
    removed = []
    om.on_interfaces_added(lambda p, ifaces: added.append((p, ifaces)))
    om.on_interfaces_removed(lambda p, names: removed.append((p, names)))
    await test.call_add_child('one')
    check(added and added[-1][0] == PATH + '/one' and ITEM in added[-1][1],
          'InterfacesAdded names the new child and its interface')
    managed = await om.call_get_managed_objects()
    child = managed.get(PATH + '/one', {})
    check(ITEM in child and child[ITEM]['Kind'].value == 'item',
          'GetManagedObjects lists the child with its readable properties')
    again = await bus.introspect(NAME, PATH)
    check(any(n.name == 'one' for n in again.nodes), 'introspection lists the child as a node')
    await test.call_remove_child('one')
    check(removed and removed[-1] == (PATH + '/one', [ITEM]), 'InterfacesRemoved names the child and its interface')

    print(f'FAILURES {failures}', flush=True)
    bus.disconnect()
    return failures


if __name__ == '__main__':
    sys.exit(asyncio.run(main()))
