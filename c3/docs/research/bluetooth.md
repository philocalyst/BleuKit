# Bluetooth service research spike

Scope: the `bluetooth` service as a desktop panel needs it (adapters, power,
discovery, devices, pair/agent, connect/profiles, trust/block/remove/alias,
events, device battery). GATT is a cut line. Spike date 2026-10-20.

Method. Every source was fetched or cloned during this spike. Pinned revisions
are given where the clone had a commit; other raw URLs were fetched on the date
above and are not pinned. Source keys (`[BZ-ADP]`, `[DMS]` ...) are defined in
section 3. Claim IDs (`[C7]`) in section 2 are verified in section 4.
Tags: `(single-source)` and `(UNVERIFIED)` as the template requires.

## 1. What a shell needs

Priority order (P0 = panel is useless without it).

* P0 Adapter list; power on/off, and the rfkill-blocked state shown as its own state.
* P0 Discovery start/stop; discoverable and pairable toggles with timeouts.
* P0 Device list: address, name/alias, icon/class/appearance, paired, bonded,
  connected, trusted, blocked, RSSI while seen.
* P0 Pair with an agent: PIN entry, PIN display, passkey display, passkey entry,
  numeric confirm, authorize (just-works), cancel.
* P0 Connect and disconnect the whole device.
* P1 Per-profile connect/disconnect. Audio hints: A2DP sink/source, HFP AG/HS,
  HSP. Profile UUIDs are needed; BlueZ does not report a per-profile connected
  state (only device-level `Connected`) `[C11]`.
* P1 Trust, block, remove (forget), rename (alias).
* P1 Events: adapter and device property changes, device added/removed, pairing
  prompts, disconnect reason.
* P1 Device battery percent (Battery1). Linux only has a documented source `[C12]`.
* P2 Modalias vendor/product, appearance, TxPower, service UUIDs, component
  batteries (left/right/case, experimental) `[C13]`.
* Cut lines: GATT and LE advertising, OBEX, PAN/DUN tethering, AVRCP media
  endpoints, BR/EDR-to-LE bearer preferences, wake-on-BT, SDP raw records.

## 2. Per-platform native route (Linux / macOS / Windows)

### 2.1 Linux (preferred route: BlueZ D-Bus)

Route L1 (the only route to implement fully). BlueZ on `org.bluez`, used through
`bleu_dbus`. Objects are discovered via `org.freedesktop.DBus.ObjectManager` at
`/`. Names and signatures come from the BlueZ master docs `[BZ-ADP]`, `[BZ-DEV]`,
`[BZ-AGT]`, `[BZ-AGM]`, `[BZ-BAT]`, `[BZ-BP]`, `[BZ-PM]`. Experimental
members are marked `[exp]`.

Interfaces:

* `/org/bluez` `org.bluez.AgentManager1`: `RegisterAgent(o agent, s capability)`,
  `UnregisterAgent(o)`, `RequestDefaultAgent(o)` `[BZ-AGM]` L171-232.
  Capabilities: `""` (means KeyboardDisplay), `DisplayOnly`, `DisplayYesNo`,
  `KeyboardOnly`, `NoInputNoOutput`, `KeyboardDisplay` `[BZ-AGM]` L190-200 `[C6]`.
* `/org/bluez/hciN` `org.bluez.Adapter1`: methods `StartDiscovery()`,
  `StopDiscovery()`, `RemoveDevice(o device)`, `SetDiscoveryFilter(a{sv} filter)`,
  `GetDiscoveryFilters() -> as`, `ConnectDevice(a{sv}) -> o [exp]`. Properties:
  `Powered b rw`, `PowerState s ro [exp]` (`on`, `off`, `off-enabling`,
  `on-disabling`, `off-blocked`) `[C1]`, `Discoverable b rw`,
  `DiscoverableTimeout u rw` (default 180, 0 = never times out) `[C3]`,
  `Pairable b rw` (default true), `PairableTimeout u rw` (default 0),
  `Discovering b ro`, `Connectable b rw`, `Alias s rw`, `Class u ro`,
  `Address s`, `Name s`, `UUIDs as`, `Modalias s (opt)`, `Roles as`,
  `Manufacturer q`, `Version y`. `[BZ-ADP]` L25-467.
* `/org/bluez/hciN/dev_AA_BB_CC_DD_EE_FF` `org.bluez.Device1`: methods
  `Connect()`, `Disconnect()`, `ConnectProfile(s uuid)`,
  `DisconnectProfile(s uuid)`, `Pair()`, `CancelPairing()`,
  `GetServiceRecords() -> aay [exp, compat only]` `[BZ-DEV]` L25-173.
  Properties: `Address s` (ro), `AddressType s` (`public`|`random`), `Name s`
  (opt, ro), `Alias s rw` (empty string resets to Name), `Icon s` (opt,
  freedesktop icon name), `Class u` (opt), `Appearance q` (opt), `UUIDs as`
  (opt), `Paired b`, `Bonded b`, `Connected b`, `Trusted b rw`, `Blocked b rw`,
  `WakeAllowed b rw`, `Adapter o`, `LegacyPairing b`, `CablePairing b`,
  `Modalias s` (opt), `RSSI n` (opt), `TxPower n` (opt), `Connectable b` (opt),
  `ManufacturerData` and `ServiceData` (opt; dict types inferred from the doc
  text as `a{qay}` and `a{say}`, UNVERIFIED), `ServicesResolved b`,
  `AdvertisingFlags ay`, `AdvertisingData a{yay}`, `PreferredBearer s rw [exp]`,
  `SecurityLevel y [exp]`, `EncryptionType y [exp]`. Signal
  `Disconnected(s reason, s message)`, reasons `org.bluez.Reason.{Unknown,Timeout,Local,Remote,Authentication,Suspend}` `[BZ-DEV]` L178-227.
* `<device path>` `org.bluez.Battery1` (`[BZ-BAT]` L238-286): `Percentage y`
  (opt; absent while unknown) `[C12]`, `Source s` (opt, informational, e.g.
  "HFP 1.7"). Child battery objects `<device>/battery_{id}` (experimental) add
  `Device o`, `Identifier s` (e.g. `left`, `right`, `case`), `Charging b` `[C13]`.
* Agent (we export `org.bluez.Agent1` at a path we choose): `Release()`,
  `RequestPinCode(o) -> s` (1-16 chars), `DisplayPinCode(o, s)` (always 6
  digits, zero-padded), `RequestPasskey(o) -> u` (0-999999), `DisplayPasskey(o, u passkey, q entered)`,
  `RequestConfirmation(o, u passkey)` (empty reply = accept), `RequestAuthorization(o)`,
  `AuthorizeService(o, s uuid)`, `Cancel()`. Errors `org.bluez.Error.Rejected`,
  `org.bluez.Error.Canceled` `[BZ-AGT]` L24-146 `[C7]` `[C9]`.
