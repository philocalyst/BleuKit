"""A client that behaves as DankMaterialShell's QML client (Services/DMSService.qml) does.

* Two connections, as the shell has: one for requests, one for subscriptions.
* The handshake is the first line of each connection and has no id.
* Request ids are `Date.now() + counter` (DMSService.qml:386-387): big numbers, and
  distinct across requests.
* Replies are matched by id; a reply with an error carries the text in `error`.
* Frames on a subscription carry the subscribe request's id and `result.service`,
  and the shell dispatches on that service name (DMSService.qml:256-361). Lines without
  `result` are ignored, as the shell ignores them.
Only the standard library is used.
"""
import json
import socket
import time


class Connection:
    """One socket: newline-delimited JSON in both directions."""

    def __init__(self, path, timeout=10.0):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.reader = self.sock.makefile('rb')
        self.handshake = json.loads(self.reader.readline().decode())

    def send(self, obj):
        self.sock.sendall((json.dumps(obj) + "\n").encode())

    def read(self):
        """The next line as a parsed object; key order is the order on the wire."""
        line = self.reader.readline()
        if not line:
            raise EOFError("connection closed by dmsd")
        return json.loads(line.decode())

    def close(self):
        self.reader.close()
        self.sock.close()


class DmsClient:
    """Requests on one connection; subscriptions on another, as the shell does."""

    def __init__(self, path, timeout=10.0):
        self.path = path
        self.timeout = timeout
        self.requests = Connection(path, timeout)
        self.counter = 0
        self.subscriptions = None
        self.subscribe_id = None

    def next_id(self):
        self.counter += 1
        return int(time.time() * 1000) + self.counter

    def request(self, method, params=None):
        """Send a request and return its reply object (with `result` or `error`)."""
        req_id = self.next_id()
        obj = {"id": req_id, "method": method}
        if params is not None:
            obj["params"] = params
        self.requests.send(obj)
        while True:
            reply = self.requests.read()
            if reply.get("id") == req_id:
                return reply

    def subscribe(self, services, client_id="qml-test"):
        """Open the subscription connection and send the one `subscribe` request for `services`."""
        if self.subscriptions is None:
            self.subscriptions = Connection(self.path, self.timeout)
        self.subscribe_id = self.next_id()
        self.subscriptions.send({"id": self.subscribe_id, "method": "subscribe",
                                 "params": {"services": services, "clientId": client_id}})
        return self.subscribe_id

    def next_frame(self):
        """The next subscription frame as (service, data); lines without a result are skipped."""
        while True:
            obj = self.subscriptions.read()
            if "result" not in obj:
                continue
            result = obj["result"]
            return result.get("service"), result.get("data"), obj.get("id")

    def close(self):
        self.requests.close()
        if self.subscriptions is not None:
            self.subscriptions.close()
