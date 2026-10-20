#!/usr/bin/env python3
"""A fake Wayland compositor for dmsd's tests: wlr-output-management and wlr-gamma-control.

    fake_wayland.py <socket path> <scenario.json> <log file>

It speaks the Wayland wire format (object ids, opcodes, 32-bit words, fds over SCM_RIGHTS)
for the globals bleu_display and bleu_color bind: a `zwlr_output_manager_v1` with one head per
output, a `zwlr_gamma_control_manager_v1`, and one `wl_output` per output. The opcodes and
argument lists come from the protocol XML in protocols/ (wlr-output-management-unstable-v1.xml,
wlr-gamma-control-unstable-v1.xml; both from gitlab.freedesktop.org/wlroots/wlr-protocols), and the
core ones below from wayland.xml (wayland/wayland, protocol/wayland.xml): wl_display (sync 0,
get_registry 1; delete_id 1), wl_registry (bind 0; global 0, global_remove 1), wl_callback
(done 0), wl_output (release 0; geometry 0, mode 1, done 2, scale 3, name 4, description 5).

The scenario is a JSON file: the outputs (names, modes, positions, whether the output takes a gamma
ramp) and `reject_transform`, a transform value a configuration is refused for (so tests can see a
compositor refusal). The log file gets one line per request that matters to the tests:
configuration calls, gamma controls and the ramps they write. A ramp is written as the three
16-bit tables read from the fd the client sends; the line gives the first and last entries.

Single-threaded select loop. Runs until SIGTERM or SIGINT.
"""
import array
import json
import os
import select
import signal
import socket
import struct
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
PROTO_FILES = ["wlr-output-management-unstable-v1.xml", "wlr-gamma-control-unstable-v1.xml"]

# Core opcodes (wayland.xml). Requests: (name, args). Events: name -> (opcode, args).
CORE_REQUESTS = {
    "wl_display": {0: ("sync", [("callback", "new_id")]), 1: ("get_registry", [("registry", "new_id")])},
    "wl_output": {0: ("release", [])},
    "wl_callback": {},
    "wl_registry": {0: ("bind", [("name", "uint"), ("interface", "string"), ("version", "uint"), ("id", "new_id")])},
}
CORE_EVENTS = {
    "wl_display": {"delete_id": (1, [("id", "uint")])},
    "wl_registry": {
        "global": (0, [("name", "uint"), ("interface", "string"), ("version", "uint")]),
    },
    "wl_callback": {"done": (0, [("callback_data", "uint")])},
    "wl_output": {
        "geometry": (0, [("x", "int"), ("y", "int"), ("physical_width", "int"), ("physical_height", "int"),
                         ("subpixel", "int"), ("make", "string"), ("model", "string"), ("transform", "int")]),
        "mode": (1, [("flags", "uint"), ("width", "int"), ("height", "int"), ("refresh", "int")]),
        "done": (2, []),
        "scale": (3, [("factor", "int")]),
        "name": (4, [("name", "string")]),
        "description": (5, [("description", "string")]),
    },
}

WL_OUTPUT_CURRENT = 1
WL_OUTPUT_PREFERRED = 2
GAMMA_SIZE = 256
SERVER_ID_BASE = 0xFF000000


def load_protocols():
    """The request and event tables of the wlr interfaces, by interface name."""
    requests, events = {}, {}
    for name in PROTO_FILES:
        root = ET.parse(os.path.join(HERE, "protocols", name)).getroot()
        for iface in root.findall("interface"):
            iname = iface.get("name")
            requests[iname] = {}
            events[iname] = {}
            for kind, table in (("request", requests), ("event", events)):
                for opcode, msg in enumerate(iface.findall(kind)):
                    args = [(a.get("name"), a.get("type")) for a in msg.findall("arg")]
                    table[iname][opcode if kind == "request" else msg.get("name")] = (
                        msg.get("name") if kind == "request" else opcode, args)
    return requests, events


REQUESTS, EVENTS = load_protocols()


def request_spec(iface, opcode):
    if iface in CORE_REQUESTS:
        return CORE_REQUESTS[iface].get(opcode)
    entry = REQUESTS.get(iface, {}).get(opcode)
    return entry


def event_spec(iface, name):
    if iface in CORE_EVENTS and name in CORE_EVENTS[iface]:
        return CORE_EVENTS[iface][name]
    return EVENTS.get(iface, {}).get(name)