* `/org/bluez` `org.bluez.ProfileManager1` (`RegisterProfile(o, s uuid, a{sv})`),
  only needed when we act as a profile server. Cut line for a panel `[BZ-PM]`.

Call sequence, happy path:

1. Connect to the system bus. Call `GetManagedObjects` on object `/` to build
   adapters and devices. Subscribe to `InterfacesAdded`, `InterfacesRemoved`
   (ObjectManager) and `PropertiesChanged` (Properties), sender `org.bluez`.
   Also watch `NameOwnerChanged` for `org.bluez` restarts. `[DMS]` manager.go:26-31, 103, 218.
2. Power on: `Set(org.bluez.Adapter1, Powered, true)` `[C20]`. If `PowerState` is
   `off-blocked`, the radio is rfkill-blocked. Report `Blocked` and do not try to
   clear it silently. Quickshell refuses to enable a blocked adapter `[QS]` adapter.cpp:53-58 `[C1]`.
3. Discovery: optionally `SetDiscoveryFilter({Transport: "auto"|"le"|"bredr", DuplicateData, Pattern, ...})`,
   then `StartDiscovery()`. Each caller holds one session; `StopDiscovery()`
   releases only that session `[BZ-ADP]` L25-62 `[C2]`. Use a
   `Set(Discoverable=true)` with a `DiscoverableTimeout` (default 180 s) `[C3]`.
4. Pair: export `Agent1` at path P, then `RegisterAgent(P, "KeyboardDisplay")`,
   then `RequestDefaultAgent(P)` if the panel should own prompts. Call
   `Device1.Pair()`, which blocks until pairing and service discovery finish `[C4]`.
   Answer `Agent1` calls by returning from them. On user cancel or when the
   caller's future is dropped, call `Device1.CancelPairing()` `[C5]`. Finish with
   `UnregisterAgent(P)` and unexport.
5. Connect: `Connect()` connects every auto-connectable profile `[C10]`.
   `ConnectProfile(uuid)` connects one profile. `Disconnect()` tears down the ACL
   link even when profiles fail `[BZ-DEV]` L62-65.
   `DisconnectProfile(uuid)` is documented as needing a registered client
   profile `[C11]`.
6. Trust, block, alias: `Set(org.bluez.Device1, Trusted|Blocked|Alias, ...)` `[C20]`.
7. Remove: call `Adapter1.RemoveDevice(device path)` on the device's own
   `Adapter` property `[BZ-ADP]` L64-77. DMS derives the adapter path by
   splitting the string instead `[DMS]` manager.go:831-837.
8. Battery: read `Battery1.Percentage` on the device path. Watch `PropertiesChanged`
   on `org.bluez.Battery1`, and `InterfacesAdded` for child batteries `[C12]` `[C13]`.
9. Stop: `StopDiscovery()` for sessions we opened, `UnregisterAgent`, remove matches.

Data layouts and constants:

* Address: `Device1.Address` string `AA:BB:CC:DD:EE:FF`. The object path uses
  `dev_AA_BB_CC_DD_EE_FF` `[BZ-DEV]` L19.
* Battery: `y` 0-100. The value 255 (`UINT8_MAX`) means unknown, and the
  property is then not exported `[BZ-SRC]` battery.c:110, 152-157 `[C12]`.
* Modalias: `bt_modalias(source, vendor, product, version)`. Source `0x0001`
  gives `"bluetooth:v%04Xp%04Xd%04X"`, source `0x0002` gives `"usb:v%04Xp%04Xd%04X"`
  `[BZ-SRC]` uuid-helper.c:34-41; called from `btd_device_set_pnpid`
  (device.c:8355-8356) `[C14]`.
* Class of device (24 bit). Major class is `(cod & 0x1f00) >> 8`, minor is
  `(cod & 0xfc) >> 2`. This is the bluetooth-classic decoder, which cites upower
  (`[BTC]` api/bluetooth/device.go:186-197) `(single-source)` `[C18]`.
* Profile UUIDs (base `0000XXXX-0000-1000-8000-00805f9b34fb`): A2DP source
  `0x110A`, A2DP sink `0x110B`, AVRCP `0x110C`/`0x110E`/`0x110F`, HSP HS `0x1108`,
  HSP AG `0x1112`, HFP HS `0x111E`, HFP AG `0x111F`, PnP Information `0x1200`
  `[BZ-PM]` L35-60; `[BTC]` api/bluetooth/services.go:13-71 `[C19]`.
* rfkill event (kernel uapi, 8 bytes): `u32 idx @0; u8 type @4; u8 op @5; u8 soft @6; u8 hard @7`.
  `type`: ALL 0, WLAN 1, BLUETOOTH 2. `op`: ADD 0, DEL 1, CHANGE 2, CHANGE_ALL 3
  `[KRF-H]` L44-46, L66-69, L93-98 `[C15]`.

Permissions:

* Calls in the sequence above need no polkit action in the default BlueZ policy
  `(UNVERIFIED)`: the D-Bus policy file was not read.
* `RegisterAgent` is reachable by any system-bus client `(UNVERIFIED)` (same reason).
* `/dev/rfkill`: on this container (systemd 255.4) the rule
  `KERNEL=="rfkill", SUBSYSTEM=="misc", TAG+="uaccess"` gives the active local
  session write access `[SD-UA]` 70-uaccess.rules:84-85 `(single-source)` `[C17]`.
  The upstream systemd rule file was not reachable, so other distros are `(UNVERIFIED)`.

Pitfalls:

* `Pair()` fails if there is no agent and no default agent `[BZ-DEV]` L117-124.
* Agent `Cancel()` means "the request failed before a reply". DMS only logs it
  and keeps its prompt open (`[DMS]` agent.go:237-240). A panel must dismiss
  its prompt on `Cancel()` `[C7]`.
* Passkey display: BlueZ may call `DisplayPasskey` repeatedly with a growing
  `entered`, and the passkey string must be zero-padded to 6 digits
  `[BZ-AGT]` L95-99 `[C8]` `[C9]`. DMS shows only when `entered == 0`
  (agent.go:171) and does not pad (agent.go:172-173). Do not copy DMS here.
* Fixed credentials: bluetooth-classic answers `RequestPinCode` with `"0000"`
  and `RequestPasskey` with `1024` without asking the user (`[BTC]` agent.go:31-32, 93-100)
  `(single-source)`. Do not copy.
* `SetDiscoveryFilter` can create Device objects for non-discoverable devices
  `[BZ-ADP]` L166-169. Filter by `Connectable`, `RSSI`, or a pattern in the panel.
* `Powered` is not persistent across restarts `[BZ-ADP]` L333-334.
  `Discoverable` cannot be set while the adapter is off `[BZ-ADP]` L378-380.
