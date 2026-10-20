#!/usr/bin/env python3
"""Mock systemd-logind and power-profiles-daemon for tests/run.sh (python-dbus-next).

Owns, on the bus it is started against:

* org.freedesktop.login1 at /org/freedesktop/login1, interface
  org.freedesktop.login1.Manager: properties LidClosed, OnExternalPower,
  IdleHint; Can* answers (configurable through the control object); the
  action methods Suspend, Hibernate, HybridSleep, PowerOff, Reboot; Inhibit,
  which returns the read-end-watched write end of a pipe as a unix fd;
  GetSessionByPID; the signal PrepareForSleep.
* org.freedesktop.login1.Session at /org/freedesktop/login1/session/_1 with
  Lock and Terminate (recorded, nothing is locked or ended).
* power-profiles-daemon, modern interface (org.freedesktop.UPower.PowerProfiles)
  or legacy (net.hadess.PowerProfiles), chosen by the argument `modern`,
  `legacy` or `none`. Modern adds HoldProfile and ReleaseProfile.
* org.bleu.Mock.Control at /org/bleu/Control on the login1 name: SetLidClosed,
  SetExternalPower, SetDegraded, SetCan, EmitPrepareForSleep, Calls (JSON list
  of every recorded call), Locks (JSON list of inhibitors and whether their
  descriptor has reached end-of-file, i.e. the client closed it).

Destructive actions are recorded and answered, never performed. Hibernate is
refused with org.freedesktop.PolicyKit1.Error.NotAuthorized, the way polkit
refuses an action this user may not take; nothing tries to get around it.
Prints READY when every name it owns is up.
"""
import asyncio
import json
import os
import select
import sys

from dbus_next import BusType, DBusError, Message, MessageType, PropertyAccess, Variant
from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, dbus_property, method, signal

LOGIND = 'org.freedesktop.login1'
MANAGER_PATH = '/org/freedesktop/login1'
SESSION_PATH = '/org/freedesktop/login1/session/_1'
CONTROL_PATH = '/org/bleu/Control'
MODERN_PATH = '/org/freedesktop/UPower/PowerProfiles'
MODERN_NAME = 'org.freedesktop.UPower.PowerProfiles'
LEGACY_PATH = '/net/hadess/PowerProfiles'
LEGACY_NAME = 'net.hadess.PowerProfiles'

CALLS = []
LOCKS = []  # dicts: id, what, mode, who, why, read_fd (our end), closed
STATE = {
    'lid': False,
    'external': True,
    'idle': False,
    'profile': 'balanced',
    'degraded': '',
    'can': {
        'CanSuspend': 'yes',
        'CanHibernate': 'challenge',
        'CanHybridSleep': 'na',
        'CanPowerOff': 'yes',
        'CanReboot': 'inhibited',
    },
    'holds': {},
    'next_cookie': 1,
    'next_lock': 1,
}
PROFILE_NAMES = ['power-saver', 'balanced', 'performance']
BUS = None


def record(text):
    CALLS.append(text)


def profiles_value():
    return [{'Profile': Variant('s', name), 'Driver': Variant('s', 'mock')} for name in PROFILE_NAMES]


class Manager(ServiceInterface):
    def __init__(self):
        super().__init__('org.freedesktop.login1.Manager')

    @dbus_property(access=PropertyAccess.READ)
    def LidClosed(self) -> 'b':
        return STATE['lid']

    @dbus_property(access=PropertyAccess.READ)
    def OnExternalPower(self) -> 'b':
        return STATE['external']

    @dbus_property(access=PropertyAccess.READ)
    def IdleHint(self) -> 'b':
        return STATE['idle']

    @method()
    def CanSuspend(self) -> 's':
        return STATE['can']['CanSuspend']

    @method()
    def CanHibernate(self) -> 's':
        return STATE['can']['CanHibernate']

    @method()
    def CanHybridSleep(self) -> 's':
        return STATE['can']['CanHybridSleep']

    @method()
    def CanPowerOff(self) -> 's':
        return STATE['can']['CanPowerOff']

    @method()
    def CanReboot(self) -> 's':
        return STATE['can']['CanReboot']

    @method()
    def Suspend(self, interactive: 'b'):
        record(f'Suspend({str(interactive).lower()})')

    @method()
    def Hibernate(self, interactive: 'b'):
        record(f'Hibernate({str(interactive).lower()})')
        raise DBusError('org.freedesktop.PolicyKit1.Error.NotAuthorized', 'denied by the mock policy')

    @method()
    def HybridSleep(self, interactive: 'b'):
        record(f'HybridSleep({str(interactive).lower()})')

    @method()
    def PowerOff(self, interactive: 'b'):
        record(f'PowerOff({str(interactive).lower()})')

    @method()
    def Reboot(self, interactive: 'b'):
        record(f'Reboot({str(interactive).lower()})')

    @method()
    def GetSessionByPID(self, pid: 'u') -> 'o':
        record(f'GetSessionByPID({pid})')
        return SESSION_PATH

    @signal()
    def PrepareForSleep(self, start: 'b') -> 'b':
        return start


class Session(ServiceInterface):
    def __init__(self):
        super().__init__('org.freedesktop.login1.Session')

    @method()
    def Lock(self):
        record('Session.Lock()')

    @method()
    def Terminate(self):
        record('Session.Terminate()')