def pad(data):
    return data + b"\0" * ((4 - len(data) % 4) % 4)


def encode(obj_id, opcode, args, values):
    """One message: the header and the body; fd arguments are returned separately."""
    body = b""
    fds = []
    for (name, typ), value in zip(args, values):
        if typ == "int":
            body += struct.pack("<i", value)
        elif typ in ("uint", "new_id", "object"):
            body += struct.pack("<I", value)
        elif typ == "fixed":
            body += struct.pack("<i", int(round(value * 256)))
        elif typ == "string":
            raw = value.encode() + b"\0"
            body += struct.pack("<I", len(raw)) + pad(raw)
        elif typ == "array":
            body += struct.pack("<I", len(value)) + pad(value)
        elif typ == "fd":
            fds.append(value)
    header = struct.pack("<II", obj_id, ((len(body) + 8) << 16) | opcode)
    return header + body, fds


class Client:
    """One connection: its byte buffer, its objects, and the fds that arrived with them."""

    def __init__(self, sock):
        self.sock = sock
        self.buf = bytearray()
        self.fds = []
        self.objects = {1: ("wl_display", None)}
        self.next_server_id = SERVER_ID_BASE
        self.manager = None  # zwlr_output_manager_v1 object id
        self.heads = {}  # head object id -> output index
        self.modes = {}  # mode object id -> (output index, mode index)
        self.mode_ids = {}  # (output index, mode index) -> mode object id
        self.configs = {}  # configuration object id -> {"serial": n, "changes": {output index: dict}, "heads": {head id: out}}
        self.config_heads = {}  # configuration head object id -> (configuration id, output index)
        self.gamma_controls = {}  # gamma control object id -> output index

    def server_id(self):
        self.next_server_id += 1
        return self.next_server_id

    def send(self, obj_id, iface_event, values):
        """Send the event `iface_event` (a (iface, name) pair) of object `obj_id`."""
        iface, name = iface_event
        opcode, args = event_spec(iface, name)
        data, fds = encode(obj_id, opcode, args, values)
        self.sock.sendall(data)


