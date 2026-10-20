"""Fake niri: JSON lines on one socket (niri-ipc 26.4.0 `socket.rs`).

One request line in, one reply line out; `EventStream` turns the connection into
an event feed. Usage: fake_niri.py SOCKET FIXTURE_DIR LOG EVENTS_FILE
"""
import sys

from fake_common import fixture, log, pause, serve

QUERIES = {
    '"Workspaces"': "workspaces_reply.json",
    '"Windows"': "windows_reply.json",
    '"Outputs"': "outputs_reply.json",
    '"KeyboardLayouts"': "layouts_reply.json",
}


def main():
    socket_path, fixture_dir, log_path, events_path = sys.argv[1:5]

    def handle(conn):
        buffered = b""
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                return
            buffered += chunk
            while b"\n" in buffered:
                line, buffered = buffered.split(b"\n", 1)
                request = line.decode("utf-8")
                if request == '"EventStream"':
                    conn.sendall(b'{"Ok":"Handled"}\n')
                    pause(0.3)
                    with open(events_path, "rb") as events:
                        for event in events.read().splitlines():
                            conn.sendall(event + b"\n")
                    conn.recv(1)
                    return
                if request in QUERIES:
                    conn.sendall(fixture(fixture_dir, QUERIES[request]).replace(b"\n", b" ") + b"\n")
                    continue
                log(log_path, request)
                if '"id":99' in request:
                    conn.sendall(b'{"Err":"window 99 not found"}\n')
                else:
                    conn.sendall(b'{"Ok":"Handled"}\n')

    serve(socket_path, handle)
    print("ready", flush=True)
    pause(3600)


if __name__ == "__main__":
    main()
