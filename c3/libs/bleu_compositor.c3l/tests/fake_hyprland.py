"""Fake Hyprland: `.socket.sock` answers `j/...` queries and dispatchers, and
`.socket2.sock` pushes `EVENT>>DATA` lines (wiki.hypr.land/IPC).

Usage: fake_hyprland.py INSTANCE_DIR FIXTURE_DIR LOG EVENTS_FILE [bad]
"""
import os
import sys

from fake_common import fixture, log, pause, serve

QUERIES = {
    "j/clients": "clients.json",
    "j/activewindow": "activewindow.json",
    "j/workspaces": "workspaces.json",
    "j/monitors": "monitors.json",
    "j/devices": "devices.json",
}


def main():
    instance_dir, fixture_dir, log_path, events_path = sys.argv[1:5]
    bad_event = len(sys.argv) > 5 and sys.argv[5] == "bad"
    os.makedirs(instance_dir, exist_ok=True)

    def command(conn):
        # The client writes its request and waits for the reply; one recv gets it all.
        request = conn.recv(65536).decode("utf-8")
        if request in QUERIES:
            conn.sendall(fixture(fixture_dir, QUERIES[request]))
            return
        log(log_path, request)
        if request.startswith("j/dispatch ") or request.startswith("switchxkblayout "):
            conn.sendall(b"ok")
            return
        conn.sendall(b"unknown request")

    def events(conn):
        pause(0.3)
        with open(events_path, "rb") as handle:
            for line in handle.read().splitlines():
                conn.sendall(line + b"\n")
        if bad_event:
            conn.sendall(b"this line has no separator\n")
        # Keep the stream open until the client goes away.
        conn.recv(1)

    serve(os.path.join(instance_dir, ".socket.sock"), command)
    serve(os.path.join(instance_dir, ".socket2.sock"), events)
    print("ready", flush=True)
    pause(3600)


if __name__ == "__main__":
    main()
