#!/usr/bin/env python3
"""Mock systemd-logind (org.freedesktop.login1) for the bleu_session live tests.

It owns org.freedesktop.login1 on the bus named by DBUS_SYSTEM_BUS_ADDRESS and exports:

* /org/freedesktop/login1 (org.freedesktop.login1.Manager): GetSessionByPID(u) -> o,
  GetSession(s) -> o, ListSessions() -> a(susso), ListSeats() -> a(so), LockSession(s),
  UnlockSession(s), TerminateSession(s), Suspend(b) and the signals PrepareForSleep(b),
  SessionNew(so), SessionRemoved(so);
* /org/freedesktop/login1/session/_32 (this process's session, "32", wayland, seat0,
  active) and /org/freedesktop/login1/session/_c1 (a remote tty session with no seat):
  org.freedesktop.login1.Session with the properties bleu_session reads, and the Lock and
  Unlock signals.

The mock stands in for the session locker as well: LockSession and UnlockSession set
LockedHint and emit PropertiesChanged, as a locker's SetLockedHint would. Suspend emits
PrepareForSleep(true), waits 200 ms, and emits PrepareForSleep(false), as logind does
around a real suspend.

Every session method call is appended to the file named by BLEU_LOGIND_LOG, one
"Method argument" line each, before it is checked, so the test script can see the refused
calls too.

BLEU_LOGIND_LATE_SESSION_SECONDS (optional): this process is in no session at first. The first
GetSessionByPID is refused with NoSessionForPID; that many seconds later the mock announces
SessionNew for session 32, and from then on answers the lookup.

Prints READY on stdout once the name is owned. Needs python-dbus-next (0.2.x).
"""
import asyncio
import os

from dbus_next import BusType, DBusError
from dbus_next.aio import MessageBus
from dbus_next.constants import PropertyAccess
from dbus_next.service import ServiceInterface, dbus_property, method, signal

NAME = 'org.freedesktop.login1'
MANAGER_PATH = '/org/freedesktop/login1'
MANAGER_IFACE = 'org.freedesktop.login1.Manager'
SESSION_IFACE = 'org.freedesktop.login1.Session'
LOG = os.environ.get('BLEU_LOGIND_LOG', '')
SUSPEND_GAP_SECONDS = 0.2
LATE_SESSION_SECONDS = float(os.environ.get('BLEU_LOGIND_LATE_SESSION_SECONDS', '0') or 0)
# The late session: scheduled at the first refused lookup, announced once, then visible.
late_state = {'scheduled': False, 'announced': False}
MANAGER = None

SESSIONS = {
    '32': {
        'path': MANAGER_PATH + '/session/_32', 'uid': 1000, 'user': 'alice', 'seat': 'seat0',
        'Id': '32', 'User': [1000, '/org/freedesktop/login1/user/_1000'], 'Name': 'alice',
        'Seat': ['seat0', '/org/freedesktop/login1/seat/seat0'], 'Type': 'wayland', 'Class': 'user',
        'Active': True, 'Remote': False, 'LockedHint': False, 'IdleHint': False,
    },
    'c1': {
        'path': MANAGER_PATH + '/session/_c1', 'uid': 1001, 'user': 'bob', 'seat': '',
        'Id': 'c1', 'User': [1001, '/org/freedesktop/login1/user/_1001'], 'Name': 'bob',
        'Seat': ['', '/'], 'Type': 'tty', 'Class': 'user',
        'Active': False, 'Remote': True, 'LockedHint': False, 'IdleHint': False,
    },
}


def log(line):
    if LOG:
        with open(LOG, 'a') as f:
            f.write(line + '\n')


