#!/usr/bin/env python3
"""Generate C3 Wayland protocol bindings from protocol XML (the job wayland-scanner does for C).

    python3 wlscan.py --manifest protocols.tsv --xml-dir DIR --out libs/bleu_wl.c3l/src/proto

For every protocol in the manifest this writes `<out>/<module>.c3`. Per interface:

* `const display::Interface WL_X` - the wire name, the highest version this binding
  speaks, and the dispatch function that decodes the interface's events;
* `struct WlX { display::Proxy base; }` - the typed view of a proxy (`base` is the
  first field, so pointers convert both ways);
* a `constset` for each enum and bitfield, typed `uint`;
* `alias` function types and `struct WlXListener` of function pointers, one per
  event, each taking `void* context` first (C3 has no closures);
* request methods that encode the wire format and check `since`;
* `wl_x_dispatch`, which decodes one incoming event and calls the listener.

Destructor requests and destructor events retire the object locally. Two core
events also call into the runtime, as given in `HOOKS`.

Standard library only. The output is deterministic: the same XML gives the same
bytes, so regenerating is a reviewable diff.
"""
import argparse
import os
import re
import sys
import textwrap
import xml.etree.ElementTree as ET

# Runtime code that must run when an event arrives, in addition to the user's
# listener. Keyed by (interface, event); the template may use the event's
# argument names as C3 locals.
HOOKS = {
    ("wl_display", "error"): "conn.protocol_error(object_id, code, message)!;",
    ("wl_display", "delete_id"): "conn.release_id(id);",
}

# Identifiers the generated code uses for itself or C3 reserves. A protocol
# argument with one of these names gets a trailing underscore.
RESERVED = {
    "alias", "any", "asm", "assert", "bitfield", "bitstruct", "body", "bool", "break",
    "case", "catch", "char", "const", "constset", "continue", "default", "defer", "do",
    "double", "else", "enum", "extern", "false", "fault", "float", "fn", "for", "foreach",
    "if", "import", "inline", "int", "interface", "isz", "local", "long", "macro",
    "module", "nextcase", "null", "private", "public", "return", "self", "short",
    "sizeof", "static", "struct", "switch", "sz", "tlocal", "true", "try", "typedef",
    "typeid", "uint", "ulong", "union", "unreachable", "usz", "var", "void", "while",
    "args", "context", "conn", "created", "listener", "opcode", "proxy", "target", "w",
    "display", "wire", "error", "rt",
}

# Wire read method for each non-object, non-enum argument type.
READERS = {"int": "get_int", "uint": "get_uint", "fixed": "get_fixed", "string": "get_string",
           "array": "get_array", "fd": "get_fd"}


def pascal(name):
    """'wl_output' -> 'WlOutput', 'zwlr_gamma_control_v1' -> 'ZwlrGammaControlV1'."""
    return "".join(part[:1].upper() + part[1:] for part in name.split("_") if part)


def ident(name):
    """A C3 identifier for a protocol name ('-' and leading digits are not allowed)."""
    name = re.sub(r"[^A-Za-z0-9_]", "_", name)
    if name[:1].isdigit():
        name = "_" + name
    return name + "_" if name in RESERVED else name


def const_name(name):
    """A constset member: 'flipped-90' -> 'FLIPPED_90', '90' -> 'N90'."""
    name = re.sub(r"[^A-Za-z0-9_]", "_", name).upper()
    return "N" + name if name[:1].isdigit() else name


def doc(text, *, indent=""):
    """Doc-comment lines for prose: one paragraph, wrapped to 92 columns."""
    text = " ".join(text.split()).replace("*>", "* >")
    lines = []
    for line in textwrap.wrap(text, width=92 - len(indent)):
        # A line starting with '@' would be read as a contract tag.
        lines.append(indent + " " + ("`" + line if line.startswith("@") else line))
    return lines


def text_of(element):
    """Text of a <description> child, or the element's own summary attribute."""
    desc = element.find("description")
    if desc is not None and desc.text and desc.text.strip():
        return desc.text
    return element.get("summary", "")