class Compositor:
    def __init__(self, scenario, log_path):
        self.scenario = scenario
        self.outputs = []
        for index, spec in enumerate(scenario["outputs"]):
            modes = [dict(m) for m in spec["modes"]]
            current = spec.get("current")
            self.outputs.append({
                "name": spec["name"],
                "description": spec.get("description", spec["name"]),
                "make": spec.get("make", "Fake"),
                "model": spec.get("model", "Display"),
                "serial": spec.get("serial", "0000"),
                "width_mm": spec.get("width_mm", 0),
                "height_mm": spec.get("height_mm", 0),
                "x": spec.get("x", 0),
                "y": spec.get("y", 0),
                "transform": spec.get("transform", 0),
                "scale": spec.get("scale", 1.0),
                "enabled": spec.get("enabled", True),
                "current": modes.index(current) if current in modes else None,
                "modes": modes,
                "gamma": spec.get("gamma", True),
            })
        self.serial = 1
        self.log = open(log_path, "a", buffering=1)
        self.clients = []
        self.listener = None

    def note(self, line):
        self.log.write(line + "\n")

    # ---- objects and globals ------------------------------------------------------------

    def globals(self):
        """(name, interface, version) of every global, as the registry announces them."""
        result = [(1, "zwlr_output_manager_v1", 4), (2, "zwlr_gamma_control_manager_v1", 1)]
        for index in range(len(self.outputs)):
            result.append((100 + index, "wl_output", 4))
        return result

    def on_connect(self, client):
        self.clients.append(client)

    # ---- sending state --------------------------------------------------------------------

    def send_head(self, client, out_index, head_id):
        """The properties of one head, then its modes (the wlr-output-management event order)."""
        out = self.outputs[out_index]
        client.send(head_id, ("zwlr_output_head_v1", "name"), [out["name"]])
        client.send(head_id, ("zwlr_output_head_v1", "description"), [out["description"]])
        client.send(head_id, ("zwlr_output_head_v1", "physical_size"), [out["width_mm"], out["height_mm"]])
        for mode_index, mode in enumerate(out["modes"]):
            mode_id = client.mode_ids.get((out_index, mode_index))
            if mode_id is None:
                mode_id = client.server_id()
                client.mode_ids[(out_index, mode_index)] = mode_id
                client.modes[mode_id] = (out_index, mode_index)
                client.objects[mode_id] = ("zwlr_output_mode_v1", None)
                client.send(head_id, ("zwlr_output_head_v1", "mode"), [mode_id])
            client.send(mode_id, ("zwlr_output_mode_v1", "size"), [mode["width"], mode["height"]])
            client.send(mode_id, ("zwlr_output_mode_v1", "refresh"), [mode["refresh"]])
            if mode.get("preferred"):
                client.send(mode_id, ("zwlr_output_mode_v1", "preferred"), [])
        client.send(head_id, ("zwlr_output_head_v1", "enabled"), [1 if out["enabled"] else 0])
        if out["current"] is not None and out["enabled"]:
            client.send(head_id, ("zwlr_output_head_v1", "current_mode"), [client.mode_ids[(out_index, out["current"])]])
        client.send(head_id, ("zwlr_output_head_v1", "position"), [out["x"], out["y"]])
        client.send(head_id, ("zwlr_output_head_v1", "transform"), [out["transform"]])
        client.send(head_id, ("zwlr_output_head_v1", "scale"), [float(out["scale"])])
        client.send(head_id, ("zwlr_output_head_v1", "make"), [out["make"]])
        client.send(head_id, ("zwlr_output_head_v1", "model"), [out["model"]])
        client.send(head_id, ("zwlr_output_head_v1", "serial_number"), [out["serial"]])
        client.send(head_id, ("zwlr_output_head_v1", "adaptive_sync"), [0])

    def send_manager_state(self, client):
        """Announce every head to the manager, then the serial that ends the state."""
        client.heads = {}
        for out_index in range(len(self.outputs)):
            head_id = client.server_id()
            client.objects[head_id] = ("zwlr_output_head_v1", None)
            client.heads[head_id] = out_index
            client.send(client.manager, ("zwlr_output_manager_v1", "head"), [head_id])
            self.send_head(client, out_index, head_id)
        client.send(client.manager, ("zwlr_output_manager_v1", "done"), [self.serial])

    def send_updates(self, client):
        """After a change: the properties of every head again, then the new serial."""
        for head_id, out_index in client.heads.items():
            self.send_head(client, out_index, head_id)
        client.send(client.manager, ("zwlr_output_manager_v1", "done"), [self.serial])

    # ---- configurations ------------------------------------------------------------------

    def decide(self, client, config_id):
        """Whether the configuration would succeed; the scenario's refused transform makes it fail."""
        config = client.configs[config_id]
        refused = self.scenario.get("reject_transform")
        for change in config["changes"].values():
            if refused is not None and change.get("transform") == refused:
                return False
        return True

    def apply_changes(self, client, config_id):
        config = client.configs[config_id]
        for out_index, change in config["changes"].items():
            out = self.outputs[out_index]
            if "enabled" in change:
                out["enabled"] = change["enabled"]
            if "mode" in change and change["mode"] is not None:
                out["current"] = change["mode"]
            if "custom" in change:
                custom = change["custom"]
                out["modes"].append({"width": custom[0], "height": custom[1], "refresh": custom[2], "preferred": False})
                out["current"] = len(out["modes"]) - 1
            for key in ("x", "y", "transform", "scale"):
                if key in change:
                    out[key] = change[key]
        self.serial += 1

    def finish_config(self, client, config_id, test_only):
        ok = self.decide(client, config_id)
        if test_only:
            self.note("config.test %s" % ("ok" if ok else "failed"))
            client.send(config_id, ("zwlr_output_configuration_v1", "succeeded" if ok else "failed"), [])
            return
        self.note("config.apply %s" % ("ok" if ok else "failed"))
        if not ok:
            client.send(config_id, ("zwlr_output_configuration_v1", "failed"), [])
            return
        self.apply_changes(client, config_id)
        client.send(config_id, ("zwlr_output_configuration_v1", "succeeded"), [])
        self.send_updates(client)

    # ---- gamma ---------------------------------------------------------------------------

    def set_gamma(self, client, control_id, fd):
        out_index = client.gamma_controls[control_id]
        out = self.outputs[out_index]
        size = GAMMA_SIZE
        data = os.pread(fd, size * 3 * 2, 0)
        os.close(fd)
        table = array.array("H")
        table.frombytes(data[:size * 3 * 2])
        if sys.byteorder == "big":
            table.byteswap()
        red, green, blue = table[0:size], table[size:2 * size], table[2 * size:3 * size]
        self.note("gamma.set %s red=%d,%d green=%d,%d blue=%d,%d" % (
            out["name"], red[0], red[size - 1], green[0], green[size - 1], blue[0], blue[size - 1]))

    # ---- request dispatch ----------------------------------------------------------------

    def dispatch(self, client, obj_id, opcode, values):
        iface = client.objects.get(obj_id, (None, None))[0]
        if iface is None:
            return
        if iface == "wl_display":
            if opcode == 0:  # sync
                callback = values[0]
                client.objects[callback] = ("wl_callback", None)
                client.send(callback, ("wl_callback", "done"), [self.serial])
                client.send(1, ("wl_display", "delete_id"), [callback])
            elif opcode == 1:  # get_registry
                client.objects[values[0]] = ("wl_registry", None)
                for name, interface, version in self.globals():
                    client.send(values[0], ("wl_registry", "global"), [name, interface, version])
            return
        if iface == "wl_registry" and opcode == 0:
            name, interface, version, new_id = values
            client.objects[new_id] = (interface, None)
            if interface == "zwlr_output_manager_v1":
                client.manager = new_id
                self.send_manager_state(client)
            elif interface == "wl_output":
                index = name - 100
                client.objects[new_id] = ("wl_output", index)
                client.send(new_id, ("wl_output", "geometry"),
                            [0, 0, self.outputs[index]["width_mm"], self.outputs[index]["height_mm"], 0,
                             self.outputs[index]["make"], self.outputs[index]["model"], 0])
                mode = self.outputs[index]["modes"][0] if self.outputs[index]["modes"] else None
                if mode is not None:
                    client.send(new_id, ("wl_output", "mode"), [WL_OUTPUT_CURRENT, mode["width"], mode["height"], mode["refresh"]])
                client.send(new_id, ("wl_output", "name"), [self.outputs[index]["name"]])
                client.send(new_id, ("wl_output", "done"), [])
            return
        if iface == "zwlr_output_manager_v1":
            if opcode == 0:  # create_configuration(id, serial)
                config_id, serial = values
                client.objects[config_id] = ("zwlr_output_configuration_v1", None)
                if serial != self.serial:
                    client.send(config_id, ("zwlr_output_configuration_v1", "cancelled"), [])
                else:
                    client.configs[config_id] = {"serial": serial, "changes": {}}
            return
        if iface == "zwlr_output_configuration_v1":
            if opcode == 0:  # enable_head(id, head)
                head_obj_id, head_id = values
                out_index = client.heads[head_id]
                client.objects[head_obj_id] = ("zwlr_output_configuration_head_v1", None)
                client.config_heads[head_obj_id] = (obj_id, out_index)
                client.configs[obj_id]["changes"].setdefault(out_index, {})["enabled"] = True
            elif opcode == 1:  # disable_head(head)
                out_index = client.heads[values[0]]
                client.configs[obj_id]["changes"].setdefault(out_index, {})["enabled"] = False
                self.note("config.disable %s" % self.outputs[out_index]["name"])
            elif opcode == 2:
                self.finish_config(client, obj_id, test_only=False)
            elif opcode == 3:
                self.finish_config(client, obj_id, test_only=True)
            elif opcode == 4:
                client.objects.pop(obj_id, None)
                client.configs.pop(obj_id, None)
            return
        if iface == "zwlr_output_configuration_head_v1":
            config_id, out_index = client.config_heads[obj_id]
            change = client.configs[config_id]["changes"].setdefault(out_index, {})
            name = self.outputs[out_index]["name"]
            if opcode == 0:  # set_mode(mode)
                mode_out, mode_index = client.modes[values[0]]
                change["mode"] = mode_index
                self.note("config.mode %s %d" % (name, mode_index))
            elif opcode == 1:  # set_custom_mode(w, h, refresh)
                change["custom"] = values
                self.note("config.custom_mode %s %d %d %d" % (name, *values))
            elif opcode == 2:
                change["x"], change["y"] = values
                self.note("config.set_position %s %d %d" % (name, *values))
            elif opcode == 3:
                change["transform"] = values[0]
                self.note("config.set_transform %s %d" % (name, values[0]))
            elif opcode == 4:
                change["scale"] = values[0] / 256.0
                self.note("config.set_scale %s %s" % (name, change["scale"]))
            elif opcode == 5:
                change["adaptive"] = values[0]
                self.note("config.set_adaptive_sync %s %d" % (name, values[0]))
            return
        if iface == "zwlr_gamma_control_manager_v1":
            if opcode == 0:  # get_gamma_control(id, output)
                control_id, output_obj = values
                out_index = client.objects[output_obj][1]
                client.objects[control_id] = ("zwlr_gamma_control_v1", None)
                name = self.outputs[out_index]["name"]
                if not self.outputs[out_index]["gamma"]:
                    self.note("gamma.refuse %s" % name)
                    client.send(control_id, ("zwlr_gamma_control_v1", "failed"), [])
                    return
                client.gamma_controls[control_id] = out_index
                self.note("gamma.control %s" % name)
                client.send(control_id, ("zwlr_gamma_control_v1", "gamma_size"), [GAMMA_SIZE])
            return
        if iface == "zwlr_gamma_control_v1":
            if opcode == 0:  # set_gamma(fd)
                self.set_gamma(client, obj_id, values[0])
            elif opcode == 1:  # destroy
                out_index = client.gamma_controls.pop(obj_id, None)
                client.objects.pop(obj_id, None)
                if out_index is not None:
                    self.note("gamma.destroy %s" % self.outputs[out_index]["name"])
            return

    # ---- the socket loop -----------------------------------------------------------------

    def read_messages(self, client):
        """Read what arrived (and its fds), then dispatch every complete message in order."""
        ancillary_size = socket.CMSG_SPACE(4 * 16)
        data, ancillary, flags, _ = client.sock.recvmsg(65536, ancillary_size)
        for level, kind, payload in ancillary:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                fds = array.array("i")
                fds.frombytes(payload[:len(payload) - len(payload) % fds.itemsize])
                client.fds.extend(fds.tolist())
        if not data:
            return False
        client.buf.extend(data)
        while len(client.buf) >= 8:
            obj_id, size_opcode = struct.unpack_from("<II", client.buf, 0)
            size, opcode = size_opcode >> 16, size_opcode & 0xFFFF
            if len(client.buf) < size:
                break
            body = bytes(client.buf[8:size])
            del client.buf[:size]
            values = self.parse(client, obj_id, opcode, body)
            if values is not None:
                self.dispatch(client, obj_id, opcode, values)
        return True

    def parse(self, client, obj_id, opcode, body):
        iface = client.objects.get(obj_id, (None, None))[0]
        spec = request_spec(iface, opcode) if iface else None
        if spec is None:
            return None
        name, args = spec
        values = []
        offset = 0
        for arg_name, typ in args:
            if typ in ("uint", "new_id", "object"):
                values.append(struct.unpack_from("<I", body, offset)[0])
                offset += 4
            elif typ == "int":
                values.append(struct.unpack_from("<i", body, offset)[0])
                offset += 4
            elif typ == "fixed":
                values.append(struct.unpack_from("<i", body, offset)[0] / 256.0)
                offset += 4
            elif typ == "string":
                length = struct.unpack_from("<I", body, offset)[0]
                values.append(body[offset + 4:offset + 4 + length - 1].decode())
                offset += 4 + length + (4 - length % 4) % 4
            elif typ == "fd":
                values.append(client.fds.pop(0))
        return values


def main():
    socket_path, scenario_path, log_path = sys.argv[1], sys.argv[2], sys.argv[3]
    with open(scenario_path) as handle:
        scenario = json.load(handle)
    compositor = Compositor(scenario, log_path)
    if os.path.exists(socket_path):
        os.unlink(socket_path)
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(socket_path)
    listener.listen(16)
    stopping = []
    signal.signal(signal.SIGTERM, lambda *_: stopping.append(True))
    signal.signal(signal.SIGINT, lambda *_: stopping.append(True))
    print("READY", flush=True)
    while not stopping:
        readable = [listener] + [c.sock for c in compositor.clients]
        ready, _, _ = select.select(readable, [], [], 0.2)
        for sock in ready:
            if sock is listener:
                conn, _ = listener.accept()
                compositor.on_connect(Client(conn))
                continue
            client = next(c for c in compositor.clients if c.sock is sock)
            if not compositor.read_messages(client):
                compositor.clients.remove(client)
                client.sock.close()
    listener.close()
    os.unlink(socket_path)


if __name__ == "__main__":
    main()
