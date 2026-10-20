#!/usr/bin/env python3
"""Raw-socket checks of the DMS IPC protocol, with no client library.

Run by protocol_driver.c3 against an in-process server (api version 38, the
capabilities ["network", "bluetooth"], max line 4096 bytes, topics "live" and
"snap", with "snap" holding {"n":1}). Methods: echo, publish, caps, plus the
built-ins ping and subscribe. Every expected line below is the exact byte
sequence the server writes (see docs/research/bleu_ipc.md).

Exit status 0 when every check passes, 1 otherwise.
"""
import json
import socket
import sys
import time

TIMEOUT = 5.0
PATH = sys.argv[1] if len(sys.argv) > 1 else ""


class Peer:
    """One raw connection: writes bytes as given, reads newline-terminated lines."""

    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(TIMEOUT)
        self.sock.connect(path)
        self.buffer = b""

    def send(self, data):
        self.sock.sendall(data)

    def line(self):
        while b"\n" not in self.buffer:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise EOFError("connection closed by server")
            self.buffer += chunk
        line, _, self.buffer = self.buffer.partition(b"\n")
        return line

    def is_closed_by_server(self):
        """True once the server has closed the connection (end of stream or reset)."""
        deadline = time.time() + TIMEOUT
        while time.time() < deadline:
            try:
                chunk = self.sock.recv(65536)
            except (ConnectionResetError, BrokenPipeError):
                return True
            if not chunk:
                return True
        return False

    def close(self):
        self.sock.close()


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def expect(peer, want):
    got = peer.line()
    check(got == want, "expected %r, got %r" % (want, got))


def handshake(peer):
    line = peer.line()
    value = json.loads(line)
    check(set(value) == {"apiVersion", "capabilities"}, "handshake keys: %r" % value)
    check(value["apiVersion"] == 38, "apiVersion: %r" % value)
    check(value["capabilities"] == ["network", "bluetooth"], "capabilities: %r" % value)
    check(b'"id"' not in line, "handshake must carry no id")


def check_handshake_and_ping():
    peer = Peer(PATH)
    handshake(peer)
    peer.send(b'{"id":1,"method":"ping"}\n')
    expect(peer, b'{"id":1,"result":{"pong":true}}')
    peer.close()


def check_errors_keep_the_connection_usable():
    peer = Peer(PATH)
    handshake(peer)
    peer.send(b'{"id":2,"method":"nope"}\n')
    expect(peer, b'{"id":2,"error":"unknown method: nope"}')
    peer.send(b"this is not json\n")
    expect(peer, b'{"error":"invalid json: malformed JSON"}')
    peer.send(b"\n")
    expect(peer, b'{"error":"invalid json: malformed JSON"}')
    peer.send(b'{"id":3,"method":"\xff"}\n')
    expect(peer, b'{"error":"invalid json: input is not UTF-8"}')
    peer.send(b'{"id":4,"method":"ping"}\n')
    expect(peer, b'{"id":4,"result":{"pong":true}}')
    peer.close()


def check_ids_up_to_two_to_the_53():
    peer = Peer(PATH)
    handshake(peer)
    peer.send(b'{"id":9007199254740992,"method":"ping"}\n')
    expect(peer, b'{"id":9007199254740992,"result":{"pong":true}}')
    peer.send(b'{"id":9007199254740993,"method":"ping"}\n')
    expect(peer, b'{"id":9007199254740993,"result":{"pong":true}}')
    peer.close()


def check_partial_lines_and_pipelining_and_crlf():
    peer = Peer(PATH)
    handshake(peer)
    peer.send(b'{"id":8,"me')
    time.sleep(0.05)
    peer.send(b'thod":"ping"}\n')
    expect(peer, b'{"id":8,"result":{"pong":true}}')
    peer.send(b'{"id":9,"method":"a"}\n{"id":10,"method":"b"}\n{"id":11,"method":"c"}\n')
    expect(peer, b'{"id":9,"error":"unknown method: a"}')
    expect(peer, b'{"id":10,"error":"unknown method: b"}')
    expect(peer, b'{"id":11,"error":"unknown method: c"}')
    peer.send(b'{"id":12,"method":"ping"}\r\n')
    expect(peer, b'{"id":12,"result":{"pong":true}}')
    peer.close()


