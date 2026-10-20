#!/usr/bin/env python3
"""Python consumer of the Bleu C ABI through ctypes, checked against the JSON path.

    python3 -I capi_ctypes.py <path/to/libbleu_capi.so> <fake-root>

The Structure classes mirror the generated headers (include/bleu/*.h); the JSON
text from bleu_*_snapshot_json must agree with the same values read through the
structs. Exit status 0 when every check passes.
"""

import ctypes as C
import json
import os
import sys
import threading

STATUS_OK, STATUS_INVALID_ARGUMENT, STATUS_NOT_FOUND = 0, 6, 5
STATUS_TIMEOUT, STATUS_CANCELLED, STATUS_UNSUPPORTED = 9, 10, 1
PHASE_SUCCEEDED = 2
BATTERY_BACKEND_SYSFS = 1
BRIGHTNESS_BACKEND_LINUX = 1
KIND_BATTERY = 2

failures = 0


def check(cond, what):
    global failures
    if not cond:
        failures += 1
        print("FAIL:", what, file=sys.stderr)


class Slice(C.Structure):
    _fields_ = [("ptr", C.c_void_p), ("len", C.c_size_t)]

    def text(self):
        return C.string_at(self.ptr, self.len).decode("utf-8") if self.len else ""


class MaybeLevel(C.Structure):
    _fields_ = [("value", C.c_float), ("has_value", C.c_bool)]


class MaybeFloat(C.Structure):
    _fields_ = [("value", C.c_float), ("has_value", C.c_bool)]


class MaybeUint(C.Structure):
    _fields_ = [("value", C.c_uint32), ("has_value", C.c_bool)]


class MaybeI64(C.Structure):
    _fields_ = [("value", C.c_int64), ("has_value", C.c_bool)]


class Availability(C.Structure):
    _fields_ = [("reason", C.c_uint8), ("note", Slice)]


class BatterySource(C.Structure):
    _fields_ = [
        ("id", Slice), ("kind", C.c_uint8), ("present", C.c_bool), ("state", C.c_uint8),
        ("charge", MaybeLevel), ("power", MaybeI64), ("time_to_empty", MaybeI64),
        ("time_to_full", MaybeI64), ("energy", MaybeI64), ("energy_full", MaybeI64),
        ("energy_design", MaybeI64), ("health", MaybeLevel), ("cycles", MaybeUint),
        ("temperature", MaybeFloat), ("chemistry", C.c_uint8),
        ("vendor", Slice), ("model", Slice), ("serial", Slice),
    ]


class BatteryState(C.Structure):
    _fields_ = [("on_mains", C.c_bool), ("sources", Slice), ("adapter_watts", MaybeUint),
                ("reading", Availability)]


class BatteryOptions(C.Structure):
    _fields_ = [("struct_size", C.c_uint32), ("backend", C.c_uint8), ("poll_ms", C.c_uint64),
                ("root", C.c_char_p)]


class BatteryEvent(C.Structure):
    _fields_ = [("kind", C.c_uint8), ("source_id", Slice)]


class BrightnessOptions(C.Structure):
    _fields_ = [("struct_size", C.c_uint32), ("backend", C.c_uint8), ("poll_ms", C.c_uint64),
                ("transition_step_ms", C.c_uint64), ("root", C.c_char_p), ("bus_address", C.c_char_p)]


class Policy(C.Structure):
    _fields_ = [("kind", C.c_uint8), ("mechanism", C.c_uint8)]


class SetRequest(C.Structure):
    _fields_ = [("struct_size", C.c_uint32), ("device", C.c_char_p), ("level", C.c_float),
                ("policy", Policy), ("transition_ms", C.c_uint64)]


class Applied(C.Structure):
    _fields_ = [("mechanism", C.c_uint8), ("requested", C.c_float), ("applied", C.c_float),
                ("raw", C.c_int64), ("read_back", MaybeLevel)]


class ErrorDetail(C.Structure):
    _fields_ = [("status", C.c_int32), ("domain", C.c_uint8), ("native_code", C.c_int32),
                ("message", C.c_char * 256)]


WATCH_CALLBACK = C.CFUNCTYPE(None, C.c_void_p, C.c_void_p)


