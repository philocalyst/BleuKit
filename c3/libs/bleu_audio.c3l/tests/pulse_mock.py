#!/usr/bin/env python3
"""Mock PulseAudio native-protocol server for the bleu_audio integration test.

Speaks enough of protocol version 35 to exercise the Linux backend: AUTH with a
cookie check, SET_CLIENT_NAME, GET_SERVER_INFO, the sink, source, sink-input,
source-output and card list queries, SUBSCRIBE with server-pushed events, and
the setters (volume, mute, default, stream move, port, card profile).

Encoding follows the upstream server (pulsecore/protocol-native.c and
tagstruct.c, master branch; see the field comments below). It is written
independently of the C3 codec so that the two can disagree.

Control socket (<socket>.ctl), one line per command, used by the C3 test:
  add-sink NAME     create a sink and send a NEW sink event
  remove-sink NAME  remove a sink and send a REMOVE sink event
  exit              close every client and stop the server

Usage: pulse_mock.py SOCKET COOKIE_FILE
"""
import os
import selectors
import socket
import struct
import sys

PROTOCOL_VERSION = 35
TAG_STRING, TAG_STRING_NULL, TAG_U32, TAG_U8 = b"t", b"N", b"L", b"B"
TAG_U64, TAG_SAMPLE_SPEC, TAG_ARBITRARY = b"R", b"a", b"x"
TAG_BOOL_TRUE, TAG_BOOL_FALSE, TAG_USEC = b"1", b"0", b"U"
TAG_CHANNEL_MAP, TAG_CVOLUME, TAG_PROPLIST = b"m", b"v", b"P"
TAG_VOLUME, TAG_FORMAT_INFO, TAG_S64 = b"V", b"f", b"r"

NO_INDEX = 0xFFFFFFFF
VOLUME_NORM = 0x10000
FLAG_HW_VOLUME_CTRL = 0x0001
FLAG_HW_MUTE_CTRL = 0x0010

CMD_ERROR, CMD_REPLY = 0, 2
CMD_AUTH, CMD_SET_CLIENT_NAME = 45, 46
CMD_GET_SERVER_INFO = 58
CMD_GET_SINK_INFO_LIST, CMD_GET_SOURCE_INFO_LIST = 60, 62
CMD_GET_SINK_INPUT_INFO_LIST, CMD_GET_SOURCE_OUTPUT_INFO_LIST = 68, 70
CMD_SUBSCRIBE, CMD_SUBSCRIBE_EVENT = 73, 116
CMD_SET_SINK_VOLUME, CMD_SET_SINK_INPUT_VOLUME, CMD_SET_SOURCE_VOLUME = 75, 76, 77
CMD_SET_SINK_MUTE, CMD_SET_SOURCE_MUTE = 79, 80
CMD_SET_DEFAULT_SINK, CMD_SET_DEFAULT_SOURCE = 86, 87
CMD_MOVE_SINK_INPUT, CMD_MOVE_SOURCE_OUTPUT = 121, 122
CMD_SET_SINK_INPUT_MUTE = 125
CMD_GET_CARD_INFO_LIST, CMD_SET_CARD_PROFILE = 159, 160
CMD_SET_SINK_PORT, CMD_SET_SOURCE_PORT = 171, 172
CMD_SET_SOURCE_OUTPUT_VOLUME, CMD_SET_SOURCE_OUTPUT_MUTE = 175, 176

ERR_ACCESS, ERR_COMMAND, ERR_INVALID, ERR_NOENTITY = 1, 2, 3, 5

MASK_SINK, MASK_SOURCE, MASK_SINK_INPUT, MASK_SOURCE_OUTPUT = 1, 2, 4, 8
MASK_CARD, MASK_SERVER = 0x200, 0x80
EV_NEW, EV_CHANGE, EV_REMOVE = 0x0000, 0x0010, 0x0020
FAC_SINK, FAC_SOURCE, FAC_SINK_INPUT, FAC_SOURCE_OUTPUT = 0, 1, 2, 3
FAC_SERVER, FAC_CARD = 7, 9