* `Alias` vs `Name`: display `Alias`, fall back to `Name` `[BZ-DEV]` L261-265, L342-352.
* Experimental members (`PowerState`, `ConnectDevice`, `GetServiceRecords`,
  `PreferredBearer`, `Sets`, `SecurityLevel`, component batteries) must be probed,
  not assumed. Quickshell binds `PowerState` `[QS]` adapter.hpp:162.
* Quickshell scales `Battery1.Percentage` to 0.0-1.0 `[QS]` device.cpp:301-302.
  The API doc says percent, so keep percent and convert in the view.

Private or undocumented on Linux: none required for the scope above.

Route L2 (fallback only): `/dev/rfkill`. DMS writes an 8-byte `rfkill_event`
(type 2 = BLUETOOTH, op 3 = CHANGE_ALL, soft 0) before `Powered=true`, which clears
soft blocks for all Bluetooth radios and ignores hard blocks `[DMS]`
rfkill_linux.go:7-17 `[C15]`. The kernel write path has no `CAP_NET_ADMIN` check,
unlike sysfs `soft_store`, which does `[KRF-C]` core.c:1283-1330 vs core.c:769 `[C16]`.
Recommendation: surface `off-blocked` and do not write `/dev/rfkill` from the
library by default.

### 2.2 macOS

Route M1 (public, preferred for classic Bluetooth): `IOBluetooth` (Obj-C, `@import IOBluetooth`).
The Apple symbol list confirms these selectors `[AP-IOB]` `[C21]`.

* Listing: `+[IOBluetoothDevice pairedDevices]` (`[BLUEUTIL]` blueutil.m:919),
  `+recentDevices:` (1117), `+favoriteDevices` (1054).
  `+deviceWithAddressString:` (493).
* Per device: `-addressString` (533), `-name` (541), `-isConnected` (534),
  `-isPaired` (540), `-isFavorite`, `-rawRSSI` (535), `-RSSI` (560, `char`).
  `-getServiceRecord(for:)` exists (SDP records) but was not used by blueutil.
* Connect: `-openConnection` (1165) creates a baseband connection.
  `-closeConnection` (1196) tears it down. Watch disconnect with
  `-registerForDisconnectNotification:selector:` (1194).
* Pair: `+[IOBluetoothDevicePair pairWithDevice:]` (1260), `-setDelegate:`,
  `-start` (1265) and `-stop` (1270). `-stop` removes the delegate and
  disconnects `[AP-IOB]` pair JSON `[C22]`. Delegate methods (see blueutil.m:726-803):
  `devicePairingFinished:error:` (740), `devicePairingPINCodeRequest:` (745),
  `devicePairingUserConfirmationRequest:numericValue:` (775),
  `devicePairingUserPasskeyNotification:passkey:` (797). Replies:
  `replyPINCode:PINCode:` (772, up to 16 bytes) and `replyUserConfirmation:` (787-792).
* Discovery: `+[IOBluetoothDeviceInquiry inquiryWithDelegate:]` (1083), `-start`
  (1085), `-stop` (1091), `-foundDevices` (1096). Delegate `deviceInquiryComplete:error:aborted:` (649).
  blueutil notes that the inquiry length is ignored from Monterey (1087) `[C23]`.
  Inquiry is a bounded run, not a session. "Discovering" must be synthesized.
* Power state (public, read only): `+[IOBluetoothHostController defaultController]`
  and `-powerState` `[AP-IOB]` hostcontroller JSON. No public setter appears in
  the symbol list `[C24]`.

Route M2 (private, observed in blueutil, must be gated per ARCHITECTURE):
`IOBluetoothPreferencesAvailable()`, `IOBluetoothPreferenceGetControllerPowerState()`,
`IOBluetoothPreferenceSetControllerPowerState(int)`,
`IOBluetoothPreferenceGetDiscoverableState()`,
`IOBluetoothPreferenceSetDiscoverableState(int)` (blueutil.m:46-52, 185-193).
blueutil sets then polls the getter 101 times at 100 ms, giving up after about
10 s (167-181) `(single-source)` `[C25]`. The same routine handles power and
discoverable state.

Unpair (experimental): `[device performSelector:@selector(remove)]` (blueutil.m:1292-1298),
flagged EXPERIMENTAL in the usage text (239) `(single-source)` `[C26]`.

Route M3 (CLI fallback only): run `blueutil --format json` (blueutil.m:570-610),
which prints `address`, `name`, `recentAccessDate`, `favourite`, `paired`,
`connected`, `slave`, `RSSI`, `rawRSSI`. Pairing from the CLI reads a PIN from
stdin (759-770) or uses `--pair ID [PIN]`, which is not usable from a GUI
panel. Exit codes are sysexits (288-297). blueutil refuses root unless
`BLUEUTIL_ALLOW_ROOT=1` (925-931).

Battery (macOS): blueutil reads `system_profiler SPBluetoothDataType -xml` for
device lists and never reads battery `(single-source)` (blueutil.m:412-476) `[C30]`.
Battery keys (`BatteryPercentCase`, `BatteryPercentLeft`, IORegistry
`AppleDeviceManagementHIDEventService` `BatteryPercent`) are leads from the brief
and were not verified against any source `(UNVERIFIED)` `[C31]`.

Route M4 (private, unexamined): `BluetoothManager.framework` (`BluetoothManager`,
`BluetoothDevice`, `setPowered:`, `setConnectable`). No source was read
`(UNVERIFIED)` `[C32]`. Treat as a lead only.

Route M5 (BLE only, cut line): CoreBluetooth `CBCentralManager`, public from
macOS 10.7 `[AP-CB]`. It is the wrong API for classic pairing and profiles.

Permissions:

* TCC: without Bluetooth permission the process is aborted (SIGABRT), and blueutil
  maps that to "System Settings > Privacy & Security > Bluetooth" (blueutil.m:304-310) `(single-source)` `[C29]`.
* CoreBluetooth apps need `NSBluetoothAlwaysUsageDescription` in `Info.plist`.
  The Apple doc text is written for iOS 13+ and says the app crashes without it
  `[AP-CB]` `(single-source for macOS)` `[C29]`.
* Sandbox entitlement for Bluetooth: `(UNVERIFIED)`, not in any source read.

Pitfalls:

* No public API for trust, block, rename (alias), modalias, per-profile
  connect, or battery. blueutil has none of these, and the Apple class symbol
  lists fetched do not show them `(single-source)` `[C21]`.
* Apple's JSON gives no per-member availability or deprecation data for these
  selectors. Version gating is `(UNVERIFIED)`. blueutil says favourites and
  recent devices are not stored and return empty from macOS 12 (blueutil.m:228-243, 268) `(single-source)` `[C27]`.
* RSSI is a signed `char`. The value 127 means unreadable, and 0 means
  "in the golden range" (blueutil.m:24, 1425; Apple `rssi()` abstract) `[C28]`.
