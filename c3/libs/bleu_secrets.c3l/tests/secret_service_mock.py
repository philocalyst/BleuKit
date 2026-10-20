#!/usr/bin/env python3
"""A mock of org.freedesktop.secrets for testing the Bleu Secret Service backend.

It implements the Service, Collection, Item, Session and Prompt interfaces of the
Secret Service API draft, on a session bus. The DH session
(dh-ietf1024-sha256-aes128-cbc-pkcs7) is implemented here from the spec, with
Python integers, hmac/hashlib and the `cryptography` package. It shares no code
with the C3 implementation, so the two validate each other.

Usage: secret_service_mock.py BUS_ADDRESS MODE

MODE selects the scenario:
  normal        DH session; the default collection is unlocked.
  refuse-dh     OpenSession refuses the DH algorithm (org.freedesktop.DBus.Error.NotSupported).
  locked        the default collection starts locked; Unlock returns a prompt that is accepted.
  dismiss       as locked, but the prompt is dismissed by the user.
  hang          as locked, but the prompt never completes.
  no-collection the default alias has no collection, so one must be created.

Prints "READY" on stdout once the name is owned.
"""
import asyncio
import hashlib
import hmac
import os
import sys
import time

from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from dbus_next import DBusError, PropertyAccess, Variant
from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, dbus_property, method, signal

# RFC 2409 section 6.2, Second Oakley Group: 1024-bit MODP prime, generator 2.
P = int(
    "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74"
    "020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437"
    "4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"
    "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF",
    16,
)
G = 2
SERVICE_PATH = "/org/freedesktop/secrets"
ALIAS_PATH = "/org/freedesktop/secrets/collection/login"
DH_ALGORITHM = "dh-ietf1024-sha256-aes128-cbc-pkcs7"
PLAIN_ALGORITHM = "plain"
PROMPT_DELAY = 0.1

MODE = sys.argv[2] if len(sys.argv) > 2 else "normal"
STATE = {"sessions": {}, "items": {}, "prompts": {}, "counter": 0, "collections": {}}
LOG = []


def next_id() -> int:
    STATE["counter"] += 1
    return STATE["counter"]


def hkdf16(ikm: bytes) -> bytes:
    prk = hmac.new(b"\x00" * 32, ikm, hashlib.sha256).digest()
    return hmac.new(prk, b"\x01", hashlib.sha256).digest()[:16]


