# bleu_bluetooth

The Bluetooth service: controllers (adapters), devices, the operations on them, and
pairing prompts that a user answers. Module root `bleu::bluetooth`. Depends on
`bleu_core`, `bleu_rt`, `bleu_service`, `bleu_dbus`, `bleu_dl`, `bleu_objc`, `bleu_win`.
Design: `docs/ARCHITECTURE.md`; the research and the cut line: `docs/research/bluetooth.md`;
what was implemented, verified and deviated from: `docs/research/bluetooth_impl.md`.

**Status.** The Linux BlueZ backend is **run** against a python-dbus-next mock of
`org.bluez` (`tests/run.sh`, 56 checks, all passing). The macOS and Windows backends
are **type-checked only** (`tools/check.sh` on all six targets); nothing in them has run.

## Public API

`Bluetooth* bt = bluetooth::open(allocator, Options{ backend, bus_address, root, call_timeout, pairing_timeout })!`,
then `bt.close()`. A request waits for its reply at most `call_timeout` (default 25 s); a pairing,
user answers included, at most `pairing_timeout` (default 120 s). A timed-out pairing closes its
waiting prompts, so a late answer is refused with `INVALID_STATE`.

* State: `latest()`, `wait_after(seen, timeout)`, `watch`/`unwatch` (on the worker thread),
  `subscribe()` -> `Reader{Event}` for transients.
* `State` = `Adapter[]` (address, `Maybe{bool} powered` (unknown where the backend cannot read it), blocked, discoverable, pairable, discovering ...)
  and `Device[]` (address, adapter, display_name, icon, paired, bonded, connected, trusted,
  blocked, `Maybe{Dbm} rssi`, `Maybe{Level} battery`, `Maybe{PnpId} pnp`, uuids, `Profile[]`).
* Addresses must be `AA:BB:CC:DD:EE:FF` (or empty where the operation takes "the first controller"); any other text fails with `INVALID_ARGUMENT` at the call.
* Operations return `Task*?` (an `Operation{Done}`; `wait`, `failure`, `release()`):
  `set_powered`, `set_discoverable(adapter, on, timeout_s)`, `set_pairable`,
  `start_discovery(adapter, DiscoveryFilter)`, `stop_discovery`, `pair`, `cancel_pairing`,
  `reply_pairing(id, accept, secret)`, `connect`, `disconnect`, `connect_profile`,
  `disconnect_profile`, `set_trusted`, `set_blocked`, `rename`, `remove`, `refresh`.
* `capability(Cap)` says whether an operation works here, and why not; a refused operation
  fails at the call with `UNSUPPORTED` / `UNAVAILABLE` and never reaches the worker.