def bind(lib):
    """Declare every signature used here, so ctypes never guesses an int return."""
    lib.bleu_abi_version.restype = C.c_uint32
    lib.bleu_status_name.restype = C.c_char_p
    lib.bleu_status_name.argtypes = [C.c_int32]
    lib.bleu_last_error.argtypes = [C.POINTER(ErrorDetail)]
    lib.bleu_free.argtypes = [C.c_void_p]
    lib.bleu_snapshot_release.argtypes = [C.c_void_p]
    lib.bleu_snapshot_json.argtypes = [C.c_void_p, C.POINTER(C.c_void_p), C.POINTER(C.c_size_t)]
    lib.bleu_operation_wait.argtypes = [C.c_void_p, C.c_int64]
    lib.bleu_operation_release.argtypes = [C.c_void_p]
    lib.bleu_battery_open.argtypes = [C.POINTER(BatteryOptions), C.POINTER(C.c_void_p)]
    lib.bleu_battery_close.argtypes = [C.c_void_p]
    lib.bleu_battery_wait.argtypes = [C.c_void_p, C.c_uint64, C.c_int64, C.POINTER(C.c_void_p)]
    lib.bleu_battery_snapshot_state.restype = C.POINTER(BatteryState)
    lib.bleu_battery_snapshot_state.argtypes = [C.c_void_p]
    lib.bleu_battery_source_at.restype = C.POINTER(BatterySource)
    lib.bleu_battery_source_at.argtypes = [C.POINTER(BatteryState), C.c_size_t]
    lib.bleu_battery_snapshot_json.argtypes = [C.c_void_p, C.POINTER(C.c_void_p), C.POINTER(C.c_size_t)]
    lib.bleu_battery_watch.argtypes = [C.c_void_p, WATCH_CALLBACK, C.c_void_p, C.POINTER(C.c_uint64)]
    lib.bleu_battery_unwatch.argtypes = [C.c_void_p, C.c_uint64]
    lib.bleu_battery_subscribe.argtypes = [C.c_void_p, C.POINTER(C.c_void_p)]
    lib.bleu_reader_next.argtypes = [C.c_void_p, C.c_int64, C.POINTER(C.c_void_p)]
    lib.bleu_reader_release.argtypes = [C.c_void_p]
    lib.bleu_packet_release.argtypes = [C.c_void_p]
    lib.bleu_battery_packet_event.restype = C.POINTER(BatteryEvent)
    lib.bleu_battery_packet_event.argtypes = [C.c_void_p]
    lib.bleu_brightness_open.argtypes = [C.POINTER(BrightnessOptions), C.POINTER(C.c_void_p)]
    lib.bleu_brightness_close.argtypes = [C.c_void_p]
    lib.bleu_brightness_set_level.argtypes = [C.c_void_p, C.POINTER(SetRequest), C.POINTER(C.c_void_p)]
    lib.bleu_brightness_set_result.restype = C.POINTER(Applied)
    lib.bleu_brightness_set_result.argtypes = [C.c_void_p]


def fail_text(lib, status):
    return "%s (%d)" % (lib.bleu_status_name(status).decode(), status)


def read_json(lib, handle):
    text = C.c_void_p()
    length = C.c_size_t()
    status = lib.bleu_battery_snapshot_json(handle, C.byref(text), C.byref(length))
    check(status == STATUS_OK, "snapshot_json status " + fail_text(lib, status))
    raw = C.string_at(text.value, length.value)
    check(C.string_at(text.value, length.value + 1)[-1:] == b"\0", "the buffer is NUL-terminated")
    lib.bleu_free(text)
    return json.loads(raw.decode("utf-8"))


def battery_checks(lib, root):
    options = BatteryOptions(struct_size=C.sizeof(BatteryOptions), backend=BATTERY_BACKEND_SYSFS,
                             poll_ms=50, root=root.encode())
    handle = C.c_void_p()
    check(lib.bleu_battery_open(C.byref(options), C.byref(handle)) == STATUS_OK, "battery open")
    if not handle.value:
        return

    snapshot = C.c_void_p()
    status = lib.bleu_battery_wait(handle, 0, 3000, C.byref(snapshot))
    check(status == STATUS_OK, "battery wait " + fail_text(lib, status))
    state = lib.bleu_battery_snapshot_state(snapshot).contents
    check(state.on_mains is True, "AC is online in the fake tree")
    check(state.sources.len == 2, "two sources")
    bat = lib.bleu_battery_source_at(C.byref(state), 1).contents
    check(bat.id.text() == "BAT0" and bat.kind == KIND_BATTERY, "BAT0 is a battery")
    check(bat.charge.has_value and abs(bat.charge.value - 0.5) < 0.01, "half charged")
    check(bat.cycles.has_value and bat.cycles.value == 212, "212 cycles")
    check(bat.serial.len == 0 and bat.vendor.text() == "ACME", "vendor through the slice")
    check(not lib.bleu_battery_source_at(C.byref(state), 2), "index past the end is NULL")

    # The JSON form must say the same as the struct.
    doc = read_json(lib, handle)
    check(doc["on_mains"] == state.on_mains, "JSON on_mains equals the struct")
    check(len(doc["sources"]) == state.sources.len, "JSON source count equals the struct")
    check(doc["sources"][1]["id"] == "BAT0", "JSON BAT0 equals the struct")
    check(abs(doc["sources"][1]["charge"] - bat.charge.value) < 1e-6, "JSON charge equals the struct")
    check(doc["sources"][1]["cycles"] == bat.cycles.value, "JSON cycles equals the struct")
    lib.bleu_snapshot_release(snapshot)

    # A listener from another thread; the callback sees AC being unplugged then plugged in.
    seen = threading.Event()
    ac = os.path.join(root, "sys/class/power_supply/AC/online")

    def on_state(context, snap):
        value = lib.bleu_battery_snapshot_state(snap)
        if value and value.contents.on_mains:
            seen.set()

    callback = WATCH_CALLBACK(on_state)
    with open(ac, "w") as f:
        f.write("0\n")
    threading.Event().wait(0.3)
    watch_id = C.c_uint64()
    check(lib.bleu_battery_watch(handle, callback, None, C.byref(watch_id)) == STATUS_OK, "watch")
    with open(ac, "w") as f:
        f.write("1\n")
    check(seen.wait(5.0), "the listener saw AC plugged in, from the worker thread")
    check(lib.bleu_battery_unwatch(handle, watch_id.value) == STATUS_OK, "unwatch")
    check(lib.bleu_battery_unwatch(handle, watch_id.value) == STATUS_NOT_FOUND, "second unwatch is NOT_FOUND")

    # Events: a reader and one packet.
    reader = C.c_void_p()
    check(lib.bleu_battery_subscribe(handle, C.byref(reader)) == STATUS_OK, "subscribe")
    with open(os.path.join(root, "sys/class/power_supply/BAT0/status"), "w") as f:
        f.write("Discharging\n")
    packet = C.c_void_p()
    status = lib.bleu_reader_next(reader, 3000, C.byref(packet))
    check(status == STATUS_OK, "an event after the status changed")
    if status == STATUS_OK:
        event = lib.bleu_battery_packet_event(packet).contents
        check(event.source_id.len > 0, "event names a source")
        lib.bleu_packet_release(packet)
    check(lib.bleu_reader_next(reader, 10, C.byref(packet)) == STATUS_TIMEOUT, "no more events: TIMEOUT")
    lib.bleu_reader_release(reader)
    check(lib.bleu_battery_close(handle) == STATUS_OK, "close after the reader is released")