# ---- encoders -------------------------------------------------------------

def enc_u32(v):
    return TAG_U32 + struct.pack(">I", v)


def enc_u8(v):
    return TAG_U8 + bytes([v])


def enc_bool(v):
    return TAG_BOOL_TRUE if v else TAG_BOOL_FALSE


def enc_string(s):
    if s is None:
        return TAG_STRING_NULL
    return TAG_STRING + s.encode() + b"\0"


def enc_arbitrary(b):
    return TAG_ARBITRARY + struct.pack(">I", len(b)) + b


def enc_usec(v):
    return TAG_USEC + struct.pack(">Q", v)


def enc_s64(v):
    return TAG_S64 + struct.pack(">q", v)


def enc_sample_spec():
    # format 3 = S16LE, 2 channels, 44100 Hz (pulse/sample.h order: format, channels, rate)
    return TAG_SAMPLE_SPEC + struct.pack(">BBI", 3, 2, 44100)


def enc_channel_map(positions):
    return TAG_CHANNEL_MAP + bytes([len(positions)]) + bytes(positions)


def enc_cvolume(values):
    return TAG_CVOLUME + bytes([len(values)]) + b"".join(struct.pack(">I", v) for v in values)


def enc_volume(v):
    return TAG_VOLUME + struct.pack(">I", v)


def enc_proplist(props):
    out = TAG_PROPLIST
    for key, value in props.items():
        value = value.encode()
        out += enc_string(key) + enc_u32(len(value)) + enc_arbitrary(value)
    return out + TAG_STRING_NULL


def enc_format_info():
    # one format: encoding byte, empty proplist
    return TAG_FORMAT_INFO + enc_u8(0) + enc_proplist({})


# ---- server state ---------------------------------------------------------

class Device:
    """A sink or a source, with the fields the protocol reports."""

    def __init__(self, index, name, description, is_source, props, monitor_of=NO_INDEX):
        self.index = index
        self.name = name
        self.description = description
        self.is_source = is_source
        self.props = props
        self.volume = [VOLUME_NORM, VOLUME_NORM]
        self.muted = False
        self.monitor_of = monitor_of
        self.flags = FLAG_HW_VOLUME_CTRL | FLAG_HW_MUTE_CTRL
        self.card = 0
        self.active_port = "analog-output-speakers"


class Stream:
    """A sink input (playback) or a source output (record)."""

    def __init__(self, index, is_source_output, device_index, props, media_name):
        self.index = index
        self.is_source_output = is_source_output
        self.device_index = device_index
        self.props = props
        self.media_name = media_name
        self.volume = [VOLUME_NORM, VOLUME_NORM]
        self.muted = False
        self.corked = False


class Card:
    def __init__(self, index, name, profiles, active):
        self.index = index
        self.name = name
        self.profiles = profiles  # list of (name, description, available)
        self.active = active