* Events (`Event`): `ADAPTER_*`, `DEVICE_ADDED/CHANGED/REMOVED`, `DEVICE_DISCONNECTED` (text =
  BlueZ's reason), `PAIRING_REQUEST` (`PairingRequest{id, device, kind, passkey}`),
  `PAIRING_ENDED`. Prompts are never answered by the library: `reply_pairing` carries the user's answer;
  an empty PIN is refused. A `PASSKEY_DISPLAY` prompt carries the code as BlueZ sent it in `Event.text`.
* Stopping or losing the backend completes every request still queued with `DISCONNECTED`; none is left pending.

## Coverage (capability x OS -> Run / Compiled-only / Not done)

Linux = BlueZ (`bluez`). macOS = IOBluetooth (`iobluetooth`). Windows = Win32 (`win32`).
"Run" means exercised by `tests/run.sh` against the mock; "Compiled-only" means type-checked
and the code path exists but is not asserted by a run; "Not done" means `UNSUPPORTED_*` and
the call refuses.

| Capability | Linux (BlueZ) | macOS (IOBluetooth) | Windows (Win32) |
| --- | --- | --- | --- |
| POWER | Run | Not done (private gate not built) | Not done (WinRT Radio) |
| DISCOVERABLE | Run | Not done (private gate not built) | Not done (not read) |
| PAIRABLE | Compiled-only | Not done | Not done (not read) |
| DISCOVERY (start/stop, filter) | Run | Not done (inquiry needs delegate) | Not done (not read) |
| PAIR | Run (agent; confirm, PIN, passkey) | Not done (delegate) | Not done (WinRT pairing) |
| CANCEL_PAIRING | Run | Not done | Not done |
| PAIRING_PROMPTS (events + reply) | Run | Not done | Not done |
| CONNECT / DISCONNECT | Run | Compiled-only | Not done (no Win32 call) |
| PROFILE_CONNECT | Run | Not done | Not done |
| PROFILE_DISCONNECT | Compiled-only | Not done | Not done |
| TRUST / BLOCK / RENAME | Run | Not done | Not done |
| REMOVE | Run | Not done (private `remove`) | Compiled-only (remembered only) |
| BATTERY | Run | Not done | Not done |
| RSSI | Compiled-only (asserted nowhere) | Compiled-only (`rawRSSI`) | Not done |
| SERVICE_UUIDS / profiles | Run | Not done | Not done |
| MODALIAS | Run | Not done | Not done |
| RFKILL_STATE (read only) | Run (sysfs fake tree) | Not done | Not done |
| Adapter/device list | Run | Compiled-only (paired devices only) | Compiled-only (radios + remembered) |
| Device events (added/changed/removed) | Compiled-only | Compiled-only (by poll) | Compiled-only (by poll) |
| Disconnect event with reason | Run | Not done | Not done |

## Not done

* **macOS:** controller power, discoverability and unpair (private `IOBluetoothPreference*` /
  `remove` selectors; the `*_private.c3` gate was not built), pairing and inquiry (need the
  IOBluetoothDevicePair / Inquiry delegates on a run loop), trust, block, rename, battery,
  per-profile, adapter list (no controller is reported).
* **Windows:** WinRT radio power (so `powered` is unknown), WinRT custom pairing
  (`PairingRequested`), inquiry, discoverable/pairable reads, connect/disconnect, per-profile
  service state, trust, block, rename, battery, RSSI, modalias.
* **Linux:** GATT, LE advertising, OBEX, PAN/DUN, AVRCP, wake-on-BT, component batteries,
  `ConnectDevice`/`GetServiceRecords` [exp]; no `/dev/rfkill` write; no reconnect after
  bluetoothd restarts (a lost bus publishes an empty state and ends the worker).
* Real hardware: nothing has been run against a real BlueZ, adapter or device.
* Not exercised by a run: BlueZ's `Release` and `Cancel` closing waiting prompts (the mock sends
  neither), a `DisplayPinCode` (the mock sends none), and a failing `GetManagedObjects` is only
  simulated by the mock's fault switch (`BLEU_MOCK_FAIL_TREE`). The Windows and macOS error paths
  (GetLastError for find functions, PIN wiping) are type-checked only.

## Verified how

* `tests/run.sh`: private dbus-daemon, `tests/mock_bluez.py` as `org.bluez`, a fake rfkill tree,
  and `tests/bluez_integration.c3`. Last run: 56 PASS, `ALL CHECKS PASSED`. The new completion
  checks (a short pairing timeout, an unanswered pairing and prompt, a late answer, a failed tree
  read) were run against the review commit 2f89765 and 6 of them failed there.
* `src/abandon_test.c3`: a hub whose backend returns while requests are queued; every request
  completes with `DISCONNECTED`.
* `src/classify_test.c3`: 7 `@test`s (class/appearance icons, battery, modalias, MAC and
  Windows address conversions): 66 of 66 library tests pass on Linux.
* `tools/check.sh bleu_core bleu_rt bleu_service bleu_dbus bleu_dl bleu_objc bleu_win bleu_bluetooth`: ok on all six targets.