class Arg:
    def __init__(self, element):
        self.name = element.get("name")
        self.type = element.get("type")
        self.target = element.get("interface")
        self.enum = element.get("enum")
        self.nullable = element.get("allow-null") == "true"
        self.ident = ident(self.name)


class Message:
    """A request or an event. Its opcode is its position in the XML."""

    def __init__(self, element, opcode):
        self.name = element.get("name")
        self.ident = ident(self.name)
        self.opcode = opcode
        self.since = int(element.get("since", "1"))
        self.destructor = element.get("type") == "destructor"
        self.description = text_of(element)
        self.args = [Arg(a) for a in element.findall("arg")]


class Enum:
    def __init__(self, element, interface):
        self.name = element.get("name")
        self.bitfield = element.get("bitfield") == "true"
        self.interface = interface
        self.description = text_of(element)
        self.entries = [(const_name(e.get("name")), int(e.get("value"), 0)) for e in element.findall("entry")]
        self.pascal = interface.pascal + pascal(self.name)


class Interface:
    def __init__(self, element, protocol):
        self.name = element.get("name")
        self.version = int(element.get("version"))
        self.protocol = protocol
        self.pascal = pascal(self.name)
        self.constant = const_name(self.name)
        self.summary = element.get("summary", "")
        self.description = text_of(element)
        self.requests = [Message(e, i) for i, e in enumerate(element.findall("request"))]
        self.events = [Message(e, i) for i, e in enumerate(element.findall("event"))]
        self.enums = [Enum(e, self) for e in element.findall("enum")]

    @property
    def module(self):
        return self.protocol.module


class Protocol:
    def __init__(self, module, path):
        self.module = module
        root = ET.parse(path).getroot()
        self.name = root.get("name")
        self.interfaces = [Interface(e, self) for e in root.findall("interface")]


class Registry:
    """Every interface and enum of every protocol, so references can name their module."""

    def __init__(self, protocols):
        self.interfaces = {}
        self.enums = {}
        for protocol in protocols:
            for iface in protocol.interfaces:
                self.interfaces[iface.name] = iface
                for enum in iface.enums:
                    self.enums[(iface.name, enum.name)] = enum

    @staticmethod
    def qualify(module, name, current):
        return name if module == current else f"{module}::{name}"

    def object_type(self, target, current):
        """Type of an object argument: a typed pointer when the interface is known."""
        if target is None:
            return "display::Proxy*"
        iface = self.interfaces[target]
        return self.qualify(iface.module, iface.pascal, current) + "*"

    def object_constant(self, target, current):
        iface = self.interfaces[target]
        return self.qualify(iface.module, iface.constant, current)

    def enum_type(self, arg, owner, current):
        """Type of an enum argument. 'iface.enum' names an enum of another interface."""
        if "." in arg.enum:
            owner_name, enum_name = arg.enum.split(".", 1)
        else:
            owner_name, enum_name = owner.name, arg.enum
        enum = self.enums[(owner_name, enum_name)]
        return self.qualify(enum.interface.module, enum.pascal, current)

    def value_type(self, arg, owner, current):
        """C3 type of an argument as a parameter (requests) or a value (events)."""
        if arg.enum:
            return self.enum_type(arg, owner, current)
        if arg.type in ("int", "uint"):
            return arg.type
        if arg.type == "fixed":
            return "wire::Fixed"
        if arg.type == "string":
            return "String"
        if arg.type == "array":
            return "char[]"
        if arg.type == "fd":
            return "Native"
        if arg.type == "object":
            return self.object_type(arg.target, current)
        if arg.type == "new_id":
            return self.object_type(arg.target, current)
        raise ValueError(f"unknown argument type {arg.type}")

    def modules_referenced(self, protocol):
        """Other protocol modules whose names this module's generated code mentions."""
        needed = set()
        for iface in protocol.interfaces:
            for msg in iface.requests + iface.events:
                for arg in msg.args:
                    if arg.target:
                        needed.add(self.interfaces[arg.target].module)
                    if arg.enum and "." in arg.enum:
                        needed.add(self.interfaces[arg.enum.split(".", 1)[0]].module)
        needed.discard(protocol.module)
        return sorted(needed)