class Server:
    def __init__(self):
        self.default_sink = "alsa_output.test"
        self.default_source = "alsa_input.test"
        self.next_index = 10
        self.sinks = [
            Device(0, "alsa_output.test", "Test Sink", False,
                   {"device.form_factor": "speaker", "device.bus": "pci",
                    "device.description": "Test Sink"}),
        ]
        self.sources = [
            Device(1, "alsa_output.test.monitor", "Monitor of Test Sink", True, {}, monitor_of=0),
            Device(2, "alsa_input.test", "Test Microphone", True,
                   {"device.form_factor": "microphone", "device.bus": "usb"}),
        ]
        self.sink_inputs = [
            Stream(20, False, 0, {"application.name": "Music Player",
                                  "application.id": "org.example.Music",
                                  "application.icon_name": "music",
                                  "application.process.binary": "musicplayer",
                                  "application.process.id": "4321"}, "Track 1"),
        ]
        self.source_outputs = [
            Stream(21, True, 2, {"application.name": "Recorder",
                                 "application.process.id": "77"}, "Voice"),
        ]
        self.cards = [
            Card(0, "alsa_card.test", [("a2dp-sink", "High Fidelity Playback (A2DP Sink)", True),
                                       ("off", "Off", True)], "a2dp-sink"),
        ]
        self.subscribed = 0
        self.clients = []

    def find_sink(self, index, name):
        for d in self.sinks:
            if (index != NO_INDEX and d.index == index) or (index == NO_INDEX and d.name == name):
                return d
        return None

    def find_source(self, index, name):
        for d in self.sources:
            if (index != NO_INDEX and d.index == index) or (index == NO_INDEX and d.name == name):
                return d
        return None

    def sink_name(self, index):
        for d in self.sinks:
            if d.index == index:
                return d.name
        return ""

    def source_name(self, index):
        for d in self.sources:
            if d.index == index:
                return d.name
        return ""

    # Record encoders, in the field order of the upstream fill_tagstruct functions.

    def device_record(self, d, version):
        out = enc_u32(d.index) + enc_string(d.name) + enc_string(d.description)
        out += enc_sample_spec() + enc_channel_map([1, 2])
        out += enc_u32(NO_INDEX) + enc_cvolume(d.volume) + enc_bool(d.muted)
        if d.is_source:
            monitor = d.monitor_of
            out += enc_u32(NO_INDEX if monitor == NO_INDEX else monitor)
            out += enc_string(self.sink_name(monitor) if monitor != NO_INDEX else None)
        else:
            out += enc_u32(NO_INDEX)
            out += enc_string(d.name + ".monitor")
        out += enc_usec(0) + enc_string("alsa") + enc_u32(d.flags)
        if version >= 13:
            out += enc_proplist(d.props) + enc_usec(0)
        if version >= 15:
            out += enc_volume(VOLUME_NORM) + enc_u32(0) + enc_u32(65536) + enc_u32(0)
        if version >= 16:
            out += enc_u32(1)  # one port
            out += enc_string("analog-output-speakers") + enc_string("Speakers") + enc_u32(100)
            if version >= 24:
                out += enc_u32(2)  # PA_PORT_AVAILABLE_YES
                if version >= 34:
                    out += enc_string(None) + enc_u32(0)
            out += enc_string(d.active_port)
        if version >= (22 if d.is_source else 21):
            out += enc_u8(1) + enc_format_info()
        return out

    def stream_record(self, s, version):
        if not s.is_source_output:
            out = enc_u32(s.index) + enc_string(s.media_name) + enc_u32(NO_INDEX) + enc_u32(5)
            out += enc_u32(s.device_index) + enc_sample_spec() + enc_channel_map([1, 2])
            out += enc_cvolume(s.volume) + enc_usec(0) + enc_usec(0)
            out += enc_string("copy") + enc_string("protocol-native")
            if version >= 11:
                out += enc_bool(s.muted)
            if version >= 13:
                out += enc_proplist(s.props)
            if version >= 19:
                out += enc_bool(s.corked)
            if version >= 20:
                out += enc_bool(True) + enc_bool(True)
            if version >= 21:
                out += enc_format_info()
            return out
        out = enc_u32(s.index) + enc_string(s.media_name) + enc_u32(NO_INDEX) + enc_u32(6)
        out += enc_u32(s.device_index) + enc_sample_spec() + enc_channel_map([1, 2])
        out += enc_usec(0) + enc_usec(0) + enc_string("copy") + enc_string("protocol-native")
        if version >= 13:
            out += enc_proplist(s.props)
        if version >= 19:
            out += enc_bool(s.corked)
        if version >= 22:
            out += enc_cvolume(s.volume) + enc_bool(s.muted) + enc_bool(True) + enc_bool(True)
            out += enc_format_info()
        return out

    def card_record(self, c, version):
        out = enc_u32(c.index) + enc_string(c.name) + enc_u32(NO_INDEX) + enc_string("alsa")
        out += enc_u32(len(c.profiles))
        for name, description, available in c.profiles:
            out += enc_string(name) + enc_string(description)
            out += enc_u32(1) + enc_u32(1) + enc_u32(100)
            if version >= 29:
                out += enc_u32(1 if available else 0)
        out += enc_string(c.active) + enc_proplist({"device.description": "Test Card"})
        if version >= 26:
            out += enc_u32(0)  # no ports in the mock
        return out

    def server_info(self, version):
        out = enc_string("pulseaudio") + enc_string("16.1") + enc_string("tester") + enc_string("host")
        out += enc_sample_spec() + enc_string(self.default_sink) + enc_string(self.default_source)
        out += enc_u32(0x12345678)
        if version >= 15:
            out += enc_channel_map([1, 2])
        return out


