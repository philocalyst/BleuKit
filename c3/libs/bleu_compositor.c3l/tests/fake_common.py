"""Shared helpers for the fake compositors: a Unix socket server per IPC, a
request log, and fixture loading. Used only by the live tests (run_live.sh).

Each fake answers the requests the C3 client sends, from the same golden
fixtures the unit tests embed, and pushes scripted events. It never touches
anything but its own socket, its log and the fixture directory.
"""
import os
import socket
import threading
import time


def serve(path, handler):
    """Listen on `path` (removing a stale socket) and run handler(conn) per connection."""
    if os.path.exists(path):
        os.unlink(path)
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(path)
    listener.listen(8)

    def accept_loop():
        while True:
            conn, _ = listener.accept()
            threading.Thread(target=run_connection, args=(conn, handler), daemon=True).start()

    threading.Thread(target=accept_loop, daemon=True).start()


def run_connection(conn, handler):
    try:
        handler(conn)
    except (BrokenPipeError, ConnectionResetError):
        pass
    finally:
        conn.close()


def log(path, line):
    """Append one line to the request log the test script checks."""
    with open(path, "a", encoding="utf-8") as out:
        out.write(line + "\n")


def fixture(directory, name):
    with open(os.path.join(directory, name), "rb") as handle:
        return handle.read()


def pause(seconds):
    time.sleep(seconds)