def int_bytes(n: int) -> bytes:
    return n.to_bytes((n.bit_length() + 7) // 8 or 1, "big")


def encrypt(key: bytes, iv: bytes, plain: bytes) -> bytes:
    padder = padding.PKCS7(128).padder()
    data = padder.update(plain) + padder.finalize()
    enc = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
    return enc.update(data) + enc.finalize()


def decrypt(key: bytes, iv: bytes, cipher: bytes) -> bytes:
    dec = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
    data = dec.update(cipher) + dec.finalize()
    unpadder = padding.PKCS7(128).unpadder()
    return unpadder.update(data) + unpadder.finalize()


def secret_struct(session_path: str, session_key, plain: bytes):
    """A (oayays) value for `plain`, encrypted when the session is encrypted."""
    if session_key is None:
        return (session_path, b"", plain, "text/plain; charset=utf8")
    iv = os.urandom(16)
    return (session_path, iv, encrypt(session_key, iv, plain), "text/plain; charset=utf8")


def read_secret_struct(session_key, struct):
    _, params, value, _ = struct
    if session_key is None:
        return bytes(value)
    if len(params) != 16:
        raise DBusError("org.freedesktop.Secret.Error.InvalidArgs", "encrypted secret without IV")
    return decrypt(session_key, bytes(params), bytes(value))


class Collection(ServiceInterface):
    def __init__(self, path: str, label: str, locked: bool):
        super().__init__("org.freedesktop.Secret.Collection")
        self.path = path
        self.label = label
        self.locked_flag = locked
        self.created = int(time.time())
        self.modified = self.created
        STATE["collections"][path] = self

    @dbus_property(access=PropertyAccess.READ)
    def Locked(self) -> "b":
        return self.locked_flag

    @dbus_property(access=PropertyAccess.READ)
    def Label(self) -> "s":
        return self.label

    @dbus_property(access=PropertyAccess.READ)
    def Created(self) -> "t":
        return self.created

    @dbus_property(access=PropertyAccess.READ)
    def Modified(self) -> "t":
        return self.modified

    @dbus_property(access=PropertyAccess.READ)
    def Items(self) -> "ao":
        return [p for p, i in STATE["items"].items() if i["collection"] == self.path]

    def set_locked(self, value: bool):
        self.locked_flag = value
        self.emit_properties_changed({"Locked": value})

    @method()
    def SearchItems(self, attributes: "a{ss}") -> "ao":
        return [p for p, i in STATE["items"].items() if i["collection"] == self.path and matches(i, attributes)]

    @method()
    def CreateItem(self, properties: "a{sv}", secret: "(oayays)", replace: "b") -> "oo":
        if self.locked_flag:
            raise DBusError("org.freedesktop.Secret.Error.IsLocked", "collection is locked")
        session = secret[0]
        if session not in STATE["sessions"]:
            raise DBusError("org.freedesktop.Secret.Error.NoSession", "unknown session")
        key = STATE["sessions"][session]
        plain = read_secret_struct(key, secret)
        attributes = dict(properties["org.freedesktop.Secret.Item.Attributes"].value)
        label = properties["org.freedesktop.Secret.Item.Label"].value
        for path, item in STATE["items"].items():
            if item["collection"] == self.path and item["attributes"] == attributes:
                if not replace:
                    raise DBusError("org.freedesktop.Secret.Error.AlreadyExists", "item exists")
                item["secret"] = plain
                item["label"] = label
                item["modified"] = int(time.time())
                LOG.append(("replaced", path))
                return [path, "/"]
        path = f"{self.path}/{next_id()}"
        STATE["items"][path] = {
            "collection": self.path,
            "attributes": attributes,
            "label": label,
            "secret": plain,
            "created": int(time.time()),
            "modified": int(time.time()),
            "iface": None,
        }
        item = Item(path)
        STATE["items"][path]["iface"] = item
        bus_export(item)
        LOG.append(("created", path))
        return [path, "/"]

    @method()
    def Delete(self) -> "o":
        return "/"


def matches(item, attributes) -> bool:
    return all(item["attributes"].get(k) == v for k, v in attributes.items())


class Item(ServiceInterface):
    def __init__(self, path: str):
        super().__init__("org.freedesktop.Secret.Item")
        self.path = path

    def _item(self):
        return STATE["items"][self.path]

    @dbus_property(access=PropertyAccess.READ)
    def Locked(self) -> "b":
        return False

    @dbus_property(access=PropertyAccess.READ)
    def Attributes(self) -> "a{ss}":
        return dict(self._item()["attributes"])

    @dbus_property(access=PropertyAccess.READ)
    def Label(self) -> "s":
        return self._item()["label"]

    @dbus_property(access=PropertyAccess.READ)
    def Created(self) -> "t":
        return self._item()["created"]

    @dbus_property(access=PropertyAccess.READ)
    def Modified(self) -> "t":
        return self._item()["modified"]

    @method()
    def GetSecret(self, session: "o") -> "(oayays)":
        if session not in STATE["sessions"]:
            raise DBusError("org.freedesktop.Secret.Error.NoSession", "unknown session")
        key = STATE["sessions"][session]
        LOG.append(("get", self.path))
        return secret_struct(session, key, self._item()["secret"])

    @method()
    def Delete(self) -> "o":
        item = STATE["items"].pop(self.path)
        bus_unexport(item["iface"])
        LOG.append(("deleted", self.path))
        return "/"


class Session(ServiceInterface):
    def __init__(self, path: str):
        super().__init__("org.freedesktop.Secret.Session")
        self.path = path

    @method()
    def Close(self):
        STATE["sessions"].pop(self.path, None)


class Prompt(ServiceInterface):
    def __init__(self, path: str, collection: Collection):
        super().__init__("org.freedesktop.Secret.Prompt")
        self.path = path
        self.collection = collection

    @method()
    def Prompt(self, window_id: "s"):
        LOG.append(("prompt", self.path))
        if MODE == "hang":
            return
        asyncio.get_running_loop().call_later(PROMPT_DELAY, self._finish)

    def _finish(self):
        if MODE == "dismiss":
            self.Completed(True, Variant("ao", []))
            return
        self.collection.set_locked(False)
        self.Completed(False, Variant("ao", [self.collection.path]))

    @method()
    def Dismiss(self):
        LOG.append(("dismissed", self.path))
        self.Completed(True, Variant("ao", []))

    @signal()
    def Completed(self, dismissed: "b", result: "v") -> "bv":
        return [dismissed, result]


class Service(ServiceInterface):
    def __init__(self):
        super().__init__("org.freedesktop.Secret.Service")

    @method()
    def OpenSession(self, algorithm: "s", input: "v") -> "vo":
        path = f"/org/freedesktop/secrets/session/{next_id()}"
        if algorithm == PLAIN_ALGORITHM:
            STATE["sessions"][path] = None
            session = Session(path)
            bus_export(session)
            return [Variant("s", ""), path]
        if algorithm != DH_ALGORITHM or MODE == "refuse-dh":
            raise DBusError("org.freedesktop.DBus.Error.NotSupported", f"algorithm {algorithm} refused")
        client_public = int.from_bytes(bytes(input.value), "big")
        if not (1 < client_public < P - 1):
            raise DBusError("org.freedesktop.DBus.Error.InvalidArgs", "client public key out of range")
        server_private = int.from_bytes(os.urandom(128), "big")
        server_public = pow(G, server_private, P)
        shared = pow(client_public, server_private, P).to_bytes(128, "big")
        STATE["sessions"][path] = hkdf16(shared)
        session = Session(path)
        bus_export(session)
        return [Variant("ay", int_bytes(server_public)), path]

    @method()
    def ReadAlias(self, name: "s") -> "o":
        if name != "default":
            return "/"
        return ALIAS_PATH if ALIAS_PATH in STATE["collections"] else "/"

    @method()
    def CreateCollection(self, properties: "a{sv}", alias: "s") -> "oo":
        label = properties["org.freedesktop.Secret.Collection.Label"].value
        collection = Collection(ALIAS_PATH, label, False)
        bus_export(collection)
        LOG.append(("collection", ALIAS_PATH))
        return [ALIAS_PATH, "/"]

    @method()
    def SearchItems(self, attributes: "a{ss}") -> "aoao":
        unlocked = [p for p, i in STATE["items"].items() if matches(i, attributes) and not STATE["collections"][i["collection"]].locked_flag]
        locked = [p for p, i in STATE["items"].items() if matches(i, attributes) and STATE["collections"][i["collection"]].locked_flag]
        return [unlocked, locked]

    @method()
    def Unlock(self, objects: "ao") -> "aoo":
        unlocked, prompt = [], "/"
        for obj in objects:
            col = STATE["collections"].get(obj)
            if col is None:
                continue
            if col.locked_flag:
                prompt = f"/org/freedesktop/secrets/prompt/{next_id()}"
                bus_export(Prompt(prompt, col))
            else:
                unlocked.append(obj)
        return [unlocked, prompt]

    @method()
    def Lock(self, objects: "ao") -> "aoo":
        return [[], "/"]

    @method()
    def GetSecrets(self, items: "ao", session: "o") -> "a{o(oayays)}":
        return {}


def bus_export(iface: ServiceInterface):
    BUS[0].export(iface.path if hasattr(iface, "path") else SERVICE_PATH, iface)


def bus_unexport(iface):
    BUS[0].unexport(iface.path)


BUS = [None]


async def main():
    address = sys.argv[1]
    bus = await MessageBus(bus_address=address).connect()
    BUS[0] = bus
    service = Service()
    bus.export(SERVICE_PATH, service)
    await bus.request_name("org.freedesktop.secrets")
    if MODE != "no-collection":
        collection = Collection(ALIAS_PATH, "Login", MODE in ("locked", "dismiss", "hang"))
        bus.export(ALIAS_PATH, collection)
    print("READY", flush=True)
    await asyncio.get_running_loop().create_future()


if __name__ == "__main__":
    asyncio.run(main())