# ---- connections ----------------------------------------------------------

class Connection:
    def __init__(self, sock):
        self.sock = sock
        self.inbuf = b""
        self.version = PROTOCOL_VERSION
        self.authorized = False
        self.command = None


def frame(payload, channel=0xFFFFFFFF):
    return struct.pack(">IIQI", len(payload), channel, 0, 0) + payload


def reply(tag, body=b""):
    return frame(enc_u32(CMD_REPLY) + enc_u32(tag) + body)


def error(tag, code):
    return frame(enc_u32(CMD_ERROR) + enc_u32(tag) + enc_u32(code))


def event(event_type, facility, index):
    return frame(enc_u32(CMD_SUBSCRIBE_EVENT) + enc_u32(0xFFFFFFFF)
                 + enc_u32(event_type | facility) + enc_u32(index))


class Mock:
    def __init__(self, socket_path, cookie_path):
        self.server = Server()
        self.expected_cookie = open(cookie_path, "rb").read() if cookie_path else None
        self.sel = selectors.DefaultSelector()
        self.listen = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listen.bind(socket_path)
        self.listen.listen(8)
        self.listen.setblocking(False)
        self.sel.register(self.listen, selectors.EVENT_READ, "listen")
        self.ctl_path = socket_path + ".ctl"
        self.ctl = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.ctl.bind(self.ctl_path)
        self.ctl.listen(4)
        self.ctl.setblocking(False)
        self.sel.register(self.ctl, selectors.EVENT_READ, "ctl")
        self.connections = {}
        self.running = True

    def send(self, conn, data):
        try:
            conn.sock.sendall(data)
        except OSError:
            self.drop(conn)

    def drop(self, conn):
        try:
            self.sel.unregister(conn.sock)
        except (KeyError, ValueError):
            pass
        conn.sock.close()
        self.connections.pop(conn.sock, None)

    def broadcast_event(self, event_type, facility, index):
        for conn in list(self.connections.values()):
            if conn.authorized and (self.server.subscribed & (1 << facility)):
                self.send(conn, event(event_type, facility, index))

    def run(self):
        while self.running:
            for key, _ in self.sel.select(timeout=0.5):
                if key.data == "listen":
                    sock, _ = self.listen.accept()
                    sock.setblocking(True)
                    conn = Connection(sock)
                    self.connections[sock] = conn
                    self.sel.register(sock, selectors.EVENT_READ, "client")
                elif key.data == "ctl":
                    sock, _ = self.ctl.accept()
                    self.handle_control(sock)
                    sock.close()
                else:
                    self.read_client(self.connections[key.fileobj])
        self.shutdown()

    def read_client(self, conn):
        try:
            data = conn.sock.recv(65536)
        except OSError:
            data = b""
        if not data:
            self.drop(conn)
            return
        conn.inbuf += data
        while len(conn.inbuf) >= 20:
            length = struct.unpack(">I", conn.inbuf[:4])[0]
            if len(conn.inbuf) < 20 + length:
                break
            payload = conn.inbuf[20:20 + length]
            conn.inbuf = conn.inbuf[20 + length:]
            self.dispatch(conn, payload)

    def handle_control(self, sock):
        line = sock.recv(4096).decode().strip()
        parts = line.split(" ", 1)
        if parts[0] == "add-sink":
            index = self.server.next_index
            self.server.next_index += 1
            self.server.sinks.append(Device(index, parts[1], parts[1], False, {}))
            self.broadcast_event(EV_NEW, FAC_SINK, index)
        elif parts[0] == "remove-sink":
            for d in list(self.server.sinks):
                if d.name == parts[1]:
                    self.server.sinks.remove(d)
                    self.broadcast_event(EV_REMOVE, FAC_SINK, d.index)
        elif parts[0] == "exit":
            self.running = False

    def shutdown(self):
        for conn in list(self.connections.values()):
            self.drop(conn)
        self.listen.close()
        self.ctl.close()
        os.unlink(self.ctl_path)

    # ---- request handling ----

    def dispatch(self, conn, payload):
        # Each word is a tag byte then four bytes: 'L' cmd 'L' tag, then the arguments.
        cmd = struct.unpack(">I", payload[1:5])[0]
        if cmd == CMD_ERROR:
            return
        tag = struct.unpack(">I", payload[6:10])[0]
        args = Reader(payload[10:])
        conn.command = cmd
        handler = self.handlers().get(cmd)
        if handler is None:
            self.send(conn, error(tag, ERR_COMMAND))
            return
        if cmd == CMD_AUTH:
            handler(conn, tag, args)
            return
        if not conn.authorized:
            self.send(conn, error(tag, ERR_ACCESS))
            return
        handler(conn, tag, args)

    def handlers(self):
        return {
            CMD_AUTH: self.h_auth,
            CMD_SET_CLIENT_NAME: self.h_set_client_name,
            CMD_GET_SERVER_INFO: self.h_server_info,
            CMD_GET_SINK_INFO_LIST: self.h_list_sinks,
            CMD_GET_SOURCE_INFO_LIST: self.h_list_sources,
            CMD_GET_SINK_INPUT_INFO_LIST: self.h_list_sink_inputs,
            CMD_GET_SOURCE_OUTPUT_INFO_LIST: self.h_list_source_outputs,
            CMD_GET_CARD_INFO_LIST: self.h_list_cards,
            CMD_SUBSCRIBE: self.h_subscribe,
            CMD_SET_SINK_VOLUME: self.h_set_device_volume,
            CMD_SET_SOURCE_VOLUME: self.h_set_device_volume,
            CMD_SET_SINK_MUTE: self.h_set_device_mute,
            CMD_SET_SOURCE_MUTE: self.h_set_device_mute,
            CMD_SET_SINK_INPUT_VOLUME: self.h_set_stream_volume,
            CMD_SET_SOURCE_OUTPUT_VOLUME: self.h_set_stream_volume,
            CMD_SET_SINK_INPUT_MUTE: self.h_set_stream_mute,
            CMD_SET_SOURCE_OUTPUT_MUTE: self.h_set_stream_mute,
            CMD_SET_DEFAULT_SINK: self.h_set_default_sink,
            CMD_SET_DEFAULT_SOURCE: self.h_set_default_source,
            CMD_MOVE_SINK_INPUT: self.h_move_sink_input,
            CMD_SET_SINK_PORT: self.h_set_port,
            CMD_SET_CARD_PROFILE: self.h_set_card_profile,
        }

    def h_auth(self, conn, tag, args):
        args.u32()
        cookie = args.arbitrary()
        if self.expected_cookie is not None and cookie != self.expected_cookie:
            self.send(conn, error(tag, ERR_ACCESS))
            return
        conn.authorized = True
        self.send(conn, reply(tag, enc_u32(PROTOCOL_VERSION)))

    def h_set_client_name(self, conn, tag, args):
        args.proplist()
        self.send(conn, reply(tag, enc_u32(1)))

    def h_server_info(self, conn, tag, args):
        self.send(conn, reply(tag, self.server.server_info(conn.version)))

    def h_list_sinks(self, conn, tag, args):
        body = b"".join(self.server.device_record(d, conn.version) for d in self.server.sinks)
        self.send(conn, reply(tag, body))

    def h_list_sources(self, conn, tag, args):
        body = b"".join(self.server.device_record(d, conn.version) for d in self.server.sources)
        self.send(conn, reply(tag, body))

    def h_list_sink_inputs(self, conn, tag, args):
        body = b"".join(self.server.stream_record(s, conn.version) for s in self.server.sink_inputs)
        self.send(conn, reply(tag, body))

    def h_list_source_outputs(self, conn, tag, args):
        body = b"".join(self.server.stream_record(s, conn.version) for s in self.server.source_outputs)
        self.send(conn, reply(tag, body))

    def h_list_cards(self, conn, tag, args):
        body = b"".join(self.server.card_record(c, conn.version) for c in self.server.cards)
        self.send(conn, reply(tag, body))

    def h_subscribe(self, conn, tag, args):
        self.server.subscribed = args.u32()
        self.send(conn, reply(tag))

    def h_set_device_volume(self, conn, tag, args):
        is_source = self.last_command_is_source(conn)
        index = args.u32()
        name = args.nullable_string()
        values = args.cvolume()
        device = self.find_device(is_source, index, name)
        if device is None:
            self.send(conn, error(tag, ERR_NOENTITY))
            return
        device.volume = values
        self.send(conn, reply(tag))
        self.broadcast_event(EV_CHANGE, FAC_SOURCE if is_source else FAC_SINK, device.index)

    def h_set_device_mute(self, conn, tag, args):
        is_source = self.last_command_is_source(conn)
        index = args.u32()
        name = args.nullable_string()
        muted = args.boolean()
        device = self.find_device(is_source, index, name)
        if device is None:
            self.send(conn, error(tag, ERR_NOENTITY))
            return
        device.muted = muted
        self.send(conn, reply(tag))
        self.broadcast_event(EV_CHANGE, FAC_SOURCE if is_source else FAC_SINK, device.index)

    def h_set_stream_volume(self, conn, tag, args):
        is_source_output = self.last_command_is_source(conn)
        index = args.u32()
        values = args.cvolume()
        stream = self.find_stream(is_source_output, index)
        if stream is None:
            self.send(conn, error(tag, ERR_NOENTITY))
            return
        stream.volume = values
        self.send(conn, reply(tag))
        self.broadcast_event(EV_CHANGE, FAC_SOURCE_OUTPUT if is_source_output else FAC_SINK_INPUT, stream.index)

    def h_set_stream_mute(self, conn, tag, args):
        is_source_output = self.last_command_is_source(conn)
        index = args.u32()
        muted = args.boolean()
        stream = self.find_stream(is_source_output, index)
        if stream is None:
            self.send(conn, error(tag, ERR_NOENTITY))
            return
        stream.muted = muted
        self.send(conn, reply(tag))
        self.broadcast_event(EV_CHANGE, FAC_SOURCE_OUTPUT if is_source_output else FAC_SINK_INPUT, stream.index)

    def h_set_default_sink(self, conn, tag, args):
        name = args.string()
        self.server.default_sink = name
        self.send(conn, reply(tag))
        self.broadcast_event(EV_CHANGE, FAC_SERVER, 0)

    def h_set_default_source(self, conn, tag, args):
        name = args.string()
        self.server.default_source = name
        self.send(conn, reply(tag))
        self.broadcast_event(EV_CHANGE, FAC_SERVER, 0)

    def h_move_sink_input(self, conn, tag, args):
        index = args.u32()
        device_index = args.u32()
        device_name = args.nullable_string()
        stream = self.find_stream(False, index)
        sink = self.server.find_sink(device_index, device_name) if device_index != NO_INDEX or device_name else None
        if stream is None or sink is None:
            self.send(conn, error(tag, ERR_NOENTITY))
            return
        stream.device_index = sink.index
        self.send(conn, reply(tag))
        self.broadcast_event(EV_CHANGE, FAC_SINK_INPUT, stream.index)

    def h_set_port(self, conn, tag, args):
        index = args.u32()
        name = args.nullable_string()
        port = args.string()
        device = self.server.find_sink(index, name)
        if device is None:
            self.send(conn, error(tag, ERR_NOENTITY))
            return
        device.active_port = port
        self.send(conn, reply(tag))
        self.broadcast_event(EV_CHANGE, FAC_SINK, device.index)

    def h_set_card_profile(self, conn, tag, args):
        index = args.u32()
        name = args.nullable_string()
        profile = args.string()
        card = None
        for c in self.server.cards:
            if (index != NO_INDEX and c.index == index) or (index == NO_INDEX and c.name == name):
                card = c
        if card is None or profile not in [p[0] for p in card.profiles]:
            self.send(conn, error(tag, ERR_NOENTITY))
            return
        card.active = profile
        self.send(conn, reply(tag))
        self.broadcast_event(EV_CHANGE, FAC_CARD, card.index)

    # Which list a setter addresses is given by its command number; recorded per dispatch.
    def last_command_is_source(self, conn):
        return conn.command in (CMD_SET_SOURCE_VOLUME, CMD_SET_SOURCE_MUTE, CMD_SET_SOURCE_OUTPUT_VOLUME,
                                CMD_SET_SOURCE_OUTPUT_MUTE)

    def find_device(self, is_source, index, name):
        if is_source:
            return self.server.find_source(index, name)
        return self.server.find_sink(index, name)

    def find_stream(self, is_source_output, index):
        streams = self.server.source_outputs if is_source_output else self.server.sink_inputs
        for s in streams:
            if s.index == index:
                return s
        return None