def brightness_checks(lib, root):
    options = BrightnessOptions(struct_size=C.sizeof(BrightnessOptions), backend=BRIGHTNESS_BACKEND_LINUX,
                                poll_ms=100, transition_step_ms=50, root=root.encode(), bus_address=None)
    handle = C.c_void_p()
    check(lib.bleu_brightness_open(C.byref(options), C.byref(handle)) == STATUS_OK, "brightness open")
    if not handle.value:
        return
    request = SetRequest(struct_size=C.sizeof(SetRequest), device=b"intel_backlight", level=0.25)
    operation = C.c_void_p()
    check(lib.bleu_brightness_set_level(handle, C.byref(request), C.byref(operation)) == STATUS_OK, "set_level")
    check(lib.bleu_operation_wait(operation, 5000) == STATUS_OK, "operation waited to success")
    result = lib.bleu_brightness_set_result(operation)
    check(bool(result) and result.contents.raw == 24000, "a quarter of 96000 is written")
    with open(os.path.join(root, "sys/class/backlight/intel_backlight/brightness")) as f:
        check(f.read().strip() == "24000", "the file holds 24000")
    lib.bleu_operation_release(operation)
    lib.bleu_brightness_close(handle)


def error_checks(lib):
    detail = ErrorDetail()
    options = BatteryOptions(struct_size=C.sizeof(BatteryOptions), poll_ms=1 << 40)
    handle = C.c_void_p()
    status = lib.bleu_battery_open(C.byref(options), C.byref(handle))
    check(status == STATUS_INVALID_ARGUMENT, "a huge poll interval is refused")
    check(lib.bleu_last_error(C.byref(detail)) == STATUS_OK, "last error is readable")
    check(detail.status == STATUS_INVALID_ARGUMENT and b"poll_ms" in detail.message, "the message names poll_ms")
    check(not handle.value, "the handle is NULL after a refusal")
    options.poll_ms = 0
    options.backend = 4  # WIN32, not on Linux
    status = lib.bleu_battery_open(C.byref(options), C.byref(handle))
    check(status == STATUS_UNSUPPORTED, "the Windows backend is UNSUPPORTED here")
    check(lib.bleu_status_name(STATUS_CANCELLED) == b"CANCELLED", "status names")


def main():
    if len(sys.argv) != 3:
        print("usage: capi_ctypes.py <libbleu_capi.so> <fake-root>", file=sys.stderr)
        return 2
    lib = C.CDLL(sys.argv[1])
    bind(lib)
    check(lib.bleu_abi_version() == 1, "ABI version 1")
    with open(os.path.join(sys.argv[2], "sys/class/power_supply/BAT0/status"), "w") as f:
        f.write("Charging\n")
    error_checks(lib)
    battery_checks(lib, sys.argv[2])
    brightness_checks(lib, sys.argv[2])
    print("capi_ctypes: all checks passed" if failures == 0 else "capi_ctypes: %d check(s) failed" % failures)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