def request_params(msg, iface, registry):
    """Parameters of a request method, in wire order. A typed new_id is the return value,
    not a parameter; an untyped one is passed as a proxy, preceded on the wire by the
    interface name and version (wire protocol, "new_id" without an interface)."""
    params = []
    for arg in msg.args:
        if arg.type == "new_id" and arg.target:
            continue
        if arg.type == "new_id":
            params.append("String interface_name")
            params.append("uint version")
            params.append(f"display::Proxy* {arg.ident}")
        else:
            params.append(f"{registry.value_type(arg, iface, iface.module)} {arg.ident}")
    return params


def request_encode(arg, registry, iface):
    """Lines that write one request argument into `w`."""
    n = arg.ident
    if arg.enum:
        return [f"w.put_int((int)(uint){n})!;" if arg.type == "int" else f"w.put_uint((uint){n})!;"]
    if arg.type == "int":
        return [f"w.put_int({n})!;"]
    if arg.type == "uint":
        return [f"w.put_uint({n})!;"]
    if arg.type == "fixed":
        return [f"w.put_fixed({n})!;"]
    if arg.type == "string":
        return [f"w.put_{'nullable_' if arg.nullable else ''}string({n})!;"]
    if arg.type == "array":
        return [f"w.put_array({n})!;"]
    if arg.type == "fd":
        return [f"w.put_fd({n})!;"]
    if arg.type == "object":
        ref = f"{n}.base.id" if arg.target else f"{n}.id"
        return [f"w.put_object({n} == null ? 0 : {ref})!;" if arg.nullable else f"w.put_object({ref})!;"]
    raise ValueError(f"unknown argument type {arg.type}")


def emit_request(msg, iface, registry):
    """One request method: encodes the message, sends it, retires a destructor."""
    typed_new = next((a for a in msg.args if a.type == "new_id" and a.target), None)
    ret = registry.object_type(typed_new.target, iface.module) if typed_new else "void"
    out = [""]
    out.append("<*")
    out.extend(doc(msg.description or msg.name))
    if msg.since > 1:
        out.extend(doc(f"Available since version {msg.since}."))
    if msg.destructor:
        out.extend(doc("Destructor: the object is retired locally once the request is sent."))
    out.append("*>")
    params = request_params(msg, iface, registry)
    out.append(f"fn {ret}? {iface.pascal}.{msg.ident}(&self" + "".join(f", {p}" for p in params) + ")")
    out.append("{")
    out.append("\twire::Writer w;")
    out.append(f"\tw.begin(self.base.id, {msg.opcode});")
    if msg.since > 1:
        out.append(f"\tif (self.base.version < {msg.since})")
        out.append("\t{")
        out.append(f'\t\treturn error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, '
                   f'"{iface.name}.{msg.name} needs version {msg.since}, bound at version %d", '
                   f'self.base.version)~;')
        out.append("\t}")
    if typed_new:
        const = registry.object_constant(typed_new.target, iface.module)
        out.append(f"\tdisplay::Proxy* created = self.base.conn.new_object({const}, self.base.version)!;")
    for arg in msg.args:
        if arg.type == "new_id" and arg.target:
            out.append("\tw.put_new_id(created.id)!;")
        elif arg.type == "new_id":
            out.append("\tw.put_string(interface_name)!;")
            out.append("\tw.put_uint(version)!;")
            out.append(f"\tw.put_new_id({arg.ident}.id)!;")
        else:
            out.extend("\t" + line for line in request_encode(arg, registry, iface))
    out.append("\tself.base.conn.send(&w)!;")
    if msg.destructor:
        out.append("\tself.base.conn.retire(&self.base);")
    if typed_new:
        out.append(f"\treturn ({ret})created;")
    out.append("}")
    return out


