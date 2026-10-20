#!/usr/bin/env python3
"""Record the replies a real PulseAudio server sends, for the golden tests.

Usage: capture_fixtures.py SOCKET OUTDIR

Sends the handshake and each list query with the request encoders of
pulse_mock.py (which the real server accepts) and writes each reply payload
(command word, tag word, then the arguments) to OUTDIR/<name>.bin. The
server's own bytes are the golden input of pulse_test.c3 and
pulse_records_test.c3, so the decoders are checked against a real server,
not against this repository's encoder.
"""
import os
import socket
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pulse_mock as pm  # noqa: E402

QUERIES = [
    ("server_info", pm.CMD_GET_SERVER_INFO, None),
    ("sinks", pm.CMD_GET_SINK_INFO_LIST, None),
    ("sources", pm.CMD_GET_SOURCE_INFO_LIST, None),
    ("sink_inputs", pm.CMD_GET_SINK_INPUT_INFO_LIST, None),
    ("source_outputs", pm.CMD_GET_SOURCE_OUTPUT_INFO_LIST, None),
    ("cards", pm.CMD_GET_CARD_INFO_LIST, None),
]


def read_packet(sock):
    header = recv_exact(sock, 20)
    length = struct.unpack(">I", header[:4])[0]
    return recv_exact(sock, length)


def recv_exact(sock, n):
    out = b""
    while len(out) < n:
        chunk = sock.recv(n - len(out))
        if not chunk:
            raise SystemExit("server closed the connection")
        out += chunk
    return out


def main():
    socket_path, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(socket_path)
    tag = 0

    def request(command, body=b""):
        nonlocal tag
        tag += 1
        sock.sendall(pm.frame(pm.enc_u32(command) + pm.enc_u32(tag) + body))
        while True:
            payload = read_packet(sock)
            cmd = struct.unpack(">I", payload[1:5])[0]
            if cmd == pm.CMD_SUBSCRIBE_EVENT:
                continue
            return payload

    request(pm.CMD_AUTH, pm.enc_u32(pm.PROTOCOL_VERSION) + pm.enc_arbitrary(bytes(pm.COOKIE_LENGTH)))
    request(pm.CMD_SET_CLIENT_NAME, pm.enc_proplist({"application.name": "fixture-capture"}))
    for name, command, body in QUERIES:
        payload = request(command, body or b"")
        with open(os.path.join(outdir, name + ".bin"), "wb") as f:
            f.write(payload)
        print(name, len(payload))


if __name__ == "__main__":
    main()
