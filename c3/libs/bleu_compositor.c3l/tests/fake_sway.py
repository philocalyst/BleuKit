"""Fake sway (or i3 with the `i3` argument): the i3-ipc binary protocol on one socket.

A frame is the magic "i3-ipc", a native-order u32 payload length, a native-order
u32 type, then the payload (i3 docs/ipc). Events have bit 31 set in the type.

Usage: fake_sway.py SOCKET FIXTURE_DIR LOG EVENTS_FILE [i3]
EVENTS_FILE holds one event per line: NAME<TAB>JSON, NAME as in i3-ipc ("window").
"""
import struct
import sys

from fake_common import fixture, log, pause, serve

MAGIC = b"i3-ipc"
EVENT_BIT = 0x80000000
EVENT_TYPES = {"workspace": 0, "output": 1, "window": 3, "input": 21}
REPLIES = {
    1: "workspaces.json",
    3: "outputs.json",
    4: "tree.json",
    100: "inputs.json",
}
SUBSCRIBE = 2
RUN_COMMAND = 0


def frame(message_type, payload):
    return MAGIC + struct.pack("=II", len(payload), message_type) + payload


def read_exact(conn, count):
    data = b""
    while len(data) < count:
        chunk = conn.recv(count - len(data))
        if not chunk:
            return None
        data += chunk
    return data


def read_frame(conn):
    header = read_exact(conn, 14)
    if header is None:
        return None
    length, message_type = struct.unpack("=II", header[6:14])
    payload = read_exact(conn, length) or b""
    return message_type, payload


def main():
    socket_path, fixture_dir, log_path, events_path = sys.argv[1:5]
    i3 = len(sys.argv) > 5 and sys.argv[5] == "i3"

    def handle(conn):
        while True:
            request = read_frame(conn)
            if request is None:
                return
            message_type, payload = request
            if message_type == SUBSCRIBE:
                conn.sendall(frame(SUBSCRIBE, b'{"success": true}'))
                pause(0.3)
                with open(events_path, "r", encoding="utf-8") as handle_file:
                    for line in handle_file:
                        name, _, body = line.rstrip("\n").partition("\t")
                        if i3 and name == "input":
                            continue
                        conn.sendall(frame(EVENT_BIT | EVENT_TYPES[name], body.encode("utf-8")))
                continue
            if message_type in REPLIES:
                conn.sendall(frame(message_type, fixture(fixture_dir, REPLIES[message_type])))
            elif message_type == RUN_COMMAND:
                command = payload.decode("utf-8")
                log(log_path, command)
                conn.sendall(frame(RUN_COMMAND, b'[{"success": true}]'))
            else:
                conn.sendall(frame(message_type, b'{"success": false}'))

    serve(socket_path, handle)
    print("ready", flush=True)
    pause(3600)


if __name__ == "__main__":
    main()