def emit_listener(iface, registry):
    """Function types and the listener struct. Empty when the interface has no events."""
    if not iface.events:
        return []
    out = []
    for ev in iface.events:
        alias = f"{iface.pascal}{pascal(ev.name)}Fn"
        params = ["void* context", f"{iface.pascal}* target"]
        for arg in ev.args:
            if arg.type == "new_id" and not arg.target:
                raise ValueError(f"untyped new_id in event {iface.name}.{ev.name}")
            params.append(f"{registry.value_type(arg, iface, iface.module)} {arg.ident}")
        out.append("")
        out.append("<*")
        out.extend(doc(f"Event {iface.name}.{ev.name}: {ev.description or ev.name}"))
        out.append("*>")
        out.append(f"alias {alias} = fn void({', '.join(params)});")
    out.append("")
    out.append("<*")
    out.extend(doc(f"Event handlers of {iface.name}. A null field ignores its event. Strings and arrays are "
                   "valid only during the call, and a descriptor is owned by the handler, which must close it."))
    out.append("*>")
    out.append(f"struct {iface.pascal}Listener")
    out.append("{")
    for ev in iface.events:
        out.append(f"\t{iface.pascal}{pascal(ev.name)}Fn {ev.ident};")
    out.append("}")
    return out


def decode_event(ev, iface, registry):
    """The `case` body that reads one event's arguments and calls the listener."""
    lines = []
    fds = []
    values = []
    for arg in ev.args:
        n = arg.ident
        ctype = registry.value_type(arg, iface, iface.module)
        if arg.type == "new_id":
            const = registry.object_constant(arg.target, iface.module)
            lines.append(f"\t\t\tuint {n}_id = args.get_new_id()!;")
            lines.append(f"\t\t\t{ctype} {n} = ({ctype})(conn.server_object({n}_id, {const}, proxy.version)!);")
        elif arg.type == "object":
            # The raw id stays in a local named after the argument (hooks read it); the
            # object is resolved, and an id the client no longer knows is passed as null.
            lines.append(f"\t\t\tuint {n} = args.get_object()!;")
            lines.append(f"\t\t\tdisplay::Proxy* {n}_obj = conn.find({n});")
            values.append(f"({ctype}){n}_obj")
            continue
        elif arg.enum:
            getter = "get_int" if arg.type == "int" else "get_uint"
            cast = "(uint)" if arg.type == "int" else ""
            lines.append(f"\t\t\t{ctype} {n} = ({ctype})({cast}args.{getter}()!);")
        else:
            lines.append(f"\t\t\t{ctype} {n} = args.{READERS[arg.type]}()!;")
        if arg.type == "fd":
            fds.append(n)
        values.append(n)
    live = f"!proxy.zombie && listener != null && listener.{ev.ident} != null"
    call = ", ".join(["proxy.context", f"({iface.pascal}*)proxy"] + values)
    lines.append(f"\t\t\tif ({live})")
    lines.append("\t\t\t{")
    lines.append(f"\t\t\t\tlistener.{ev.ident}({call});")
    lines.append("\t\t\t}")
    if fds:
        # The handler did not run, so nobody else will close the descriptors that came with the event.
        lines.append("\t\t\telse")
        lines.append("\t\t\t{")
        lines.extend(f"\t\t\t\tconn.close_native({f});" for f in fds)
        lines.append("\t\t\t}")
    if (iface.name, ev.name) in HOOKS:
        lines.append("\t\t\t" + HOOKS[(iface.name, ev.name)])
    if ev.destructor:
        lines.append("\t\t\tconn.retire(proxy);")
    return lines


def emit_dispatch(iface, registry):
    """`fn void? <iface>_dispatch`: decodes one event and calls the listener."""
    out = [f"fn void? {iface.name}_dispatch(display::Display* conn, display::Proxy* proxy, ushort opcode, "
           "wire::Reader* args)", "{"]
    if iface.events:
        out.append(f"\t{iface.pascal}Listener* listener = ({iface.pascal}Listener*)proxy.listener;")
    out.append("\tswitch (opcode)")
    out.append("\t{")
    for ev in iface.events:
        out.append(f"\t\tcase {ev.opcode}:")
        out.append("\t\t{")
        out.extend(decode_event(ev, iface, registry))
        out.append("\t\t\treturn;")
        out.append("\t\t}")
    out.append("\t\tdefault:")
    out.append(f'\t\t\treturn error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, '
               f'"opcode %d is not an event of {iface.name}", opcode)~;')
    out.append("\t}")
    out.append("}")
    return out