class Session(ServiceInterface):
    """One session object. Its properties are read from SESSIONS; LockedHint changes emit PropertiesChanged."""

    def __init__(self, key):
        super().__init__(SESSION_IFACE)
        self.key = key

    def value(self, name):
        return SESSIONS[self.key][name]

    @dbus_property(access=PropertyAccess.READ)
    def Id(self) -> 's':
        return self.value('Id')

    @dbus_property(access=PropertyAccess.READ)
    def User(self) -> '(uo)':
        return self.value('User')

    @dbus_property(access=PropertyAccess.READ)
    def Name(self) -> 's':
        return self.value('Name')

    @dbus_property(access=PropertyAccess.READ)
    def Seat(self) -> '(so)':
        return self.value('Seat')

    @dbus_property(access=PropertyAccess.READ)
    def Type(self) -> 's':
        return self.value('Type')

    @dbus_property(access=PropertyAccess.READ)
    def Class(self) -> 's':
        return self.value('Class')

    @dbus_property(access=PropertyAccess.READ)
    def Active(self) -> 'b':
        return self.value('Active')

    @dbus_property(access=PropertyAccess.READ)
    def Remote(self) -> 'b':
        return self.value('Remote')

    @dbus_property(access=PropertyAccess.READ)
    def LockedHint(self) -> 'b':
        return self.value('LockedHint')

    @dbus_property(access=PropertyAccess.READ)
    def IdleHint(self) -> 'b':
        return self.value('IdleHint')

    @signal()
    def Lock(self):
        return None

    @signal()
    def Unlock(self):
        return None

    def set_locked(self, locked):
        SESSIONS[self.key]['LockedHint'] = locked
        self.emit_properties_changed({'LockedHint': locked})
        if locked:
            self.Lock()
        else:
            self.Unlock()


class Manager(ServiceInterface):
    def __init__(self, sessions):
        super().__init__(MANAGER_IFACE)
        self.sessions = sessions

    def key_of(self, session_id):
        if session_id not in SESSIONS:
            raise DBusError('org.freedesktop.login1.NoSuchSession', 'No session \'%s\' known' % session_id)
        return session_id

    @method()
    def GetSessionByPID(self, pid: 'u') -> 'o':
        # The test process is session 32; any other pid is treated the same way.
        if LATE_SESSION_SECONDS > 0 and not late_state['announced']:
            if not late_state['scheduled']:
                late_state['scheduled'] = True
                asyncio.get_running_loop().call_later(LATE_SESSION_SECONDS, announce_late_session)
            raise DBusError('org.freedesktop.login1.NoSessionForPID', 'No session for PID %d' % pid)
        return SESSIONS['32']['path']

    @method()
    def GetSession(self, session_id: 's') -> 'o':
        return SESSIONS[self.key_of(session_id)]['path']

    @method()
    def ListSessions(self) -> 'a(susso)':
        return [
            [key, SESSIONS[key]['uid'], SESSIONS[key]['user'], SESSIONS[key]['seat'], SESSIONS[key]['path']]
            for key in ('32', 'c1')
        ]

    @method()
    def ListSeats(self) -> 'a(so)':
        return [['seat0', '/org/freedesktop/login1/seat/seat0']]

    @method()
    def LockSession(self, session_id: 's'):
        log('LockSession %s' % session_id)
        self.sessions[self.key_of(session_id)].set_locked(True)

    @method()
    def UnlockSession(self, session_id: 's'):
        log('UnlockSession %s' % session_id)
        self.sessions[self.key_of(session_id)].set_locked(False)

    @method()
    def TerminateSession(self, session_id: 's'):
        log('TerminateSession %s' % session_id)
        self.key_of(session_id)

    @method()
    async def Suspend(self, interactive: 'b'):
        log('Suspend %s' % ('true' if interactive else 'false'))
        self.PrepareForSleep(True)
        asyncio.get_running_loop().call_later(SUSPEND_GAP_SECONDS, lambda: self.PrepareForSleep(False))

    @signal()
    def PrepareForSleep(self, start: 'b') -> 'b':
        return start

    @signal()
    def SessionNew(self, session_id: 's', path: 'o') -> 'so':
        return [session_id, path]

    @signal()
    def SessionRemoved(self, session_id: 's', path: 'o') -> 'so':
        return [session_id, path]


def announce_late_session():
    late_state['announced'] = True
    MANAGER.SessionNew('32', SESSIONS['32']['path'])


async def main():
    global MANAGER
    bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
    sessions = {key: Session(key) for key in SESSIONS}
    manager = Manager(sessions)
    MANAGER = manager
    bus.export(MANAGER_PATH, manager)
    for key, obj in sessions.items():
        bus.export(SESSIONS[key]['path'], obj)
    await bus.request_name(NAME)
    print('READY', flush=True)
    await bus.wait_for_disconnect()


if __name__ == '__main__':
    asyncio.run(main())
