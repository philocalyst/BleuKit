#!/usr/bin/env python3
"""A stand-in for systemd-logind (org.freedesktop.login1) for the dmsd tests.

It owns org.freedesktop.login1 on the bus named by DBUS_SYSTEM_BUS_ADDRESS (the
test script starts a private dbus-daemon) and provides what bleu_session and
bleu_power call at start-up and during the tests:

* Manager: GetSessionByPID, GetSession, ListSessions, ListSeats, LockSession,
  UnlockSession, TerminateSession, Suspend, CanSuspend ... CanHybridSleep,
  Inhibit (returns the write end of a pipe as a unix fd, like logind's inhibitor
  lock), and the PrepareForSleep signal.
* Session /org/freedesktop/login1/session/_32 (this process's session: wayland,
  seat0, active): properties read by bleu_session, and Lock, Unlock, Terminate.

Suspend emits PrepareForSleep(true), then waits until every delay inhibitor is
released (its pipe reaches end-of-file, which is what closing the descriptor does),
or until five seconds pass, then emits PrepareForSleep(false). That is the real
logind contract the dmsd sleep barrier relies on, so a missing acknowledgement
shows up as a long suspend in the test.

Every call that changes state is appended to $DMSD_MOCK_LOG as one line, so the
test can check the order: "Lock", "Unlock", "Terminate <id>", "Inhibit <what> <mode>",
"Suspend", "PrepareForSleep true", "PrepareForSleep false", "Released <n>".
Prints READY on stdout once the name is owned.
"""
import asyncio
import os
import sys

from dbus_next import BusType, Message, Variant
from dbus_next.aio import MessageBus
from dbus_next.constants import MessageType, PropertyAccess
from dbus_next.service import ServiceInterface, dbus_property, method, signal

LOGIND = 'org.freedesktop.login1'
MANAGER_PATH = '/org/freedesktop/login1'
SESSION_PATH = '/org/freedesktop/login1/session/_32'
SESSION_ID = '32'
MANAGER_IFACE = 'org.freedesktop.login1.Manager'
SESSION_IFACE = 'org.freedesktop.login1.Session'
LOG = os.environ.get('DMSD_MOCK_LOG', '')
SLEEP_WAIT_SECONDS = 5.0

BUS = None
LOCKS = []           # delay inhibitors: {'read_fd': int, 'what': str, 'mode': str}
STATE = {'locked': False, 'next_lock': 1}


def record(line):
    if LOG:
        with open(LOG, 'a') as f:
            f.write(line + '\n')


def released_count():
    """Inhibitors whose write end has been closed by every holder (the pipe reads end-of-file)."""
    count = 0
    for lock in LOCKS:
        if lock.get('done'):
            count += 1
            continue
        try:
            if os.read(lock['read_fd'], 1) == b'':
                lock['done'] = True
                count += 1
        except BlockingIOError:
            pass
    return count


class Session(ServiceInterface):
    """The session this process runs in. LockedHint follows Lock and Unlock."""

    def __init__(self):
        super().__init__(SESSION_IFACE)

    @dbus_property(access=PropertyAccess.READ)
    def Id(self) -> 's':
        return SESSION_ID

    @dbus_property(access=PropertyAccess.READ)
    def User(self) -> '(uo)':
        return [1000, '/org/freedesktop/login1/user/_1000']

    @dbus_property(access=PropertyAccess.READ)
    def Name(self) -> 's':
        return 'alice'

    @dbus_property(access=PropertyAccess.READ)
    def Seat(self) -> '(so)':
        return ['seat0', '/org/freedesktop/login1/seat/seat0']

    @dbus_property(access=PropertyAccess.READ)
    def Type(self) -> 's':
        return 'wayland'

    @dbus_property(access=PropertyAccess.READ)
    def Class(self) -> 's':
        return 'user'

    @dbus_property(access=PropertyAccess.READ)
    def Active(self) -> 'b':
        return True

    @dbus_property(access=PropertyAccess.READ)
    def Remote(self) -> 'b':
        return False

    @dbus_property(access=PropertyAccess.READ)
    def LockedHint(self) -> 'b':
        return STATE['locked']

    @dbus_property(access=PropertyAccess.READ)
    def IdleHint(self) -> 'b':
        return False

    @dbus_property(access=PropertyAccess.READ)
    def IdleSinceHint(self) -> 't':
        return 0

    def set_locked(self, locked):
        STATE['locked'] = locked
        self.emit_properties_changed({'LockedHint': Variant('b', locked)})

    @method()
    def Lock(self):
        record('Lock')
        self.set_locked(True)

    @method()
    def Unlock(self):
        record('Unlock')
        self.set_locked(False)

    @method()
    def Terminate(self):
        record(f'Terminate {SESSION_ID}')