def check_unsubscribe_is_unknown_as_in_dms():
    peer = Peer(PATH)
    handshake(peer)
    peer.send(b'{"id":13,"method":"unsubscribe","params":{}}\n')
    expect(peer, b'{"id":13,"error":"unknown method: unsubscribe"}')
    peer.close()


def check_a_line_over_the_limit_closes_the_connection():
    peer = Peer(PATH)
    handshake(peer)
    peer.send(b"x" * 5000)
    check(peer.is_closed_by_server(), "server kept a connection with an over-long line")
    peer.close()


def check_subscription_order_and_fan_out():
    # S subscribes to snap then live: the server frame, then the snapshot of snap.
    sub = Peer(PATH)
    handshake(sub)
    sub.send(b'{"id":42,"method":"subscribe","params":{"services":["snap","live"],"clientId":"t"}}\n')
    expect(sub, b'{"id":42,"result":{"service":"server","data":{"apiVersion":38,"capabilities":["network","bluetooth"]}}}')
    expect(sub, b'{"id":42,"result":{"service":"snap","data":{"n":1}}}')

    # Q subscribes to live only: the server frame and no snapshot (live has none).
    other = Peer(PATH)
    handshake(other)
    other.send(b'{"id":5,"method":"subscribe","params":{"services":["live"]}}\n')
    expect(other, b'{"id":5,"result":{"service":"server","data":{"apiVersion":38,"capabilities":["network","bluetooth"]}}}')

    # A third connection publishes through a method; both subscribers see the value.
    caller = Peer(PATH)
    handshake(caller)
    caller.send(b'{"id":13,"method":"publish","params":{"value":"hi"}}\n')
    expect(caller, b'{"id":13,"result":{"published":true}}')
    expect(sub, b'{"id":42,"result":{"service":"live","data":{"value":"hi"}}}')
    expect(other, b'{"id":5,"result":{"service":"live","data":{"value":"hi"}}}')

    # A capability change reaches every subscription with its own id.
    caller.send(b'{"id":14,"method":"caps","params":{}}\n')
    expect(caller, b'{"id":14,"result":{"notified":true}}')
    expect(sub, b'{"id":42,"result":{"service":"server","data":{"apiVersion":38,"capabilities":["network","bluetooth"]}}}')
    expect(other, b'{"id":5,"result":{"service":"server","data":{"apiVersion":38,"capabilities":["network","bluetooth"]}}}')

    for peer in (sub, other, caller):
        peer.close()


def check_params_must_be_an_object():
    peer = Peer(PATH)
    handshake(peer)
    peer.send(b'{"id":15,"method":"echo","params":[1]}\n')
    expect(peer, b'{"error":"invalid json: params must be an object"}')
    peer.send(b'{"id":16,"method":"echo","params":null}\n')
    expect(peer, b'{"id":16,"result":{"ok":true}}')
    peer.close()


CHECKS = [
    check_handshake_and_ping,
    check_errors_keep_the_connection_usable,
    check_ids_up_to_two_to_the_53,
    check_partial_lines_and_pipelining_and_crlf,
    check_unsubscribe_is_unknown_as_in_dms,
    check_params_must_be_an_object,
    check_a_line_over_the_limit_closes_the_connection,
    check_subscription_order_and_fan_out,
]


def main():
    failures = 0
    for check_fn in CHECKS:
        try:
            check_fn()
            print("PASS %s" % check_fn.__name__)
        except (AssertionError, EOFError, OSError, ValueError) as error:
            failures += 1
            print("FAIL %s: %s" % (check_fn.__name__, error))
    print("%d of %d raw protocol checks passed" % (len(CHECKS) - failures, len(CHECKS)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