* Power set is asynchronous in effect and can take up to about 10 s to verify (blueutil.m:167-181) `[C25]`.
* Do not run as root (blueutil.m:925-931).

### 2.3 Windows

Route W1 (Win32 classic, `bluetoothapis.h` with `Bthprops.lib`). Signatures
come from windows-sys 0.61.2 `[WIN-SYS]` and the Learn remarks `[LEARN]`.

* Radios: `BluetoothFindFirstRadio(const BLUETOOTH_FIND_RADIO_PARAMS*, HANDLE*) -> HBLUETOOTH_RADIO_FIND`
  (mod.rs:10); `BluetoothFindNextRadio`, `BluetoothFindRadioClose`, and
  `CloseHandle` for the radio handle `[LEARN]` FindFirstRadio.
  `BluetoothGetRadioInfo(HANDLE, BLUETOOTH_RADIO_INFO*)` (mod.rs:28; fields at
  340-347: `dwSize`, `address`, `szName[248]`, `ulClassofDevice`, `lmpSubversion`, `manufacturer`).
  Discoverable: `BluetoothEnableDiscovery(HANDLE, BOOL)` (mod.rs:5). Connectable:
  `BluetoothEnableIncomingConnections(HANDLE, BOOL)` (mod.rs:6),
  `BluetoothIsConnectable(HANDLE)` (mod.rs:29).
* Devices: `BluetoothFindFirstDevice(const BLUETOOTH_DEVICE_SEARCH_PARAMS*, BLUETOOTH_DEVICE_INFO*)`
  (mod.rs:9). Search params: `fReturnAuthenticated`, `fReturnRemembered`,
  `fReturnUnknown`, `fReturnConnected`, `fIssueInquiry`, `cTimeoutMultiplier`, `hRadio` (mod.rs:225-233).
  `BluetoothGetDeviceInfo(HANDLE, BLUETOOTH_DEVICE_INFO*)` (mod.rs:27).
  `BLUETOOTH_DEVICE_INFO` (mod.rs:206-216): `dwSize`, `Address` (u64 union with `rgBytes[6]`),
  `ulClassofDevice`, `fConnected`, `fRemembered`, `fAuthenticated`, `stLastSeen`,
  `stLastUsed`, `szName[248]` `(single-source)` `[C34]`. There is no trusted,
  blocked, battery, RSSI, or UUID field.
* Installed services: `BluetoothEnumerateInstalledServices(HANDLE, const BLUETOOTH_DEVICE_INFO*, u32*, GUID*)` (mod.rs:7).
  `BluetoothSetServiceState(HANDLE, const BLUETOOTH_DEVICE_INFO*, const GUID*, u32)`
  (mod.rs:45), flags `BLUETOOTH_SERVICE_ENABLE` = 1 and `DISABLE` = 0 (mod.rs:377-378).
  Learn: enabling installs the service driver and disabling removes it `[C39]`.
  This is not a connection. It is the closest Win32 analogue to per-profile enable.
* Pair (Win32 UI path): `BluetoothAuthenticateDeviceEx(HWND, HANDLE, BLUETOOTH_DEVICE_INFO* inout, const BLUETOOTH_OOB_DATA_INFO*, AUTHENTICATION_REQUIREMENTS)`
  (mod.rs:2). A NULL OOB pointer shows the Windows wizard `[LEARN]` AuthenticateDeviceEx `[C35]`.
* Pair (own UI, callback path): `BluetoothRegisterForAuthenticationEx(const BLUETOOTH_DEVICE_INFO*, isize*, PFN_AUTHENTICATION_CALLBACK_EX, void*)`
  (mod.rs:33). The callback gets `BLUETOOTH_AUTHENTICATION_CALLBACK_PARAMS`
  (mod.rs:163-169: `deviceInfo`, `authenticationMethod`, `ioCapability`,
  `authenticationRequirements`, union). Reply with `BluetoothSendAuthenticationResponseEx(HANDLE, const BLUETOOTH_AUTHENTICATE_RESPONSE*)`
  (mod.rs:43). Unregister with `BluetoothUnregisterAuthentication(isize)` (mod.rs:46).
  Learn: only the first registered callback fires `[LEARN]` RegisterForAuthenticationEx `[C36]`.
  Method values: LEGACY 1, OOB 2, NUMERIC_COMPARISON 3, PASSKEY_NOTIFICATION 4,
  PASSKEY 5 (mod.rs:186-191). IO capability: DISPLAYONLY 0, DISPLAYYESNO 1,
  KEYBOARDONLY 2, NOINPUTNOOUTPUT 3, UNDEFINED 255 (mod.rs:276-281) `(single-source)` `[C37]`.
* Remove: `BluetoothRemoveDevice(const BLUETOOTH_ADDRESS*)` (mod.rs:34). It fails
  for a device that is not remembered `[LEARN]` RemoveDevice `[C38]`.
* `BluetoothUpdateDeviceRecord(const BLUETOOTH_DEVICE_INFO*)` (mod.rs:47): semantics not read `(UNVERIFIED)`.
* Cancel pairing: no Win32 cancel was found in the pages read `(UNVERIFIED)`.
* Trusted: Windows has no trust concept. bluetooth-classic treats trusted as
  "paired" and blocked as false (`[BTC]` api/bluetooth/device.go:136-144) `(single-source)` `[C43]`.

Route W2 (WinRT, `Windows.Devices.Bluetooth` + `Windows.Devices.Enumeration` + `Windows.Devices.Radios`):

* Radio power: `Radio.GetRadiosAsync`, `Radio.SetStateAsync` (on/off), `StateChanged`.
  Learn: "use SetStateAsync to turn radios on or off programmatically" `[LEARN]` Radio `[C41]`.
* Classic device by address: `BluetoothDevice.FromBluetoothAddressAsync(unsigned long long)` `[LEARN]` `[C42]`.
* Pairing: `DeviceInformation.Custom` returns `DeviceInformationCustomPairing`.
  `PairAsync(DevicePairingKinds, DevicePairingProtectionLevel[, IDevicePairingSettings])`
  and `PairingRequested`. Event args `DevicePairingRequestedEventArgs` expose
  `DeviceInformation`, `PairingKind`, `Pin`, and `Accept()`, `Accept(String)`,
  `AcceptWithPasswordCredential(...)` `[LEARN]` `[C40]`.
  `DevicePairingKinds` (flags): None 0, ConfirmOnly 1, DisplayPin 2, ProvidePin 4,
  ConfirmPinMatch 8, ProvidePasswordCredential 16 `[LEARN]` `(single-source)` `[C40]`.
* Battery: `(UNVERIFIED)`. The DEVPKEY pages the brief named returned 404, and
  the GUID `{104EA319-6EE2-4701-BD47-8DDBF425BBE5}` does not appear in windows-sys.