class Manager(ServiceInterface):
    """The login manager: sessions, locks, suspend and the sleep barrier."""

    def __init__(self):
        super().__init__(MANAGER_IFACE)

    @method()
    def GetSessionByPID(self, pid: 'u') -> 'o':
        return SESSION_PATH

    @method()
    def GetSession(self, session_id: 's') -> 'o':
        if session_id != SESSION_ID:
            raise_error('org.freedesktop.login1.NoSuchSession', session_id)
        return SESSION_PATH

    @method()
    def ListSessions(self) -> 'a(susso)':
        return [[SESSION_ID, 1000, 'alice', 'seat0', SESSION_PATH]]

    @method()
    def ListSeats(self) -> 'a(so)':
        return [['seat0', '/org/freedesktop/login1/seat/seat0']]

    @method()
    def LockSession(self, session_id: 's'):
        record('LockSession ' + session_id)
        SESSION.set_locked(True)

    @method()
    def UnlockSession(self, session_id: 's'):
        record('UnlockSession ' + session_id)
        SESSION.set_locked(False)

    @method()
    def TerminateSession(self, session_id: 's'):
        record('TerminateSession ' + session_id)

    @method()
    def CanSuspend(self) -> 's':
        return 'yes'

    @method()
    def CanHibernate(self) -> 's':
        return 'na'

    @method()
    def CanHybridSleep(self) -> 's':
        return 'na'

    @method()
    def CanPowerOff(self) -> 's':
        return 'yes'

    @method()
    def CanReboot(self) -> 's':
        return 'yes'

    @method()
    async def Suspend(self, interactive: 'b'):
        record('Suspend')
        self.PrepareForSleep(True)
        loop = asyncio.get_running_loop()
        deadline = loop.time() + SLEEP_WAIT_SECONDS
        while loop.time() < deadline:
            if released_count() == len(LOCKS):
                break
            await asyncio.sleep(0.05)
        record(f'Released {released_count()}')
        self.PrepareForSleep(False)

    @signal()
    def PrepareForSleep(self, start: 'b') -> 'b':
        record(f'PrepareForSleep {str(start).lower()}')
        return start


def raise_error(name, text):
    from dbus_next import DBusError
    raise DBusError(name, text)


def handle_inhibit(message):
    """Inhibit(what, who, why, mode) -> h: the reply carries the write end of a pipe."""
    if message.message_type != MessageType.METHOD_CALL or message.member != 'Inhibit':
        return None
    if message.path != MANAGER_PATH or message.interface != MANAGER_IFACE:
        return None
    what, who, why, mode = message.body
    read_fd, write_fd = os.pipe()
    os.set_blocking(read_fd, False)
    LOCKS.append({'id': STATE['next_lock'], 'what': what, 'mode': mode, 'who': who,
                  'read_fd': read_fd, 'done': False})
    STATE['next_lock'] += 1
    record(f'Inhibit {what} {mode}')
    # logind keeps its own copy of the write end; the caller's copy is what releases the lock.
    asyncio.get_running_loop().call_later(0.5, os.close, write_fd)
    return Message.new_method_return(message, 'h', [0], unix_fds=[write_fd])


SESSION = Session()
MANAGER = Manager()


async def main():
    global BUS
    BUS = await MessageBus(bus_type=BusType.SYSTEM, negotiate_unix_fd=True).connect()
    BUS.export(MANAGER_PATH, MANAGER)
    BUS.export(SESSION_PATH, SESSION)
    BUS.add_message_handler(handle_inhibit)
    await BUS.request_name(LOGIND)
    print('READY', flush=True)
    await asyncio.get_running_loop().create_future()


if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
