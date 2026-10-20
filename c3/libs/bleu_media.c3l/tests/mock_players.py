"""Fake MPRIS players for the bleu_media live test.

Run by tests/run.sh on a private session bus:

    python3 -I mock_players.py <bus-address>

Three players, each on its own bus connection so that "vanish" is a real
disconnect of the owner:

  fake_a  Playing, track /org/fake/track/1, art as file://, two artists
  fake_b  Paused, track /org/fake/track/7, art as https://, CanGoNext false
  fake_c  Paused, no track id ("/"), vanishes when the test says so

Each player answers the MPRIS 2.2 Player and root interfaces. It keeps a
position anchor and extrapolates the position from the monotonic clock, as a
real player does; the position is never signalled. It records every command it
receives, and it ignores a SetPosition whose TrackId is not the current track,
as the spec requires. A control interface on org.bleu.MediaTest lets the C3
test change state, emit Seeked, and make a player vanish. The control
interface prints READY on stdout when every name is owned.
"""
import asyncio
import sys
import time

from dbus_next import PropertyAccess, Variant
from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, dbus_property, method, signal

OBJECT_PATH = "/org/mpris/MediaPlayer2"
PREFIX = "org.mpris.MediaPlayer2."
TRACK_LENGTH_US = 180_000_000
CONTROL_NAME = "org.bleu.MediaTest"
CONTROL_PATH = "/org/bleu/MediaTest"


class Fake:
    """The state of one fake player, shared by its interfaces."""

    def __init__(self, short, identity, status, position_us, trackid, title, artists, art, can_next):
        self.short = short
        self.identity = identity
        self.desktop_entry = "fake-" + short
        self.status = status
        self.rate = 1.0
        self.volume = 1.0
        self.shuffle = False
        self.loop = "None"
        self.trackid = trackid
        self.title = title
        self.artists = artists
        self.art = art
        self.can_next = can_next
        self.anchor_us = position_us
        self.anchor_t = time.monotonic()
        self.calls = []
        self.bus = None
        self.interfaces = None

    def now_us(self):
        return int(self.anchor_us + (time.monotonic() - self.anchor_t) * 1_000_000 * self.rate)

    def position(self):
        if self.status != "Playing":
            return self.anchor_us
        return max(0, min(TRACK_LENGTH_US, self.now_us()))

    def re_anchor(self, position_us):
        self.anchor_us = position_us
        self.anchor_t = time.monotonic()

    def metadata(self):
        meta = {"mpris:trackid": Variant("o", self.trackid), "mpris:length": Variant("x", TRACK_LENGTH_US)}
        if self.title:
            meta["xesam:title"] = Variant("s", self.title)
        if self.artists:
            meta["xesam:artist"] = Variant("as", self.artists)
        if self.art:
            meta["mpris:artUrl"] = Variant("s", self.art)
        return meta


class Root(ServiceInterface):
    def __init__(self, fake):
        super().__init__("org.mpris.MediaPlayer2")
        self.fake = fake

    @dbus_property(access=PropertyAccess.READ)
    def Identity(self) -> "s":
        return self.fake.identity

    @dbus_property(access=PropertyAccess.READ)
    def DesktopEntry(self) -> "s":
        return self.fake.desktop_entry

    @dbus_property(access=PropertyAccess.READ)
    def CanQuit(self) -> "b":
        return True

    @dbus_property(access=PropertyAccess.READ)
    def CanRaise(self) -> "b":
        return True

    @dbus_property(access=PropertyAccess.READ)
    def HasTrackList(self) -> "b":
        return False

    @dbus_property(access=PropertyAccess.READ)
    def SupportedUriSchemes(self) -> "as":
        return []

    @dbus_property(access=PropertyAccess.READ)
    def SupportedMimeTypes(self) -> "as":
        return []

    @method()
    def Raise(self):
        self.fake.calls.append("Raise")

    @method()
    def Quit(self):
        self.fake.calls.append("Quit")