class Reader:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def take(self, n):
        out = self.data[self.pos:self.pos + n]
        self.pos += n
        return out

    def u32(self):
        assert self.take(1) == TAG_U32
        return struct.unpack(">I", self.take(4))[0]

    def boolean(self):
        tag = self.take(1)
        return tag == TAG_BOOL_TRUE

    def string(self):
        assert self.take(1) == TAG_STRING
        end = self.data.index(b"\0", self.pos)
        s = self.data[self.pos:end].decode()
        self.pos = end + 1
        return s

    def nullable_string(self):
        if self.data[self.pos:self.pos + 1] == TAG_STRING_NULL:
            self.pos += 1
            return None
        return self.string()

    def arbitrary(self):
        assert self.take(1) == TAG_ARBITRARY
        n = struct.unpack(">I", self.take(4))[0]
        return self.take(n)

    def cvolume(self):
        assert self.take(1) == TAG_CVOLUME
        n = self.take(1)[0]
        return [struct.unpack(">I", self.take(4))[0] for _ in range(n)]

    def proplist(self):
        assert self.take(1) == TAG_PROPLIST
        props = {}
        while self.data[self.pos:self.pos + 1] != TAG_STRING_NULL:
            key = self.string()
            assert self.take(1) == TAG_U32
            length = struct.unpack(">I", self.take(4))[0]
            value = self.arbitrary()
            assert len(value) == length, "proplist length mismatch"
            props[key] = value.decode()
        self.pos += 1
        return props


def main():
    socket_path, cookie_path = sys.argv[1], sys.argv[2]
    if os.path.exists(socket_path):
        os.unlink(socket_path)
    mock = Mock(socket_path, cookie_path)
    print("ready", flush=True)
    mock.run()


if __name__ == "__main__":
    main()