def emit_enum(enum):
    out = [""]
    out.append("<*")
    bit = "; a bitfield, members combine with |" if enum.bitfield else ""
    out.extend(doc(f"{enum.description or enum.name} ({enum.interface.name}.{enum.name}{bit})."))
    out.append("*>")
    out.append(f"constset {enum.pascal} : uint")
    out.append("{")
    out.extend(f"\t{name} = {value}," for name, value in enum.entries)
    out.append("}")
    return out


def emit_interface(iface, registry):
    out = [""]
    out.append("<*")
    out.extend(doc(f"{iface.name} version {iface.version}" + (f": {iface.summary}" if iface.summary else "") + "."))
    if iface.description.strip():
        out.extend(doc(iface.description))
    out.append("*>")
    out.append(f'const display::Interface {iface.constant} = {{ .name = "{iface.name}", '
               f".version = {iface.version}, .dispatch = &{iface.name}_dispatch }};")
    out.append("")
    out.append("<*")
    out.extend(doc(f"Typed view of a {iface.name} object. The proxy is the first field, so a pointer to "
                   "either type converts to the other."))
    out.append("*>")
    out.append(f"struct {iface.pascal}")
    out.append("{")
    out.append("\tdisplay::Proxy base;")
    out.append("}")
    for enum in iface.enums:
        out.extend(emit_enum(enum))
    listener = emit_listener(iface, registry)
    out.extend(listener)
    if iface.events:
        out.append("")
        out.append("<*")
        out.extend(doc("Install the event handlers. The listener and the context must outlive the object."))
        out.append("*>")
        out.append(f"fn void {iface.pascal}.set_listener(&self, {iface.pascal}Listener* listener, void* context)")
        out.append("{")
        out.append("\tself.base.listener = listener;")
        out.append("\tself.base.context = context;")
        out.append("}")
    for req in iface.requests:
        out.append("")
        out.extend(emit_request(req, iface, registry))
    if not any(r.destructor for r in iface.requests):
        out.append("")
        out.append("<*")
        out.extend(doc(f"Stop using this object locally. {iface.name} has no destructor request, so the server "
                       "releases its id with wl_display.delete_id."))
        out.append("*>")
        out.append(f"fn void {iface.pascal}.destroy(&self)")
        out.append("{")
        out.append("\tself.base.conn.retire(&self.base);")
        out.append("}")
    out.append("")
    out.extend(emit_dispatch(iface, registry))
    return out


def emit_module(protocol, registry):
    body = []
    for iface in protocol.interfaces:
        body.extend(emit_interface(iface, registry))
    head = [
        f'// GENERATED by tools/wlscan/wlscan.py from the Wayland protocol "{protocol.name}". Do not edit.',
        "// Regenerate with tools/wlscan/regen.sh.",
        f"module bleu::wl::proto::{protocol.module};",
        "import bleu::error, bleu::rt, bleu::wl::display, bleu::wl::wire;",
    ]
    head.extend(f"import bleu::wl::proto::{m};" for m in registry.modules_referenced(protocol))
    return "\n".join(head + body) + "\n"


def read_manifest(path, xml_dir):
    protocols = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            if not line.strip() or line.startswith("#"):
                continue
            module, _url = line.rstrip("\n").split("\t", 1)
            protocols.append(Protocol(module, os.path.join(xml_dir, module + ".xml")))
    return protocols


def main(argv):
    parser = argparse.ArgumentParser(description="Generate C3 Wayland bindings from protocol XML.")
    parser.add_argument("--manifest", required=True, help="protocols.tsv: module<TAB>url per line")
    parser.add_argument("--xml-dir", required=True, help="directory holding <module>.xml for each line")
    parser.add_argument("--out", required=True, help="output directory for <module>.c3")
    args = parser.parse_args(argv)
    protocols = read_manifest(args.manifest, args.xml_dir)
    registry = Registry(protocols)
    os.makedirs(args.out, exist_ok=True)
    for protocol in protocols:
        with open(os.path.join(args.out, protocol.module + ".c3"), "w", encoding="utf-8") as f:
            f.write(emit_module(protocol, registry))
    count = sum(len(p.interfaces) for p in protocols)
    print(f"wrote {len(protocols)} modules with {count} interfaces to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