class Control(ServiceInterface):
    def __init__(self):
        super().__init__('org.bleu.Mock.Control')

    @method()
    def SetLidClosed(self, value: 'b'):
        STATE['lid'] = value
        MANAGER.emit_properties_changed({'LidClosed': value})

    @method()
    def SetExternalPower(self, value: 'b'):
        STATE['external'] = value
        MANAGER.emit_properties_changed({'OnExternalPower': value})

    @method()
    def SetDegraded(self, value: 's'):
        STATE['degraded'] = value
        if PPD_MODERN is not None:
            PPD_MODERN.emit_properties_changed({'PerformanceDegraded': value})

    @method()
    def SetCan(self, name: 's', answer: 's'):
        STATE['can'][name] = answer

    @method()
    def EmitPrepareForSleep(self, start: 'b'):
        MANAGER.PrepareForSleep(start)

    @method()
    def Calls(self) -> 's':
        return json.dumps(CALLS)

    @method()
    def Locks(self) -> 's':
        out = []
        for lock in LOCKS:
            out.append({'id': lock['id'], 'what': lock['what'], 'mode': lock['mode'],
                        'closed': lock_closed(lock)})
        return json.dumps(out)


def lock_closed(lock):
    """True once the client has closed every copy of the descriptor it was sent."""
    if lock['closed']:
        return True
    readable, _, _ = select.select([lock['read_fd']], [], [], 0)
    if readable and os.read(lock['read_fd'], 1) == b'':
        lock['closed'] = True
    return lock['closed']


class PpdBase(ServiceInterface):
    def __init__(self, name):
        super().__init__(name)

    @dbus_property(access=PropertyAccess.READWRITE)
    def ActiveProfile(self) -> 's':
        return STATE['profile']

    @ActiveProfile.setter
    def set_active(self, value: 's'):
        if value not in PROFILE_NAMES:
            raise DBusError('org.freedesktop.DBus.Error.InvalidArgs', 'unknown profile')
        record(f'SetActiveProfile({value})')
        STATE['profile'] = value
        self.emit_properties_changed({'ActiveProfile': value})

    @dbus_property(access=PropertyAccess.READ)
    def Profiles(self) -> 'aa{sv}':
        return profiles_value()

    @dbus_property(access=PropertyAccess.READ)
    def PerformanceDegraded(self) -> 's':
        return STATE['degraded']


class ModernPpd(PpdBase):
    def __init__(self):
        super().__init__('org.freedesktop.UPower.PowerProfiles')

    @method()
    def HoldProfile(self, profile: 's', reason: 's', application_id: 's') -> 'u':
        if profile not in ('power-saver', 'performance'):
            raise DBusError('org.freedesktop.DBus.Error.InvalidArgs', 'only power-saver and performance')
        cookie = STATE['next_cookie']
        STATE['next_cookie'] += 1
        STATE['holds'][cookie] = profile
        record(f'HoldProfile({profile},{reason},{application_id})')
        return cookie

    @method()
    def ReleaseProfile(self, cookie: 'u'):
        if cookie not in STATE['holds']:
            raise DBusError('org.freedesktop.DBus.Error.InvalidArgs', 'unknown cookie')
        del STATE['holds'][cookie]
        record(f'ReleaseProfile({cookie})')


class LegacyPpd(PpdBase):
    def __init__(self):
        super().__init__('net.hadess.PowerProfiles')


def handle_inhibit(bus, message):
    """Inhibit(what, who, why, mode) -> h: the reply carries the write end of a pipe."""
    if message.message_type != MessageType.METHOD_CALL or message.member != 'Inhibit':
        return None
    if message.path != MANAGER_PATH or message.interface != 'org.freedesktop.login1.Manager':
        return None
    what, who, why, mode = message.body
    read_fd, write_fd = os.pipe()
    lock_id = STATE['next_lock']
    STATE['next_lock'] += 1
    LOCKS.append({'id': lock_id, 'what': what, 'mode': mode, 'who': who, 'why': why,
                  'read_fd': read_fd, 'closed': False})
    record(f'Inhibit({what},{mode})')
    asyncio.get_running_loop().call_later(0.5, os.close, write_fd)
    return Message.new_method_return(message, 'h', [0], unix_fds=[write_fd])


async def main():
    global BUS, MANAGER, PPD_MODERN
    which = sys.argv[1] if len(sys.argv) > 1 else 'modern'
    BUS = await MessageBus(bus_type=BusType.SYSTEM, negotiate_unix_fd=True).connect()
    MANAGER = Manager()
    BUS.export(MANAGER_PATH, MANAGER)
    BUS.export(SESSION_PATH, Session())
    BUS.export(CONTROL_PATH, Control())
    BUS.add_message_handler(lambda msg: handle_inhibit(BUS, msg))
    await BUS.request_name(LOGIND)
    PPD_MODERN = None
    if which == 'modern':
        PPD_MODERN = ModernPpd()
        BUS.export(MODERN_PATH, PPD_MODERN)
        await BUS.request_name(MODERN_NAME)
    elif which == 'legacy':
        ppd = LegacyPpd()
        BUS.export(LEGACY_PATH, ppd)
        await BUS.request_name(LEGACY_NAME)
    print('READY', flush=True)
    await asyncio.get_running_loop().create_future()


if __name__ == '__main__':
    asyncio.run(main())