class Player(ServiceInterface):
    def __init__(self, fake):
        super().__init__("org.mpris.MediaPlayer2.Player")
        self.fake = fake

    def changed(self, **props):
        self.emit_properties_changed(props)

    @dbus_property(access=PropertyAccess.READ)
    def PlaybackStatus(self) -> "s":
        return self.fake.status

    @dbus_property(access=PropertyAccess.READWRITE)
    def LoopStatus(self) -> "s":
        return self.fake.loop

    @LoopStatus.setter
    def LoopStatus(self, value: "s"):
        self.fake.calls.append("LoopStatus " + value)
        self.fake.loop = value
        self.changed(LoopStatus=value)

    @dbus_property(access=PropertyAccess.READWRITE)
    def Rate(self) -> "d":
        return self.fake.rate

    @Rate.setter
    def Rate(self, value: "d"):
        self.fake.calls.append("Rate %g" % value)
        self.fake.re_anchor(self.fake.position())
        self.fake.rate = value
        self.changed(Rate=value)

    @dbus_property(access=PropertyAccess.READWRITE)
    def Shuffle(self) -> "b":
        return self.fake.shuffle

    @Shuffle.setter
    def Shuffle(self, value: "b"):
        self.fake.calls.append("Shuffle %s" % value)
        self.fake.shuffle = value
        self.changed(Shuffle=value)

    @dbus_property(access=PropertyAccess.READWRITE)
    def Volume(self) -> "d":
        return self.fake.volume

    @Volume.setter
    def Volume(self, value: "d"):
        self.fake.calls.append("Volume %g" % value)
        self.fake.volume = value
        self.changed(Volume=value)

    @dbus_property(access=PropertyAccess.READ)
    def Metadata(self) -> "a{sv}":
        return self.fake.metadata()

    @dbus_property(access=PropertyAccess.READ)
    def Position(self) -> "x":
        # Deliberately not signalled, as the spec says.
        return self.fake.position()

    @dbus_property(access=PropertyAccess.READ)
    def MinimumRate(self) -> "d":
        return 0.25

    @dbus_property(access=PropertyAccess.READ)
    def MaximumRate(self) -> "d":
        return 4.0

    @dbus_property(access=PropertyAccess.READ)
    def CanGoNext(self) -> "b":
        return self.fake.can_next

    @dbus_property(access=PropertyAccess.READ)
    def CanGoPrevious(self) -> "b":
        return True

    @dbus_property(access=PropertyAccess.READ)
    def CanPlay(self) -> "b":
        return True

    @dbus_property(access=PropertyAccess.READ)
    def CanPause(self) -> "b":
        return True

    @dbus_property(access=PropertyAccess.READ)
    def CanSeek(self) -> "b":
        return True

    @dbus_property(access=PropertyAccess.READ)
    def CanControl(self) -> "b":
        return True

    def set_status(self, status):
        self.fake.re_anchor(self.fake.position())
        self.fake.status = status
        self.changed(PlaybackStatus=status)

    @method()
    def Play(self):
        self.fake.calls.append("Play")
        if self.fake.status != "Playing":
            self.set_status("Playing")

    @method()
    def Pause(self):
        self.fake.calls.append("Pause")
        if self.fake.status == "Playing":
            self.set_status("Paused")

    @method()
    def PlayPause(self):
        self.fake.calls.append("PlayPause")
        self.set_status("Paused" if self.fake.status == "Playing" else "Playing")

    @method()
    def Stop(self):
        self.fake.calls.append("Stop")
        self.set_status("Stopped")

    @method()
    def Next(self):
        self.fake.calls.append("Next")

    @method()
    def Previous(self):
        self.fake.calls.append("Previous")

    @method()
    def Seek(self, offset: "x"):
        self.fake.calls.append("Seek %d" % offset)
        self.fake.re_anchor(self.fake.position() + offset)
        self.seeked()

    @method()
    def SetPosition(self, track_id: "o", position: "x"):
        if track_id != self.fake.trackid:
            # The spec: a TrackId that is not the current track is ignored.
            self.fake.calls.append("IGNORED SetPosition %s" % track_id)
            return
        self.fake.calls.append("SetPosition %s %d" % (track_id, position))
        self.fake.re_anchor(position)
        self.seeked()

    def seeked(self):
        self.Seeked(self.fake.position())

    @signal()
    def Seeked(self, position: "x") -> "x":
        return position


class Control(ServiceInterface):
    def __init__(self, fakes):
        super().__init__(CONTROL_NAME)
        self.fakes = fakes

    def get(self, name):
        for fake in self.fakes.values():
            if fake.bus is not None and PREFIX + "fake_" + fake.short == name:
                return fake
        raise ValueError("no player " + name)

    @method()
    def Status(self, name: "s", status: "s"):
        fake = self.get(name)
        fake.interfaces[1].set_status(status)

    @method()
    def Track(self, name: "s", trackid: "o", title: "s"):
        fake = self.get(name)
        fake.trackid = trackid
        fake.title = title
        fake.re_anchor(0)
        fake.interfaces[1].changed(Metadata=fake.metadata(), Position=0)

    @method()
    def Jump(self, name: "s", position: "x"):
        """Move the player without a status change, and send Seeked."""
        fake = self.get(name)
        fake.re_anchor(position)
        fake.interfaces[1].seeked()

    @method()
    def Vanish(self, name: "s"):
        fake = self.get(name)
        fake.bus.disconnect()
        fake.bus = None

    @method()
    def Calls(self, name: "s") -> "s":
        return ";".join(self.get(name).calls)


PLAYERS = [
    Fake("a", "Fake Alpha", "Playing", 10_000_000, "/org/fake/track/1", "Alpha",
         ["Ann", "Bo"], "file:///tmp/fake-alpha.png", True),
    Fake("b", "Fake Beta", "Paused", 42_000_000, "/org/fake/track/7", "Bravo",
         [], "https://example.invalid/bravo.jpg", False),
    Fake("c", "Fake Charlie", "Paused", 20_000_000, "/", "", [], "", True),
]


async def main(address):
    fakes = {}
    for fake in PLAYERS:
        bus = await MessageBus(bus_address=address).connect()
        fake.bus = bus
        root, player = Root(fake), Player(fake)
        bus.export(OBJECT_PATH, root)
        bus.export(OBJECT_PATH, player)
        fake.interfaces = (root, player)
        await bus.request_name(PREFIX + "fake_" + fake.short)
        fakes[fake.short] = fake
    control_bus = await MessageBus(bus_address=address).connect()
    control = Control(fakes)
    control_bus.export(CONTROL_PATH, control)
    await control_bus.request_name(CONTROL_NAME)
    print("READY", flush=True)
    await asyncio.get_running_loop().create_future()


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1]))