* Apartment and threading rules for WinRT calls: `(UNVERIFIED)`, not read.

### 2.4 Feature matrix (what each OS can back)

| Feature | Linux (BlueZ) | macOS | Windows |
| --- | --- | --- | --- |
| Adapter list | ObjectManager, `Adapter1` | `defaultController` only (single controller, read only) | `BluetoothFindFirstRadio` (multi-radio) |
| Power on/off | `Adapter1.Powered`; `PowerState` shows `off-blocked` | private `IOBluetoothPreferenceSetControllerPowerState` (M2) | `Radio.SetStateAsync` (WinRT) |
| Discoverable (+timeout) | `Discoverable`, `DiscoverableTimeout` | private prefs (M2) | `BluetoothEnableDiscovery` |
| Pairable | `Pairable`, `PairableTimeout` | UNSUPPORTED (no source) | UNSUPPORTED (`BluetoothEnableIncomingConnections` is connectability; not confirmed as pairability, UNVERIFIED) |
| Discovery start/stop | `StartDiscovery` / `StopDiscovery`, shared sessions | inquiry start/stop, bounded run | `BluetoothFindFirstDevice` with `fIssueInquiry` (UNVERIFIED); WinRT `DeviceWatcher` (not read) |
| Device list | `Device1` via ObjectManager | `pairedDevices`, `recentDevices:`, `favoriteDevices` (recent/favourites empty from macOS 12) | `BluetoothFindFirstDevice` (remembered + unknown) |
| Paired / connected | `Paired`, `Connected` | `isPaired`, `isConnected` | `fRemembered`, `fConnected`, `fAuthenticated` |
| Trusted | `Trusted` (rw) | UNSUPPORTED | UNSUPPORTED (paired is treated as trusted) |
| Blocked | `Blocked` (rw) | UNSUPPORTED | UNSUPPORTED |
| Remove / forget | `Adapter1.RemoveDevice` | private selector `remove` (EXPERIMENTAL) | `BluetoothRemoveDevice` (remembered only) |
| Rename (alias) | `Device1.Alias` (rw) | UNSUPPORTED | UNSUPPORTED |
| Pair with agent | `Device1.Pair` + `Agent1` | `IOBluetoothDevicePair` + delegate | `BluetoothAuthenticateDeviceEx` + callback; or WinRT `DeviceInformationCustomPairing` |
| PIN / passkey / confirm | `Agent1` methods | delegate callbacks; PIN up to 16 chars | callback method enum; WinRT `DevicePairingKinds` |
| Connect / disconnect (device) | `Connect` / `Disconnect` | `openConnection` / `closeConnection` | UNSUPPORTED (no Win32 connect call) |
| Per-profile | `ConnectProfile` / `DisconnectProfile(uuid)` | UNSUPPORTED | `BluetoothSetServiceState` (enables driver, not a connection) |
| Battery % | `Battery1.Percentage` | UNVERIFIED (private/system_profiler leads) | UNVERIFIED |
| RSSI | `RSSI` (while advertising/inquiring) | `rawRSSI` / `RSSI` (connected; 127 = unreadable) | no field in `BLUETOOTH_DEVICE_INFO` |
| Service UUIDs | `UUIDs` | `getServiceRecord(for:)` (SDP) | `BluetoothEnumerateInstalledServices` (installed only) |
| Modalias / vendor | `Modalias` | UNSUPPORTED | UNSUPPORTED |
| Events | `PropertiesChanged`, `InterfacesAdded/Removed`, `Disconnected` | delegates, disconnect/connect notifications | auth callback; WinRT events |

## 3. Reference implementations (prove it works)

Read status: "read code" means I opened the cited file. "README only" was not used.

| Key | Project | Lang | Location | Read? | Copy the idea of |
| --- | --- | --- | --- | --- | --- |
| BZ-ADP / BZ-DEV / BZ-AGT / BZ-AGM / BZ-BAT / BZ-BP / BZ-PM | BlueZ D-Bus API docs (master) | rst | `https://raw.githubusercontent.com/bluez/bluez/master/doc/org.bluez.{Adapter,Device,Agent,AgentManager,Battery,BatteryProvider,ProfileManager}.rst` | read (fetched 2026-10-20, not pinned) | authoritative names, signatures, defaults |
| BZ-SRC | BlueZ `src/uuid-helper.c`, `src/battery.c`, `src/device.c` | C | `https://raw.githubusercontent.com/bluez/bluez/master/src/{uuid-helper,battery,device}.c` | read the cited functions only | modalias format, battery unknown = 255 |
| DMS | DankMaterialShell `core/internal/server/bluez/` | Go | pinned `https://raw.githubusercontent.com/AvengeMedia/DankMaterialShell/8be08999caf74878179434a980420a9ed5008b03/core/internal/server/bluez/{agent,manager,types,rfkill_linux}.go`; local clone `/home/user/avengemedia/dankmaterialshell` | read agent.go, manager.go (cited ranges), types.go, rfkill_linux.go; not read: handlers.go, player.go, watcher.go | prompt broker design, rfkill fallback (do not copy as-is) |
| BTC | bluetuith-org/bluetooth-classic | Go | pinned `https://raw.githubusercontent.com/bluetuith-org/bluetooth-classic/fc86ce311e9691c35fae3ab555af67d562f43ae5/internal/bluez/{adapter,device,agent}.go` and `api/bluetooth/{device,services}.go`; local clone `/home/user/bluetuith-org/bluetooth-classic` | read Linux backend and API types; NOT read: `internal/haraltd`, `internal/libhbluetooth` (its Windows and macOS backends) | cross-platform API shape (optional percentage, UUIDs, class decoding) |
| BLUER | bluer 0.17.4 (BlueZ, Rust) | Rust | `https://static.crates.io/crates/bluer/bluer-0.17.4.crate`, extracted at `/tmp/claude-0/-home-user-BleuKit/6687942f-5aa7-51f3-b982-28eea7444ce0/scratchpad/bt/crates/bluer/bluer-0.17.4/src/` | read device.rs, adapter.rs (property table, remove), agent.rs (capability derivation) | typed property table; pair cancels on drop |
| QS | Quickshell `src/bluetooth/` (`Quickshell.Bluetooth`) | C++ | pinned `https://raw.githubusercontent.com/quickshell-mirror/quickshell/2b4501a282689792b62e94f3fb30d8f512324fe6/src/bluetooth/{adapter,device,bluez}.{cpp,hpp}`; local clone `/home/user/quickshell-mirror/quickshell` | read adapter, device (pair, battery), bluez (object manager) | shell-facing model; `off-blocked` mapping; no agent (a gap) |
| WAYLE | wayle-bluetooth (vendored fork, previous attempt; upstream commit not pinned) | Rust | `/tmp/claude-0/-home-user-BleuKit/6687942f-5aa7-51f3-b982-28eea7444ce0/scratchpad/rust_prev/desktop-systems/forks/wayle-services/wayle-bluetooth/src/{proxy/battery.rs,proxy/device.rs,proxy/agent_manager.rs,agent/providers.rs}` | read these four files | zbus proxies, pin/passkey responder model; no modalias parsing |
| BLUEUTIL | toy/blueutil 2.14.0 | Obj-C | `https://raw.githubusercontent.com/toy/blueutil/master/blueutil.m` (1482 lines, not pinned) | read fully | the only macOS route that drives the private prefs and the pairing delegate |
| AP-IOB / AP-CB | Apple IOBluetooth and CoreBluetooth doc JSON | JSON | `https://developer.apple.com/tutorials/data/documentation/iobluetooth/{iobluetoothdevice,iobluetoothdevicepair,iobluetoothdevicepairdelegate,iobluetoothdeviceinquiry,iobluetoothhostcontroller,iobluetooth}.json`; `.../corebluetooth.json`, `.../corebluetooth/cbcentralmanager.json` | read symbol lists and abstracts; no per-member availability | public selector names |
| WIN-SYS | windows-sys 0.61.2, module `Windows::Win32::Devices::Bluetooth` | Rust | `https://static.crates.io/crates/windows-sys/windows-sys-0.61.2.crate`, extracted at `/tmp/claude-0/-home-user-BleuKit/6687942f-5aa7-51f3-b982-28eea7444ce0/scratchpad/bt/crates/winsys/windows-sys-0.61.2/src/Windows/Win32/Devices/Bluetooth/mod.rs` | read | generated Win32 signatures, structs, constants (no docs) |
| LEARN | Microsoft Learn Win32 Bluetooth and WinRT pages | docs | `https://learn.microsoft.com/en-us/windows/win32/api/bluetoothapis/nf-bluetoothapis-{bluetoothauthenticatedeviceex,bluetoothfindfirstradio,bluetoothregisterforauthenticationex,bluetoothsetservicestate,bluetoothremovedevice,bluetoothenumerateinstalledservices,bluetoothgetdeviceinfo}`; `https://learn.microsoft.com/en-us/uwp/api/windows.devices.enumeration.{devicepairingkinds,deviceinformationcustompairing,devicepairingrequestedeventargs}`, `.../windows.devices.bluetooth.bluetoothdevice.frombluetoothaddressasync`, `.../windows.devices.radios.radio` | read remarks and parameters | semantics for Windows calls |
| KRF | Linux kernel rfkill uapi and core | C | `https://raw.githubusercontent.com/torvalds/linux/master/include/uapi/linux/rfkill.h`, `.../net/rfkill/core.c` (master, not pinned) | read cited lines | struct layout and permission path |
| SD-UA | systemd 255.4 `70-uaccess.rules` | udev | `/usr/lib/udev/rules.d/70-uaccess.rules` in this container | read L84-85 | `/dev/rfkill` access for the session user |

