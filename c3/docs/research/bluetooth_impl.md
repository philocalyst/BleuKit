# Bluetooth service: implementation notes

Spec: `docs/research/bluetooth.md` (v1 cut, section 6). Library: `libs/bleu_bluetooth.c3l`.
Test: `libs/bleu_bluetooth.c3l/tests/run.sh` (Linux, against a mock). Shared libraries were
used as they are; `bleu_dbus` provided the server side needed for the BlueZ agent.

## What was built, against the cut

* **Linux, BlueZ (`bluez`)**: run against a python-dbus-next mock of `org.bluez`. Adapters,
  devices, Battery1, UUID to profile, modalias, power, discovery with filter, pair with a
  pairing agent (exported with `bleu::dbus` server, registered with AgentManager1,
  KeyboardDisplay), cancel, connect/disconnect (whole device and profile), trust, block,
  alias, remove, rfkill read (sysfs, `bluetooth` type, soft or hard) and the Disconnected
  signal as an event. The rfkill switch is only read, never written.
* **macOS (`iobluetooth`)**: paired devices, connect and disconnect (`openConnection`,
  `closeConnection`), `rawRSSI`. Type-checked only.
* **Windows (`win32`)**: radios (`BluetoothFindFirstRadio` and the rest), remembered
  devices (`BluetoothFindFirstDevice` with no inquiry), remove (`BluetoothRemoveDevice`).
  Type-checked only. All functions are bound at run time through `bleu::dl`, with both
  candidates `bluetoothapis.dll` and `bthprops.cpl`, in that order.

## Deviations from the research

1. **Pairing prompts are a `PairingRequest` event answered by `reply_pairing`.** The Linux
   agent parks each BlueZ request (`Call.defer_reply`). Max 8 waiting prompts; a request beyond
   that is refused with `org.bluez.Error.Rejected`.
2. **PIN is never supplied by the library.** An empty PIN is refused with `INVALID_ARGUMENT`
   and the prompt keeps waiting (tested). A passkey must be 1-6 decimal digits, at most 999999.
3. **DisplayPinCode and DisplayPasskey** are reported as `PASSKEY_DISPLAY` requests with id 0
   and no waiting prompt. Nothing answers them. (Research did not decide this.)
4. **`Options.private_api` removed.** The research's macOS private gate was not built; an
   option with no effect would be dead.
5. **`Operation` value is `Done`** (no result beyond success). Research said `Operation{Value}`;
   a `void` value is not expressible in C3 here.
6. **Command set is internal** (`Request` in `request.c3`). The public `Command` enum is the
   operation list only; the mailbox carries the operation pointer.
7. **Device `bonded` on macOS and Windows.** macOS does not report it (left false). Windows:
   `paired` = `fAuthenticated`, `bonded` = `fRemembered` (approximation, see below).
8. **Windows "powered"** is `true` for every enumerated radio. WinRT `Radio.State` is not read
   (not built). `discoverable`, `pairable`, `discovering` are reported `false` because they are
   not read. The Cap for power is `UNSUPPORTED_BACKEND`, so no caller can rely on it changing.
9. **probe.c3 replaced** by a `platform_drivers()` in each OS file (`linux.c3`, `macos.c3`,
   `windows.c3`), each `@feat`-gated. A `$if` chain in one file cannot select between three
   OS lists without a switch that 0.8.5 does not offer here.

## Verified, and how

* Linux: `tests/run.sh` against the mock on a private `dbus-daemon`: 46 checks PASS. Covers
  the adapter and device state, battery, icon, modalias, profiles, power, discovery,
  pair/confirm, PIN (typed PIN accepted, empty refused, PIN not sent before the user
  answers), passkey refusal, unknown prompt id, cancelled pairing, connect/refused connect,
  profile connect, disconnect with reason event, trust, block, alias, remove, rfkill read
  (soft set and cleared in sysfs), reply to a refused prompt.
* Mock findings that were the mock's fault, not the library's: dbus-next's built-in
  `ObjectManager` and `Properties` ignored undecorated properties, so the mock serves
  `GetManagedObjects`, `Get`, `GetAll` and `Set` through a message handler.
* Library findings fixed during the run: a reply queued while a synchronous call read the
  socket was never dispatched (the worker slept without processing); fixed by calling
  `process()` before sleeping and after commands. A temp-allocator string was used after its
  `@pool()` closed (the device address of a prompt); fixed by copying into the prompt slot.
* Pure conversions, `classify_test.c3`: 7 tests, passing on Linux.
* Type-check on all six targets via `tools/check.sh` with the other Bluetooth dependencies.

## Doubts and unverified facts

* **Appearance categories** (`classify.c3`, `icon_from_appearance`): taken from memory of the
  GAP Assigned Numbers, not fetched. Marked "not verified" in the code. Class-of-device
  decoding is the research's single source (C18, upper-layer decoder).
* **BlueZ behaviour on a real host** (agent registration without a seat, default-agent
  policy, the D-Bus policy for RegisterAgent, `PowerState` values): unverified. The mock
  implements what the research says, not measured BlueZ.
* **Pair without an agent**: if RegisterAgent fails at run time, `agent_ready` stays false,
  prompts are not delivered, and BlueZ decides the pairing alone. The capability still reads
  DEGRADED, not UNAVAILABLE, because the failure is only known once the worker runs.
* **macOS** `openConnection` and `closeConnection` return `IOReturn`; read with `send(int, ...)`.
  The `IOBluetoothDevice` selectors were taken from the research symbol list (C21), not from
  a header. `deviceWithAddressString:` expects dashes in lower case.
* **Windows struct sizes** (`windows_backend.c3`): 4, 520, 40, 560 bytes, from the layouts in
  windows-sys and the Learn remarks. `$sizeof`/`.sizeof` do not exist in this C3 version, so
  they are constants; no compile-time check ties them to the struct layout.
* **Windows library name**: both candidates are tried at run time; which one is right on a real
  Windows host was not checked (UNVERIFIED, research section 4).
* **Bus loss on Linux**: a lost bus publishes an empty state and ends the worker. There is no
  reconnect after a bluetoothd restart.