Not read (listed so no one assumes coverage): KDE bluez-qt, GNOME
gnome-bluetooth, blueman, bluetuith `haraltd` and `libhbluetooth` (the Windows
and macOS backends), btleplug, bluest, bluez-async, Astal. The brief asked for
these, but this spike did not reach them.

## 4. Double validation

Each row is a claim from section 2 with its two independent sources. Where two
sources disagree, the row says so.

| ID | Claim | Source A | Source B | Status |
| --- | --- | --- | --- | --- |
| C1 | `Adapter1.Powered` is rw and resets on restart; `PowerState` includes `off-blocked` | BZ-ADP L327-368 | QS adapter.cpp:200-201, adapter.hpp:162 | agreed |
| C2 | Discovery is a shared session; `StopDiscovery` releases one | BZ-ADP L25-62 | (none; BLUER adapter.rs discover_devices is a wrapper) | (single-source) |
| C3 | `DiscoverableTimeout` default 180 s, 0 = never; `Discoverable` auto-reverts | BZ-ADP L377-378, L407-411 | (none) | (single-source) |
| C4 | `Pair()` blocks, needs an agent or default agent | BZ-DEV L111-124 | DMS manager.go:808-819 (call site), BLUER device.rs:257-270 | agreed |
| C5 | `CancelPairing` cancels a `Pair()` in progress | BZ-DEV L141-146 | BLUER device.rs:257-270 (drop cancels) | agreed |
| C6 | `RegisterAgent` capability list; `""` means KeyboardDisplay | BZ-AGM L190-200 | BLUER agent.rs:260-272, DMS agent.go:22, BTC agent.go:70 | agreed |
| C7 | `Agent1` methods, argument and return types | BZ-AGT L24-146 | DMS agent.go:25-64 (introspection XML), BLUER agent.rs:341-423 | agreed |
| C8 | `DisplayPasskey` may repeat with growing `entered`; DMS shows only at 0 | BZ-AGT L95-96 | DMS agent.go:171 | conflict: DMS deviates from the doc |
| C9 | Passkey display is 6-digit zero-padded | BZ-AGT L98-99 (and PIN L62-63) | DMS agent.go:172-173 does not pad | conflict: DMS deviates from the doc |
| C10 | `Connect()` connects auto-connectable profiles; `ConnectProfile(uuid)` one profile | BZ-DEV L25-30, L81-86 | BLUER device.rs:199-224 | agreed |
| C11 | `DisconnectProfile` needs a registered client profile | BZ-DEV L95-102 | BTC device.go:147 uses it without a check | (single-source); hardware UNVERIFIED |
| C12 | `Battery1.Percentage` is `y`, 0-100, absent when unknown | BZ-BAT L270-275; BZ-SRC battery.c:110, 152-157 | BLUER device.rs:530-534 (optional) | agreed |
| C13 | Component batteries are experimental, with `Device`, `Identifier`, `Charging` | BZ-BAT L255-261, L288-305 | BZ-BP L17-48 | agreed |
| C14 | Modalias is `bluetooth:` for source 1 and `usb:` for source 2 | BZ-SRC uuid-helper.c:34-41 | BZ-SRC device.c:8355-8356 | agreed (both BlueZ) |
| C15 | rfkill event layout, type 2 = BT, op 3 = CHANGE_ALL | KRF rfkill.h L44-46, L66-69, L93-98 | DMS rfkill_linux.go:5-17 | agreed |
| C16 | `/dev/rfkill` write has no `CAP_NET_ADMIN` check; sysfs does | KRF core.c:1283-1330 (no capable in write) | KRF core.c:769 (soft_store checks capable) | (single-source for the kernel path); runtime on a live host UNVERIFIED (no `/dev/rfkill` here) |
| C17 | Local session user has `uaccess` on `/dev/rfkill` | SD-UA 70-uaccess.rules:84-85 | (none; upstream systemd file not reachable) | (single-source); other distros UNVERIFIED |
| C18 | Class of device major/minor bit masks | BTC api/bluetooth/device.go:186-197 | upower up-device-bluez.c cited but not read | (single-source) |
| C19 | Profile UUID values for A2DP/HFP/HSP/PnP | BZ-PM L35-60 (HFP, HSP) | BTC api/bluetooth/services.go:13-71 (cites BlueZ sdp.h) | agreed |
| C20 | Property writes go through `org.freedesktop.DBus.Properties.Set` (Powered, Trusted; Blocked in BTC) | DMS manager.go:798-805, 840-843 | BTC internal/bluez/adapter.go:240-245 (`setAdapterProperty`), device.go:208-245 (`setDeviceProperty` for Trusted, Blocked) | agreed for Powered and Trusted; Alias (BZ-DEV L342-352 only) |
| C21 | Public `IOBluetoothDevice` selectors (`pairedDevices`, `recentDevices:`, `favoriteDevices`, `openConnection`, `closeConnection`, `rawRSSI`, `name`) | AP-IOB iobluetoothdevice.json (symbol list) | BLUEUTIL blueutil.m:533-541, 919, 1054, 1117, 1165, 1196 | agreed |
| C22 | `IOBluetoothDevicePair` `start`/`stop`, `pairWithDevice:`, delegate callbacks | AP-IOB iobluetoothdevicepair.json (`start`, `stop` abstracts) | BLUEUTIL blueutil.m:726-803, 1260-1270 | agreed |
| C23 | `IOBluetoothDeviceInquiry` is a bounded run with start/stop and `foundDevices` | AP-IOB iobluetoothdeviceinquiry.json (exists) | BLUEUTIL blueutil.m:649-653, 1083-1096 | agreed (lifecycle from BLUEUTIL only) |
| C24 | Host-controller power is read-only publicly | AP-IOB iobluetoothhostcontroller.json (`powerState` only) | BLUEUTIL blueutil.m:48-49 (uses private setter) | agreed |
| C25 | Private `IOBluetoothPreference*` symbols and set-then-poll | BLUEUTIL blueutil.m:46-52, 167-193 | (none; not in Apple's public symbol list) | (single-source) |
| C26 | Unpair via private `remove` selector, experimental | BLUEUTIL blueutil.m:1292-1298, 239 | (none) | (single-source) |
| C27 | Recent and favourites not stored from macOS 12 | BLUEUTIL blueutil.m:228-243, 268 | (none) | (single-source) |
| C28 | RSSI is `char`; 127 = unreadable; 0 = golden range | BLUEUTIL blueutil.m:24, 1425 | AP-IOB iobluetoothdevice.json `rssi()` abstract (0 = golden range) | agreed |
| C29 | TCC denial aborts (SIGABRT); CoreBluetooth needs `NSBluetoothAlwaysUsageDescription` | BLUEUTIL blueutil.m:304-310 | AP-CB corebluetooth.json (iOS-phrased) | partly agreed; macOS wording (single-source) |
| C30 | `system_profiler SPBluetoothDataType -xml` device structure | BLUEUTIL blueutil.m:412-476 | (none) | (single-source) |
| C31 | Battery keys on macOS | (none) | (none) | (UNVERIFIED) |
| C32 | `BluetoothManager.framework` private classes | (none) | (none) | (UNVERIFIED) |
| C33 | Win32 signatures and parameter lists for the radio, device, pair, remove calls | WIN-SYS mod.rs (lines in section 2.3) | LEARN (parameters and return values) | agreed on signatures |
| C34 | `BLUETOOTH_DEVICE_INFO` layout | WIN-SYS mod.rs:206-216 | (Learn struct page not fetched) | (single-source) |
| C35 | `BluetoothAuthenticateDeviceEx` with NULL OOB shows UI | LEARN AuthenticateDeviceEx (Parameters, Remarks) | WIN-SYS mod.rs:2 (signature only) | agreed |
| C36 | Callback register, respond, unregister; first callback only | LEARN RegisterForAuthenticationEx (Remarks) | WIN-SYS mod.rs:33, 43, 46 | agreed |
| C37 | Method and IO capability values | WIN-SYS mod.rs:186-191, 276-281 | (no Learn constant page fetched) | (single-source) |
| C38 | `BluetoothRemoveDevice` fails for not-remembered devices | LEARN RemoveDevice (Remarks) | WIN-SYS mod.rs:34 (signature) | agreed on the call; remark is (single-source) |
| C39 | `BluetoothSetServiceState` enables or removes a service driver; ENABLE = 1 | LEARN SetServiceState (Remarks) | WIN-SYS mod.rs:45, 377-378 | agreed |
| C40 | WinRT pairing kinds and event args | LEARN DevicePairingKinds, DevicePairingRequestedEventArgs | (none) | (single-source) |
| C41 | `Radio.SetStateAsync` for power | LEARN Radio (Remarks) | (none) | (single-source) |
| C42 | `BluetoothDevice.FromBluetoothAddressAsync(ulong)` | LEARN (Definition) | (none) | (single-source) |
| C43 | Windows trusted equals paired | BTC api/bluetooth/device.go:136-144 | (none) | (single-source) |

DLL discrepancy (not a claim row, but load-bearing): LEARN lists `Bthprops.lib`
and `bthprops.cpl` as the import library and DLL for `BluetoothFindFirstRadio`,
`BluetoothGetDeviceInfo`, `BluetoothRemoveDevice`, `BluetoothEnumerateInstalledServices`,
`BluetoothSetServiceState`, `BluetoothRegisterForAuthenticationEx`. WIN-SYS
links most of these to `bluetoothapis.dll` (mod.rs:7, 9, 10, 27, 28, 33, 34, 45),
and only `AuthenticateDevice*` to `bthprops.cpl`. `(UNVERIFIED)` which import
library is correct. Check on a Windows host before choosing one.

Other discrepancies found while reading: BlueZ docs are labelled "October 2023"
(Adapter, Device, Agent, Battery) but contain experimental component-battery
members, so they are from master, not a release. The release number that
ships with a given distro was not determined `(UNVERIFIED)`.

## 5. Proposed Bleu model

Draft only, not compiled. Types follow ARCHITECTURE.md: plain data, no optionals
in state (a `bool` next to the value), closed sets as enums, ids as `String`.
Units `Percent` and `Dbm` should live in `bleu::unit` (add them if missing).

```c3
module bleu::bluetooth;            // model.c3 (platform-neutral)
import bleu::unit;                 // Percent, Dbm

typedef Percent = ubyte;           // 0..100; battery unknown is has_battery == false
typedef Dbm = short;               // RSSI in dBm; macOS 127 "unreadable" is mapped in the backend

enum AddressKind : char { PUBLIC, RANDOM, UNKNOWN }         // Device1.AddressType; BR/EDR is PUBLIC
enum PowerState : char { OFF, ON, OFF_ENABLING, ON_DISABLING, OFF_BLOCKED }   // BlueZ PowerState; other OS: ON/OFF
enum PairingIo : char { DISPLAY_ONLY, DISPLAY_YES_NO, KEYBOARD_ONLY, NO_INPUT_NO_OUTPUT, KEYBOARD_DISPLAY }
enum PromptKind : char { PIN_CODE, PIN_DISPLAY, PASSKEY_ENTRY, PASSKEY_DISPLAY, CONFIRM, AUTHORIZE, AUTHORIZE_SERVICE }

enum Cap : char {                  // every optional operation; each has an Availability
    ADAPTER_POWER, ADAPTER_DISCOVERABLE, ADAPTER_PAIRABLE, DISCOVERY,
    PAIR, PAIR_CANCEL, PAIRING_AGENT, CONNECT, DISCONNECT,
    CONNECT_PROFILE, DISCONNECT_PROFILE, TRUST, BLOCK, REMOVE, RENAME,
    BATTERY, RSSI, UUIDS, MODALIAS, RFKILL_STATE, UNPAIR_PRIVATE_API
}

struct AdapterState {
    String address; String name; PowerState power;
    bool discoverable; uint discoverable_timeout_s;
    bool pairable; bool discovering;
}

struct DeviceState {
    String address;                 // stable id: "AA:BB:CC:DD:EE:FF"
    String adapter;                 // adapter id (hciN or controller address)
    String name; String alias; String icon;
    uint class_of_device; ushort appearance;
    bool paired; bool bonded; bool connected; bool trusted; bool blocked; bool services_resolved;
    bool has_rssi; Dbm rssi;
    bool has_battery; Percent battery;
    String modalias;                // raw; vendor/product parsed by a helper
    String[] uuids;
}

struct BluetoothState {
    AdapterState[] adapters;
    DeviceState[] devices;
}

enum Backend : char { AUTO, BLUEZ, IOBLUETOOTH, BLUEUTIL_CLI, WINRT, WIN32 }

struct Options {
    Backend backend;               // forces one backend (ARCHITECTURE rule 7)
    bool allow_private_api;        // macOS private prefs, unpair; off by default
    bool own_pairing_agent;        // Linux: register Agent1 for this process
}

enum EventKind : char {
    ADAPTER_CHANGED, DEVICE_ADDED, DEVICE_CHANGED, DEVICE_REMOVED,
    PAIRING_PROMPT, PAIRING_ABORTED, DEVICE_DISCONNECTED
}

struct Event {                     // transients on Stream{Event}
    EventKind kind;
    String address;
    PromptKind prompt; uint passkey; ushort entered;   // DisplayPasskey progress
    String token;                  // prompt id for submit/confirm/cancel
    String text;                   // disconnect reason or error text
}
```

Operations (`Operation{...}`, ARCHITECTURE rule 4):

* `set_power(bool)`, `set_discoverable(bool, timeout_s)`, `start_discovery()`,
  `stop_discovery()`: `Operation{void}`.
* `pair(address)`: `Operation{DeviceState}`; prompts go out as `PAIRING_PROMPT`
  events, answered by `submit_pin(token, String)`, `submit_passkey(token, uint)`,
  `confirm(token, bool)`, `authorize(token, bool)`, `cancel(token)`.
* `connect`, `disconnect`, `connect_profile(address, uuid)`,
  `disconnect_profile(address, uuid)`, `set_trusted`, `set_blocked`, `rename`,
  `remove`: `Operation{void}`.

Backends and priority per OS (`probe.c3` order):

* linux: `bluez` (P1, `bleu::dbus`, `org.bluez`). Rfkill: state only, through
  `PowerState`. Writing `/dev/rfkill` is a separate, explicitly enabled fallback
  if it is kept at all.
* macos: `iobluetooth` (P1, public), `iobluetooth_private` (P2, `bleu::dl`,
  `*_private.c3`, only when `allow_private_api`), `blueutil_cli` (P3, exec, JSON, read only).
* windows: `winrt` (P1, radio power and custom pairing), `win32` (P1, enumeration,
  remove, service toggles). One backend may do both; the choice is per call.

Per-OS unavailable fields (see section 2.4): trusted and blocked (macOS, Windows),
rename (macOS, Windows), modalias (macOS, Windows), battery (macOS and Windows
until verified), per-profile connect (macOS), pairable (macOS, Windows).

## 6. Risks and cut lines

Hard parts:

* Pairing UI models differ: BlueZ calls back into our agent (method return is the
  answer); Win32 callbacks carry an IO capability and an authentication method;
  macOS uses a delegate that needs a run loop on the pairing thread; blueutil
  reads PINs from stdin. A single `PromptKind` broker (as DMS and Wayle do) is
  the common shape, but the answers differ per platform.
* macOS private APIs (power, discoverable, unpair) need `bleu::dl`, run-time
  gating, TCC, and OS version testing that this spike could not do.
* Windows has no trust, block, rename, battery, or modalias fields, and the
  import-library question above is open.
* Linux: experimental members and the BlueZ version are not pinned. Default
  BlueZ D-Bus policy and agent registration rights are unverified.
* Security: fixed PIN and passkey (bluetooth-classic) must not be copied.
  Writing `/dev/rfkill` lets any active-session process clear Bluetooth soft
  blocks, so keep it out of v1.

Cut lines (recommended):

1. v1 Linux, full scope minus GATT, OBEX, PAN, AVRCP, LE advertising, wake,
   component batteries, `PreferredBearer`. Include device battery, modalias,
   per-profile connect, trust, block, alias, remove.
2. v1 Windows: adapter list and radio power (WinRT), device list (Win32),
   pairing through WinRT custom pairing (ConfirmOnly, DisplayPin, ProvidePin),
   remove. No connect or disconnect (no Win32 connect call), no battery, no
   trust or block. Per-profile only if a use case appears (`BluetoothSetServiceState`).
3. v1 macOS: paired and recent lists, connect and disconnect, pair through the
   delegate, inquiry-based discovery. Power, discoverable, and unpair only behind
   the private gate, off by default. No battery, trust, block, or rename.
4. Cut for all platforms in v1: GATT and BLE, OBEX, PAN and DUN, AVRCP, LE
   advertising, `ConnectDevice` [exp], `GetServiceRecords` [exp].

Doubts that block implementation:

* DisconnectProfile on unregistered UUIDs (C11): test on Linux hardware.
* Windows import library and whether `BluetoothSetServiceState` affects only
  driver install or also live connection (LEARN says driver install).
* macOS battery route: no verified key; the brief's keys are unconfirmed.
* macOS `BluetoothManager.framework` private classes (C32): unverified, lead only.
* `ManufacturerData`/`ServiceData` D-Bus types (inferred from doc text).
* rfkill on a live host: `/dev/rfkill` write behaviour and mode were not tested
  (no device here).
