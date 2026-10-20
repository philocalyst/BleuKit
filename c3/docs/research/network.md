# Research spike: network service

Status: research only. No code written. Every claim below cites a source
read in this spike (S-numbers in section 4). Anything not read is marked
`(UNVERIFIED)`; single-source claims are marked `(single-source)`.

Reachability used: `gitlab.freedesktop.org` raw, `raw.githubusercontent.com`
(NetworkManager and Hammerspoon mirrors), `git.kernel.org` plain (iwd docs),
`networkmanager.dev` (NM API reference), `w1.fi` (wpa_supplicant D-Bus),
`static.crates.io`, `docs.rs`, `learn.microsoft.com`, `docs.kernel.org`.
`developer.apple.com` pages are JavaScript-rendered; only page titles and
objc2 bindings (which mirror the Apple headers) were usable.

## 1. What a shell needs

Priority order (P0 = v1 cut line, see section 6):

1. P0 Wi-Fi radio on/off, scan, visible networks: SSID as raw bytes plus a
   display label, BSSID, frequency MHz, channel, band, signal (dBm and 0-100
   quality), security class (open / WEP / WPA-PSK / WPA2 / WPA3-SAE / OWE /
   802.1X), in-use flag, known (saved) profile flag.
2. P0 Wi-Fi connect with PSK passphrase, open network, disconnect, forget a
   saved profile, autoconnect on/off per profile.
3. P0 Connection progress states and failure reasons (see section 2 maps).
4. P0 Credential prompt as an event: a backend asks for a passphrase or
   enterprise credential, the shell answers (`Operation` resumes).
5. P0 Overall connectivity (none / portal / limited / full) and the primary
   connection (type, interface, name).
6. P0 Ethernet: carrier, speed, link state, per-interface traffic counters.
7. P1 Connect to hidden SSID (SSID given by user), enterprise 802.1X
   credentials (EAP method, identity, password).
8. P1 IP configuration read: addresses, gateway, DNS, metered flag.
9. P1 Airplane mode (global radio off) and per-radio state.
10. P1 VPN: list profiles, activate, deactivate, state.
11. P2 Cellular / WWAN basics (device present, enabled, registered, signal).
12. P2 Hotspot / AP mode (configure SSID+passphrase, start, stop, clients).
13. P2 Watch for changes (events) on every item above.

## 2. Per-platform native route

### 2.1 Linux

#### 2.1.1 NetworkManager over D-Bus (preferred; the shell's de-facto route)

Bus name `org.freedesktop.NetworkManager`, root object
`/org/freedesktop/NetworkManager`. Introspection read: S1.

Interface and signatures (all from S1 unless noted):

| Object / interface | Member | Signature / note |
| --- | --- | --- |
| `org.freedesktop.NetworkManager` | `GetDevices()` | -> `ao` |
| same | `GetDeviceByIpIface(s iface)` | -> `o device` |
| same | `AddAndActivateConnection2(a{sa{sv}} connection, o device, o specific_object, a{sv} options)` | -> `(o path, o active_connection, a{sv} result)` |
| same | `ActivateConnection(o connection, o device, o specific_object)` | -> `o active_connection` |
| same | `DeactivateConnection(o active_connection)` | |
| same | `Enable(b)`, `Sleep(b)` | networking on/off |
| same | `CheckConnectivity()` | -> `u connectivity` |
| same | prop `WirelessEnabled` | `b` read/write |
| same | prop `WwanEnabled`, `WwanHardwareEnabled`, `WirelessHardwareEnabled` | `b` |
| same | prop `RadioFlags`, `NetworkingEnabled` | `u`, `b` |
| same | prop `PrimaryConnection`, `PrimaryConnectionType`, `ActiveConnections` | `o`, `s`, `ao` |
| same | prop `Connectivity`, `ConnectivityCheckEnabled`, `ConnectivityCheckUri` | `u`, `b`, `s` |
| same | prop `Metered` | `u` |
| same | prop `State` ; signal `StateChanged(u state)` | `u` |
| same | signals `DeviceAdded(o)`, `DeviceRemoved(o)` | |
| `...NetworkManager.Device` | prop `State` (`u`), `StateReason` (`(uu)`: state, reason), `ActiveConnection` (`o`), `Interface` (`s`), `Autoconnect` (`b` rw), `Metered` (`u`), `Mtu` (`u`), `HwAddress` (`s`), `DeviceType` (`u`), `Ip4Config` (`o`), `Ip6Config` (`o`), `AvailableConnections` (`ao`) | S1 |
| same | method `Disconnect()`, `Delete()`, `Reapply(...)`, `GetAppliedConnection(...)` | S1 |
| same | signal `StateChanged(u new_state, u old_state, u reason)` | S1 |
| `...NetworkManager.Device.Wireless` | `GetAccessPoints() -> ao`, `GetAllAccessPoints() -> ao` | S1 |
| same | `RequestScan(a{sv} options)` | S1 |
| same | prop `ActiveAccessPoint` (`o`), `WirelessCapabilities` (`u`), `LastScan` (`x`), `Mode` (`u`), `Bitrate` (`u`), `HwAddress`, `PermHwAddress` | S1 |
| same | signals `AccessPointAdded(o)`, `AccessPointRemoved(o)` | S1 |
| `...NetworkManager.AccessPoint` | prop `Ssid` (`ay`, raw bytes), `Flags` (`u`), `WpaFlags` (`u`), `RsnFlags` (`u`), `Frequency` (`u`, MHz), `HwAddress` (`s`), `Mode` (`u`), `MaxBitrate` (`u`), `Bandwidth` (`u`), `Strength` (`y`, 0-100), `LastSeen` (`i`) | S1 |
| `...NetworkManager.Settings.Connection` | `GetSettings() -> a{sa{sv}}`, `GetSecrets(s setting_name) -> a{sa{sv}}`, `Update(a{sa{sv}})`, `Update2(a{sa{sv}} settings, u flags, a{sv} args) -> a{sv}`, `Save()`, `Delete()`, `ClearSecrets()` | S1 |
| same | prop `Unsaved` (`b`), `Flags` (`u`), `Filename` (`s`) | S1 |
| `...NetworkManager.Connection.Active` | prop `State` (`u`), `StateFlags` (`u`), `Id`, `Uuid`, `Type` (`s`), `Devices` (`ao`), `Vpn` (`b`), `SpecificObject` (`o`), `Connection` (`o`); signal `StateChanged(u state, u reason)` | S1 |
| `...NetworkManager.VPN.Connection` | prop `VpnState` (`u`), `Banner` (`s`); signal `VpnStateChanged(u state, u reason)` | S1 |
| `...NetworkManager.AgentManager` (object `/org/freedesktop/NetworkManager/AgentManager`) | `Register(s identifier)`, `RegisterWithCapabilities(s identifier, u capabilities)`, `Unregister()` | S1 (AgentManager.xml) |
| `...NetworkManager.SecretAgent` (exported by the client) | `GetSecrets(a{sa{sv}} connection, o connection_path, s setting_name, as hints, u flags) -> a{sa{sv}} secrets`, `CancelGetSecrets(o connection_path, s setting_name)`, `SaveSecrets(a{sa{sv}} connection, o connection_path)`, `DeleteSecrets(a{sa{sv}} connection, o connection_path)` | S1 (SecretAgent.xml) |

Note: the main NM XML also contains a legacy method `state() -> u`
(S1). Use the `State` property instead.

Call sequence, Wi-Fi connect with PSK (happy path, shell as client):

1. Connect to system bus. Get `GetDevices()`, pick the device whose
   `DeviceType == 2` (WIFI). Type values: ETHERNET=1, WIFI=2 (S2 names;
   values also S3 `device_type` constants).
2. Subscribe to the `Device.StateChanged` and `Device.Wireless` AP signals
   on that device path (signal match rules).
3. Optional scan: `Device.Wireless.RequestScan(a{sv}{})`. It is
   asynchronous; wait for `LastScan` to change, or re-read
   `GetAllAccessPoints()` after the signal.
4. Build settings dict `a{sa{sv}}`:
   * `"connection"`: `"id"` (s), `"type"` = `"802-11-wireless"`, `"uuid"` (s),
     `"autoconnect"` (b).
   * `"802-11-wireless"`: `"ssid"` = `ay` raw bytes of the SSID;
     `"mode"` = `"infrastructure"`; `"hidden"` = `b` for hidden SSIDs
     (single-source: S3 wifi_builder uses the same key family).
   * `"802-11-wireless-security"`: `"key-mgmt"` = `"wpa-psk"` | `"sae"` |
     `"owe"` | `"wpa-eap"` (S3 builder code; `"owe"` and `"sae"` token
     handling S4 nm-supplicant-config.c lines ~1025-1091); `"psk"` = `s`
     passphrase (S3 builder).
   * Open network: omit the security section.
5. Call `AddAndActivateConnection2(settings, device_path, "/", {}, ...)`.
   Returns the active connection path, which then reports `Connection.Active`
   `State`.
6. Watch `Device.StateChanged(new, old, reason)` until `new == 100`
   (ACTIVATED) or `new == 120` (FAILED). Map `reason` with section 2.1.3.
7. If the device enters `NEED_AUTH` (60) and the secret is missing, NM calls
   the registered secret agent (step 8). Otherwise the reason is `NO_SECRETS`
   (7).
8. Credential prompts (SecretAgent): register once per process:
   `AgentManager.Register("bleu.network")` (single-source: S3 agent code uses
   `Register` with an identifier; the exact identifier string is the caller's
   choice). Export the `SecretAgent` interface at a chosen object path.
   On `GetSecrets(connection, path, setting_name, hints, flags)`:
   * If `flags & 0x1` (`NM_SECRET_AGENT_GET_SECRETS_FLAG_ALLOW_INTERACTION`)
     is set, the agent may show a prompt. If it is clear, return an error or
     empty dict (S2 flag value; S3 `secret_agent` code returns `NoSecrets`).
   * Park the request (keyed by `(path, setting_name)`), publish a Bleu
     credential-prompt event, and reply later with the secrets dict:
     `{"802-11-wireless-security": {"psk": <s>}}` for PSK, or the 802.1X
     keys for enterprise.
   * `CancelGetSecrets(path, setting)` must abort the pending request
     (S1 + S3 `iface.rs` lines 164-172).
   * `SaveSecrets` / `DeleteSecrets` are notifications that secrets were
     stored or removed (S1 + S3 `iface.rs` lines 193-212).
   * S3 uses an internal GetSecrets timeout of 120 s with a `NoSecrets`
     reply, matching its comment about NM's timeout (single-source; S3).
9. Disconnect: `Device.Disconnect()` (S1). Forget: `Settings.Connection.Delete()`.
   Autoconnect: `Settings.Connection` property update via `Update2` with the
   `"connection" → "autoconnect"` key, or `Device.Autoconnect` (rw, S1).
10. Stop: `RemoveMatch` for signals; `AgentManager.Unregister()`; drop the
    exported SecretAgent object.

Scan results and visible networks: `Device.Wireless.GetAllAccessPoints()`
returns every AP including the ones not in range of the last scan
(S1). Use `Ssid` (`ay`) for raw bytes; `Strength` (`y`) is 0-100
(S1 names). dBm is not exposed by NM directly; convert `dBm` only if
the shell needs it (UNVERIFIED conversion; the NM API reference page does not
state the Strength formula in the fetched text).

##### 2.1.1a Connectivity and primary connection
* `Connectivity` (`u`) and `CheckConnectivity()` (S1). Values from S2:
  UNKNOWN=0, NONE=1, PORTAL=2, LIMITED=3, FULL=4. The doc text says that a
  portal state should trigger the browser flow and retrigger
  `CheckConnectivity()` when the page is dismissed (S2).
* `PrimaryConnection` (`o`) and `PrimaryConnectionType` (`s`) (S1).
* `Metered` (`u`) on the main object and on the device (S1). The numeric
  enum for metered values was not read (UNVERIFIED).

##### 2.1.1b Flags: AP security bits (verified values)
From S2 (`NM80211ApFlags`, `NM80211ApSecurityFlags`), which match S3 table:

| Name | Value |
| --- | --- |
| `NM_802_11_AP_FLAGS_PRIVACY` | `0x00000001` |
| `NM_802_11_AP_FLAGS_WPS` | `0x00000002` |
| `NM_802_11_AP_FLAGS_WPS_PBC` | `0x00000004` |
| `NM_802_11_AP_FLAGS_WPS_PIN` | `0x00000008` |
| `NM_802_11_AP_SEC_PAIR_WEP40` | `0x00000001` |
| `NM_802_11_AP_SEC_PAIR_WEP104` | `0x00000002` |
| `NM_802_11_AP_SEC_PAIR_TKIP` | `0x00000004` |
| `NM_802_11_AP_SEC_PAIR_CCMP` | `0x00000008` |
| `NM_802_11_AP_SEC_GROUP_WEP40` | `0x00000010` |
| `NM_802_11_AP_SEC_GROUP_WEP104` | `0x00000020` |
| `NM_802_11_AP_SEC_GROUP_TKIP` | `0x00000040` |
| `NM_802_11_AP_SEC_GROUP_CCMP` | `0x00000080` |
| `NM_802_11_AP_SEC_KEY_MGMT_PSK` | `0x00000100` |
| `NM_802_11_AP_SEC_KEY_MGMT_802_1X` | `0x00000200` |
| `NM_802_11_AP_SEC_KEY_MGMT_SAE` | `0x00000400` |
| `NM_802_11_AP_SEC_KEY_MGMT_OWE` | `0x00000800` |
| `NM_802_11_AP_SEC_KEY_MGMT_OWE_TM` | `0x00001000` (since NM 1.26) |
| `NM_802_11_AP_SEC_KEY_MGMT_EAP_SUITE_B_192` | `0x00002000` (since NM 1.30) |

Security classification (proposed rule, to be validated in a spike run):
* open: `Flags & PRIVACY == 0` and `WpaFlags == 0` and `RsnFlags == 0`.
* WEP: `Flags & PRIVACY` set and `WpaFlags == 0` and `RsnFlags == 0`.
* WPA-PSK: `key_mgmt & PSK` in `WpaFlags` or `RsnFlags`.
* WPA3-SAE: `key_mgmt & SAE` in `RsnFlags` (S3 classifies SAE as RSN-only
  in comments; the mapping of WpaFlags vs RsnFlags is `(single-source)`).
* OWE: `key_mgmt & OWE` in `RsnFlags`.
* Enterprise: `key_mgmt & 802_1X`.
* Transition mode: multiple key-mgmt bits set; NM selects `sae` when the
  AP advertises SAE only, and `wpa-psk` otherwise (S3 wifi_builder comments).
* Which of `WpaFlags` vs `RsnFlags` carries `PSK`/`SAE` is `(single-source)`:
  S3 comments and the NM enum doc describe the bits, but the fetched text
  does not state the property mapping (UNVERIFIED for the exact property).

Wireless mode values (S3 `wifi_mode`, names S2): ADHOC=1, INFRA=2, AP=3.
MESH=4 `(UNVERIFIED)`.

##### 2.1.1c Device state machine and reasons (verified; S2)

`Device.State` (`u`):

| Name | Value |
| --- | --- |
| UNKNOWN | 0 |
| UNMANAGED | 10 |
| UNAVAILABLE | 20 |
| DISCONNECTED | 30 |
| PREPARE | 40 |
| CONFIG | 50 |
| NEED_AUTH | 60 |
| IP_CONFIG | 70 |
| IP_CHECK | 80 |
| SECONDARIES | 90 |
| ACTIVATED | 100 |
| DEACTIVATING | 110 |
| FAILED | 120 |

`StateReason` codes (name = value, all S2): NONE=0, UNKNOWN=1,
CONFIG_FAILED=4, IP_CONFIG_UNAVAILABLE=5, IP_CONFIG_EXPIRED=6,
NO_SECRETS=7, SUPPLICANT_DISCONNECT=8, SUPPLICANT_CONFIG_FAILED=9,
SUPPLICANT_FAILED=10, SUPPLICANT_TIMEOUT=11, DHCP_START_FAILED=15,
DHCP_ERROR=16, DHCP_FAILED=17, FIRMWARE_MISSING=35, REMOVED=36,
SLEEPING=37, CONNECTION_REMOVED=38, USER_REQUESTED=39, CARRIER=40,
CONNECTION_ASSUMED=41, SUPPLICANT_AVAILABLE=42, SSID_NOT_FOUND=53,
DEPENDENCY_FAILED=50, NEW_ACTIVATION=60, IP_ADDRESS_DUPLICATE=64,
SIM_PIN_INCORRECT=59, NETWORKING_OFF=78. The full table (81 entries) is in
S2; the Wi-Fi-relevant subset above is the implementer's reason map.

`Connection.Active.State` (`u`, S2): UNKNOWN=0, ACTIVATING=1,
ACTIVATED=2, DEACTIVATING=3, DEACTIVATED=4.
Active-connection state reasons (S2): UNKNOWN=0, NONE=1,
USER_DISCONNECTED=2, DEVICE_DISCONNECTED=3, SERVICE_STOPPED=4,
IP_CONFIG_INVALID=5, CONNECT_TIMEOUT=6, SERVICE_START_TIMEOUT=7,
SERVICE_START_FAILED=8, NO_SECRETS=9, LOGIN_FAILED=10,
CONNECTION_REMOVED=11, DEPENDENCY_FAILED=12, DEVICE_REALIZE_FAILED=13,
DEVICE_REMOVED=14.

Progress mapping for the shell (proposed):
PREPARE/CONFIG → `connecting`; NEED_AUTH → `auth_required` (prompt);
IP_CONFIG/IP_CHECK → `obtaining_address`; ACTIVATED → `connected`;
FAILED with reason → `failed(reason)`.
Wrong-passphrase reason: NM's exact code for a rejected PSK is
`(UNVERIFIED)`. Candidates from S2 are SUPPLICANT_FAILED (10),
SUPPLICANT_TIMEOUT (11), or ActiveConnection LOGIN_FAILED (10). The spike
did not run NM against a real AP, so this must be tested.

##### 2.1.1d NM secret flags (partial, S2 and S3)
`NM_SECRET_AGENT_GET_SECRETS_FLAG_*` (S2): NONE=0x0, ALLOW_INTERACTION=0x1,
REQUEST_NEW=0x2, USER_REQUESTED=0x4, WPS_PBC_ACTIVE=0x8,
NO_ERRORS=0x40000000, ONLY_SYSTEM=0x80000000.
Setting secret flags (`NMSettingSecretFlags`: AGENT_OWNED=0x1, NOT_SAVED=0x2,
NOT_REQUIRED=0x4): S3 constants comments only (single-source; not verified
in S2 text).

##### 2.1.1e Client permissions (S2)
`NMClientPermission` values read: WIFI_SHARE_PROTECTED=7,
WIFI_SHARE_OPEN=8, WIFI_SCAN=17 (S2). Polkit action names for these
`(UNVERIFIED)`; NM is expected to check polkit on Settings and Device
operations.

##### 2.1.1f Hidden SSID
NM: a `802-11-wireless.hidden = true` setting (S3 builder). iwd has a
separate `ConnectHiddenNetwork` method (S5 station doc). NM's own
hidden-scan semantics are `(UNVERIFIED)`.

#### 2.1.2 iwd D-Bus (`net.connman.iwd`) (route 2)

Verified from the iwd docs on git.kernel.org (S5). Object base
`/net/connman/iwd`.

* `net.connman.iwd.AgentManager` at `/net/connman/iwd`:
  `RegisterAgent(o path)`, `UnregisterAgent(o path)`,
  `RegisterNetworkConfigurationAgent(o)`, `UnregisterNetworkConfigurationAgent(o)`.
* `net.connman.iwd.Agent` (object you export, freely named):
  * `string RequestPassphrase(object network)`
  * `string RequestPrivateKeyPassphrase(object network)`
  * `(string, string) RequestUserNameAndPassword(object network)`
  * `string RequestUserPassword(object network, string user)`
  * `void Cancel(string reason)` [noreply]
  * `void Release()` [noreply]
  * Error for user cancel: `net.connman.iwd.Agent.Error.Canceled`.
* `net.connman.iwd.Station` (object `/net/connman/iwd/{phy}/{n}`):
  * `Scan()`, `Disconnect()`.
  * `array(on) GetOrderedNetworks()`: tuples of (Network object path,
    `int16 SignalStrength` in 100 × dBm, range 0 to -10000).
  * `ConnectHiddenNetwork(string ssid)`: only for first-time provisioning of
    hidden psk/open networks; afterwards use `Network.Connect()`.
  * `GetHiddenAccessPoints()` `[experimental]`.
  * prop `State` (`string`): `connected`, `disconnected`, `connecting`,
    `disconnecting`, `roaming`.
  * prop `Scanning` (`b`), `ConnectedNetwork` (`o`, optional).
* `net.connman.iwd.Network`:
  * `Connect()` (WEP not supported).
  * prop `Name` (`string`, "Network SSID"), `Connected` (`b`), `Device`
    (`o`), `Type` (`string`: `open`, `wep`, `psk`, `8021x`), `KnownNetwork`
    (`o`, optional).
* `net.connman.iwd.KnownNetwork`: `Forget()`; prop `Name`, `Type`
  (`open`, `psk`, `8021x`, `hotspot`), `Hidden` (`b`), `LastConnectedTime`
  (optional, ISO 8601 string), `AutoConnect` (`b` rw).
* `net.connman.iwd.Device`: prop `Name`, `Address`, `Powered` (`b` rw,
  "True if the interface is UP"), `Adapter`, `Mode` (`string` rw:
  `ad-hoc`, `station`, `ap`).

Gaps (matter for the spec):
* `Network.Name` is typed `string`. iwd's doc does not state SSID bytes
  (single-source reading of the type). Non-UTF-8 SSIDs cannot be represented
  faithfully through the public API `(single-source; inference)`.
* `Network.Type` has no SAE or OWE value. WPA3 detection through iwd is
  therefore `(UNVERIFIED)`.
* The iwd agent has no SAE-specific request beyond `RequestPassphrase`
  `(single-source)`.
* Connecting to WEP is explicitly unsupported (S5).

iwdrs 0.1.0 (S6) implements this surface in Rust (station, network,
known network, device, adapter, agent). It uses `RequestPassphrase` only.
Secondary source for the names above; it matches S5.

#### 2.1.3 wpa_supplicant D-Bus (`fi.w1.wpa_supplicant1`) (route 3, lower priority)

From the w1.fi D-Bus reference (S7):
* `CreateInterface(a{sv} args) -> o`; `RemoveInterface(o)`.
* Interface: `Scan(a{sv} args)` (`Type`, `SSIDs` as `aay`), `AddNetwork(a{sv}) -> o`,
  `Disconnect()`, `SignalPoll()`, `ApScan` (`u`), `BSSExpireAge` (`u`).
* Signals: `ScanDone(b success)`, `BSSAdded(o BSS, a{sv})`,
  `BSSRemoved(o)`, `PropertiesChanged(a{sv})`.
* BSS properties: `SSID` (`ay`, raw bytes), `Privacy` (`b`), `Frequency`
  (`q`, MHz), `Mode` (`s`: `infrastructure`, `ad-hoc`), `RSN` and `WPA`
  (`a{sv}`, with `KeyMgmt` as a string array and `Pairwise`/`Group` ciphers),
  `Signal`/rssi (`i`, dBm).
* `KeyMgmt` values listed in the doc: `wpa-psk`, `wpa-eap`, `wpa-none`
  (RSN), plus `ieee8021x`, `wpa-psk-sha256`, `wpa-ft-psk`, `wpa-eap-sha256`,
  `wpa-ft-eap`, `none` (WPA property). The doc does not list `sae` or `owe`.
* NM passes `SAE` and `OWE` tokens to wpa_supplicant (S4 nm-supplicant-config.c
  lines ~1034-1091, `"OWE"`, `"SAE"`, `"FT-SAE"`). So the modern tokens exist
  but this doc is older than them `(single-source; doc drift)`.
* The state enum values (`disconnected`, `inactive`, `scanning`,
  `authenticating`, ...) are only partly read `(UNVERIFIED)` for the full list.

Route status: wpa_supplicant is a fallback only when NM and iwd are absent.
Control socket (`ctrl_interface`) path and protocol were not verified in this
spike (UNVERIFIED). A local fork (`forks/wpa-ctrl`) exists in the previous
attempt; it was not reviewed.

#### 2.1.4 ConnMan

Not researched. Cut line candidate (section 6).

#### 2.1.5 Ethernet, link state, counters (sysfs, kernel)

Verified from the kernel ABI page (S8):
* `/sys/class/net/<iface>/carrier` (link physical state, 0/1).
* `/sys/class/net/<iface>/operstate` (values include `up`, `down`,
  `dormant`, ...).
* `/sys/class/net/<iface>/speed` (Mbits/s; valid for ethtool
  `get_link_ksettings` drivers, mostly Ethernet; ABI says invalid otherwise).
* `/sys/class/net/<iface>/dormant`.

Traffic counters: the kernel statistics doc (S9) names `rx_bytes`,
`tx_bytes`, `rx_packets`, `tx_packets` among its counters. The sysfs
subpath `statistics/` is `(UNVERIFIED)` in this spike (the ABI grep did not
confirm it); `/proc/net/dev` is `(UNVERIFIED)` as well.

Ethernet devices, NM view: `Device` with `DeviceType == 1`. Carrier from
`Device.State == UNAVAILABLE` with `StateReason == CARRIER (40)`
(S1 + S2 names; mapping `(single-source)`).

#### 2.1.6 Cellular / WWAN

NM: `DeviceType` MODEM=8 (value from S3 `device_type`, names S2).
`WwanEnabled` / `WwanHardwareEnabled` properties on the main object (S1).
Modem reason codes (GSM_*, MODEM_*) are in S2 (examples: GSM_SIM_PIN_REQUIRED=46,
GSM_REGISTRATION_DENIED=31). ModemManager D-Bus was not researched (UNVERIFIED).

#### 2.1.7 Permissions and daemons (Linux)
* NetworkManager, iwd, wpa_supplicant as system daemons (general knowledge,
  UNVERIFIED in this spike).
* Polkit for NM operations: the action IDs were not verified; NM permission
  enum values are in S2 (section 2.1.1e).
* The secret agent: the client process must be allowed to register on the
  system bus (policy file). `(UNVERIFIED)`.

#### 2.1.8 Pitfalls (Linux)
* NM `GetSecrets` answers can be slow; S3 uses a 120 s timeout and then
  replies `NoSecrets` (single-source; the NM request timeout value was not
  checked against the NM source).
* `ActivateConnection` vs `AddAndActivateConnection2`: the latter creates a
  profile if needed; use the `Update2` path for profile edits (S1).
* iwd `Network.Name` is a string, so SSID bytes can be lost (section 2.1.2).
* The NM introspection XML's `state()` legacy method must not be used (S1).
* The NM doc enum `NM_DEVICE_STATE_REASON` contains two entries with value 73
  (UNMANAGED_SLEEPING and UNMANAGED_MANAGER_DISABLED, as parsed from S2); treat
  the value 73 as ambiguous `(UNVERIFIED)`.

### 2.2 macOS

#### 2.2.1 CoreWLAN (public route, preferred)

Verified from the objc2-core-wlan 0.3.0 bindings (S10), which are generated
from the CoreWLAN headers, and the Hammerspoon `hs.wifi` source (S11).

Entry points:
* `CWWiFiClient.sharedWiFiClient`, `interfaceNames`, `interfaceWithName:`,
  `interfaces`, `setDelegate:` (delegate = `CWEventDelegate`-style
  protocol; the class method list in S10).
* `CWWiFiClient.startMonitoringEventWithType:error:` with
  `CWEventTypeSSIDDidChange` / `CWEventTypeBSSIDDidChange` event types (named
  in the S10 doc comments; the enum values were not read) `(UNVERIFIED values)`.

`CWInterface` methods (S10, names from generated bindings):
`interfaceName`, `powerOn`, `setPower:error:`, `setWLANChannel:error:`,
`supportedWLANChannels`, `wlanChannel`, `activePHYMode`, `ssid`, `ssidData`,
`bssid`, `rssiValue`, `noiseMeasurement`, `security`, `transmitRate`,
`countryCode`, `interfaceMode`, `transmitPower`, `hardwareAddress`,
`serviceActive`, `cachedScanResults`, `configuration`,
`scanForNetworksWithName:includeHidden:error:`,
`scanForNetworksWithSSID:includeHidden:error:`,
`associateToNetwork:password:error:`,
`associateToEnterpriseNetwork:identity:username:password:error:`,
`disassociate`, `startIBSSModeWithSSID:security:channel:password:error:`,
`setWEPKey:flags:index:error:`, `setPairwiseMasterKey:error:`.

`CWNetwork` properties (S10): `ssid`, `ssidData` (1-32 octets, `NSData`),
`bssid`, `rssiValue`, `channel`, `security`, `countryCode`, `ibss`, etc.
Scan results: `NSSet<CWNetwork>`.

Event delegate callbacks (S10 `CWWiFiClient` bindings):
`clientConnectionInterrupted`, `clientConnectionInvalidated`,
`powerStateDidChangeForWiFiInterfaceWithName:`,
`ssidDidChangeForWiFiInterfaceWithName:`,
`bssidDidChangeForWiFiInterfaceWithName:`,
`countryCodeDidChangeForWiFiInterfaceWithName:`,
`linkDidChangeForWiFiInterfaceWithName:`,
`linkQualityDidChangeForWiFiInterfaceWithName:rssi:transmitRate:`,
`modeDidChangeForWiFiInterfaceWithName:`,
`scanCacheUpdatedForWiFiInterfaceWithName:`.
Notification names `CWSSIDDidChangeNotification`, `CWBSSIDDidChange...`,
`CWLinkDidChangeNotification`, `CWPowerDidChangeNotification`,
`CWModeDidChangeNotification`, `CWCountryCodeDidChangeNotification`,
`CWScanCacheDidUpdateNotification`, `CWLinkQualityDidChangeNotification`
(S10 constants file).

Call sequence (macOS, Wi-Fi connect):
1. `client = CWWiFiClient.sharedWiFiClient`; set delegate; start monitoring
   event types needed.
2. `iface = client.interfaceWithName:"en0"` or first of `interfaceNames`.
3. Scan: `scanForNetworksWithName:nil includeHidden:YES error:&err`
   (S11 line 42 uses `scanForNetworksWithName:error:`; `includeHidden` from
   S10). Results are `NSSet`. Hammerspoon picks `anyObject` for a named
   SSID (S11 line 160).
4. Connect: `associateToNetwork:network password:pass error:&err`
   (S10; S11 line 163 uses the same selector family). Enterprise:
   `associateToEnterpriseNetwork:identity:username:password:error:` (S10).
5. Disconnect: `disassociate` (S10, S11 line 127).
6. Power: `setPower:error:` (S10, S11 line 96).

Redaction and authorization (the critical item; verified from S10 and S11):
* S10 (CWNetwork.rs lines 38, 52, 66, 98): SSID (`ssid`, `ssidData`), BSSID
  (`bssid`), and country code are not available "unless Location Services is
  enabled and the user has authorized the calling app to use location
  services", with a "See also: CLLocationManager" reference. S10 also says
  `ssid` returns nil when the SSID cannot be encoded as UTF-8 or WinLatin1.
* S11 (Hammerspoon `hs.wifi` doc comment, libwifi.m line ~338): the
  current-network `bssid` key needs `hs.location` started.
* The previous attempt's native-apple review (local, not read here) reports
  the same redaction (lead only).
* Exactly which fields are nil without authorization: ssid, ssidData, bssid,
  countryCode (S10). RSSI, channel, security, interfaceMode, transmit rate are
  not listed as redacted in S10 `(single-source; absence of statement)`.
* Requirements: `NSLocationUsageDescription` Info.plist key (Apple page title
  present; body unreadable, S14). Entitlement
  `com.apple.security.personal-information.location` (UNVERIFIED in this
  spike). TCC prompt via CoreLocation authorization (UNVERIFIED as to
  `CLLocationManager` flow in this spike). The macOS version where redaction
  began (the brief says macOS 14) is `(UNVERIFIED)`: the TN3179 technote
  URL returned 404.
* A plain CLI or daemon that is not an app bundle is `(UNVERIFIED)` as able
  to receive location authorization; this is the main risk for SSID labels
  on macOS (section 6).

Pitfalls:
* Scan and associate calls block for their duration `(UNVERIFIED in this
  spike; the previous review says so, and S10 method docs were not read in
  full)`. Run them on the worker thread (ARCHITECTURE.md).
* `CWKeychain` APIs are marked deprecated in S10 (`CWKeychain*` pages). Do
  not use them for saved-password reads.
* `CWNetworkProfile` has `ssid`/`ssidData`/`setSsidData:` (S10); profile
  writes are not the same as Wi-Fi-network-level joins.

#### 2.2.2 Apple80211 (private framework; `(UNVERIFIED)` behaviour)

Verified export names (S13): the newosxbook article lists `Apple80211Open`,
`Apple80211Close`, `Apple80211BindToInterface`, `Apple80211GetIfListCopy`,
`Apple80211GetInterfaceNameCopy`, `Apple80211GetInfoCopy`,
`Apple80211GetPower`, `Apple80211SetPower`, `Apple80211Scan`,
`Apple80211ScanAsync`, `Apple80211ScanDynamic`, `Apple80211Associate`,
`Apple80211Associate2`, `Apple80211Disassociate`, `Apple80211Get`,
`Apple80211Set`, `Apple80211CopyValue`, `Apple80211StartMonitoringEvent`,
`Apple80211StopMonitoringEvent`, `Apple80211EventMonitoringInit`,
`Apple80211MaxLinkSpeed`, `Apple80211GetVirtualIfListCopy` (from `nm`/`jtool`
output in S13, article from a 2010s-era macOS; the OS version is not stated
in the fetched text `(UNVERIFIED OS version)`).

Call sequence (guess in S13; `(UNVERIFIED)`): `Apple80211Open` →
`Apple80211GetIfListCopy` → `Apple80211BindToInterface` → `Apple80211Scan`
/ `Apple80211Associate*` / `Apple80211GetInfoCopy`.

Status: S13 says public CoreWLAN goes through the private CoreWiFi framework
and `wifid`, and that Apple80211 "days are limited" on OS X. Use only as a
`*_private.c3` backend at lower priority and resolve symbols with `bleu::dl`
(ARCHITECTURE.md rule). Usage examples found by search (Tencent Cloud Q&A,
cnblogs, wpa_supplicant MobileApple80211 docs at docs.ros.org) were seen only
as search snippets, not read `(UNVERIFIED)`.

`CoreWiFi.framework` private classes `CWFInterface`, `CWFScanParameters`: not
verified in this spike `(UNVERIFIED)`.

#### 2.2.3 SystemConfiguration (route for IP and reachability)

Not verified in this spike (Apple pages unreadable; no SystemConfiguration
header fetched). Keys named in the brief (`State:/Network/Global/IPv4`,
`State:/Network/Interface/en0/AirPort`, `SCNetworkInterfaceCopyAll`,
`SCNetworkReachability`) are `(UNVERIFIED)`. Recommend a header check before
use.

#### 2.2.4 VPN (macOS)

`NEVPNManager` page exists (S14, JS-rendered), body not read `(UNVERIFIED)`.
`scutil --nc list` / `scutil --nc start|stop` CLI route `(UNVERIFIED)`.

#### 2.2.5 Hotspot and NEHotspotConfigurationManager

`NEHotspotConfigurationManager` page exists (S14), body not read
`(UNVERIFIED)` for macOS availability. It is the iOS-style join API; treat as
`(UNVERIFIED)` for desktop use.

#### 2.2.6 CLI status

`networksetup` and `airport` (the brief says `airport` was removed in macOS
14.4): not verified in this spike `(UNVERIFIED)`.

#### 2.2.7 Keychain

`security find-generic-password -D "AirPort network password"` (brief):
`(UNVERIFIED)`. Do not implement password reads from the keychain in v1.

### 2.3 Windows

#### 2.3.1 Native Wi-Fi (WLAN) API

Verified constant values come from `windows-sys 0.59.0` (S15, generated from
the Windows metadata). Function behaviour from `learn.microsoft.com` pages
(S16). The `rs-wifi 0.1.8` crate (S17) is a second source for call usage.

Functions in use (names verified in S16/S17): `WlanOpenHandle`,
`WlanCloseHandle`, `WlanEnumInterfaces`, `WlanScan`, `WlanGetNetworkBssList`,
`WlanGetAvailableNetworkList`, `WlanQueryInterface`, `WlanSetProfile`,
`WlanConnect`, `WlanDisconnect`, `WlanDeleteProfile`,
`WlanRegisterNotification` (S16). `WlanSetProfile` and `WlanConnect` are
called in S17 (`platform/win/interface.rs` lines 142, 163). `WlanScan` is
called in S17 line 31.

Interface states (S15 values): connected=1, disconnected=4, associating=5,
discovering=6, authenticating=7. Other values `(UNVERIFIED)`.

Connection parameters (`WLAN_CONNECTION_PARAMETERS`, S15 struct exists; S16
constraints):
* `wlanConnectionMode`: profile=0, temporary_profile=1, discovery_secure=2,
  discovery_unsecure=3, auto=4, invalid=5 (S15).
* `dwFlags`: WLAN_CONNECTION_HIDDEN_NETWORK=1, WLAN_CONNECTION_ADHOC_JOIN_ONLY=2,
  WLAN_CONNECTION_IGNORE_PRIVACY_BIT=4 (S15).
* Constraints (S16, verbatim sense): profile mode needs a non-NULL
  `strProfile` with nonzero length; discovery modes need `pDot11Ssid`;
  `wlan_connection_mode_invalid` and `auto` are not valid for `WlanConnect`
  `(as listed)`.
* Hidden networks: discovery mode with `pDot11Ssid` (S16), or the hidden flag
  for independent BSS (S16 constraint list).

Notifications (`WlanRegisterNotification`, S16):
* Sources (S15 values): NONE=0, ONEX=4, SECURITY=32, ACM=8, MSM=16, IHV=64,
  HNWK=128, ALL=0xFFFF (65535).
* `WLAN_NOTIFICATION_SOURCE_MSM` requires the `wiFiControl` device capability;
  without it the call returns `ERROR_ACCESS_DENIED`. Requesting that
  capability requires user consent about location (S16 verbatim sense).
* Callback rules (S16): "Don't call WlanRegisterNotification from a callback
  function." Unregistering (`SOURCE_NONE`) while a callback is running waits
  for the callback to finish. Registrations end when the handle is closed or
  the process ends.
* ACM codes (S15 values): start=0, autoconf_enabled=1, autoconf_disabled=2,
  background_scan_enabled=3, background_scan_disabled=4,
  power_setting_change=6, scan_complete=7, scan_fail=8, connection_start=9,
  connection_complete=10, connection_attempt_fail=11, filter_list_change=12,
  interface_arrival=13, interface_removal=14, profile_change=15,
  profile_name_change=16, profiles_exhausted=17, network_not_available=18,
  network_available=19, disconnecting=20, disconnected=21,
  adhoc_network_state_change=22, profile_unblocked=23,
  screen_power_change=24, profile_blocked=25, scan_list_refresh=26,
  operational_state_change=27, end=28. (Payload struct for each is `(UNVERIFIED)`.)

Scan results: `WlanGetAvailableNetworkList` (S16 page exists; the
`WLAN_AVAILABLE_NETWORK` flags CONNECTED=1, HAS_PROFILE=2 per S15;
`INCLUDE_ALL_MANUAL_HIDDEN_PROFILES` value 2 per S15 `(single-source)`).
`WlanGetNetworkBssList` returns `WLAN_BSS_ENTRY` (S15 struct exists; field
layout and the SSID type `DOT11_SSID` (S15 struct exists) are `(UNVERIFIED)`
in this spike, since the dot11ssid page returned 404).

Auth/cipher numeric values (S15, DOT11_AUTH_ALGO_* / DOT11_CIPHER_ALGO_*):
* Auth: OPEN=1, SHARED_KEY=2, WPA=3, WPA_PSK=4, WPA_NONE=5, RSNA=6,
  RSNA_PSK=7, WPA3=8, WPA3_ENT_192=8 (collision), WPA3_SAE=9, OWE=10,
  WPA3_ENT=11.
* Cipher: NONE=0, WEP40=1, TKIP=2, CCMP=4, WEP104=5, GCMP=8, GCMP_256=9,
  CCMP_256=10, WEP=257.

Profile XML (`WlanSetProfile`): authentication enum (S18, Microsoft
authEncryption page, verified): `open`, `shared`, `WPA`, `WPAPSK`, `WPA2`,
`WPA2PSK`, `WPA3` (deprecated, synonymous with WPA3ENT192), `WPA3ENT192`,
`WPA3ENT`, `WPA3SAE`, `OWE`. The sample profile for WPA3 transition uses
`WPA3SAE` with `transitionMode` true (S18 search snippet and S18 text).
`keyType` `passPhrase` with `protected`/`keyMaterial` is used in S17
(profile.rs line 127). Encryption enum values (`AES`, `TKIP`, `none`) were not
read on the page `(UNVERIFIED beyond S17 usage)`.
PEAP / 802.1X profile elements: `(UNVERIFIED)` in this spike.

Pitfalls (Windows, WLAN):
* Unregister inside a callback deadlocks or fails (S16 rule above).
* MSM notifications need packaging/consent; a plain Win32 process may only
  receive ACM notifications `(single-source: S16 text; packaging detail
  UNVERIFIED)`.
* The Win32 constant `WPA3` and `WPA3_ENT_192` share value 8 (S15). Map by
  name, not by value, when translating.

#### 2.3.2 Windows.Devices.Radios (airplane mode / radio control, consent)

`Radio` class page exists (S19). Text read: `RequestAccessAsync` "Requests
permission to control radios and returns a RadioAccessStatus indicating the
current …" and `SetStateAsync` "for state management, use SetStateAsync to
turn radios on or off programmatically", and user consent "depending on
regional settings and system configuration" (S19). `RadioAccessStatus`
values `(UNVERIFIED)`. Airplane mode is a separate page `(UNVERIFIED)`.

#### 2.3.3 Mobile hotspot

WinRT `Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager`
page exists (S20); members not read `(UNVERIFIED)`. `WlanHostedNetwork*`
legacy API: `(UNVERIFIED)` status.

#### 2.3.4 IP Helper and connectivity

Pages exist and were fetched (S21): `GetAdaptersAddresses`,
`GetIfTable2` (netioapi), `NotifyUnicastIpAddressChange`,
`NotifyRouteChange2` (netioapi). Function names are verified by URL only;
signatures and struct layouts `(UNVERIFIED)` in this spike.

Connectivity: `INetworkListManager` (COM, S22) and WinRT
`Windows.Networking.Connectivity` (`NetworkInformation`, S23) pages exist.
Members and the IID values were not extracted `(UNVERIFIED)`.

#### 2.3.5 VPN (Windows)

RAS: `RasEnumConnectionsA` (S24) and `RasDialA` (S24) pages exist. Struct
layouts `(UNVERIFIED)`. PowerShell `Get-VpnConnection` page exists (S25);
members `(UNVERIFIED)`.

#### 2.3.6 Permissions (Windows)
* WLAN MSM notifications and some scan data depend on `wiFiControl`
  capability and location consent (S16).
* UAC: scanning and profile writes for all-users profiles are `(UNVERIFIED)`
  in this spike.

## 3. Reference implementations (prove it works)

| Project | Language | Source used (URL) | Read or README only | What to copy the idea of |
| --- | --- | --- | --- | --- |
| nmrs 3.5.6 | Rust | `https://static.crates.io/crates/nmrs/nmrs-3.5.6.crate` (extracted) | Read: `types/constants.rs`, `api/models/access_point.rs` (flag table), `api/builders/wifi_builder.rs` (key-mgmt strings), `agent/iface.rs` (SecretAgent methods) | Settings dict shape, AP flags table, secret-agent request/cancel/save/delete mapping, validation (WPA 8-63 chars; SAE min not enforced) |
| networkmanager 0.5.0 | Rust | `https://static.crates.io/crates/networkmanager/networkmanager-0.5.0.crate` | Extracted, not read | Alternative bindings; not used |
| iwdrs 0.1.0 | Rust | `https://static.crates.io/crates/iwdrs/iwdrs-0.1.0.crate` | Read: station.rs, netowrk.rs, agent.rs, known_netowk.rs, device.rs, adapter.rs (member lines) | iwd member names and call shapes |
| objc2-core-wlan 0.3.0 | Rust | `https://static.crates.io/crates/objc2-core-wlan/objc2-core-wlan-0.3.0.crate` | Read: generated CWNetwork.rs, CWWiFiClient.rs, CWInterface.rs (doc lines + method list), CoreWLANConstants.rs | Exact CoreWLAN selectors; redaction notes |
| rs-wifi 0.1.8 | Rust | `https://static.crates.io/crates/rs-wifi/rs-wifi-0.1.8.crate` | Read: profile.rs lines 17-232 (XML), platform/win/interface.rs (WlanScan line 31, WlanConnect line 142, WlanSetProfile line 163), platform/win/util.rs (AKM mapping) | Windows profile XML, call order |
| Hammerspoon hs.wifi | Obj-C / Lua | `https://raw.githubusercontent.com/Hammerspoon/hammerspoon/master/extensions/wifi/libwifi.m`, `.../wifi/wifi.lua` | Read: libwifi.m (grep-level for CoreWLAN calls and doc comments); wifi.lua in full | CoreWLAN in real use (scan, associate, power, disassociate) |
| DankMaterialShell network backend | Go | `https://raw.githubusercontent.com/AvengeMedia/DankMaterialShell/master/core/internal/server/network/backend.go` | Read in full (interface only) | Backend surface for a shell: Wi-Fi, Ethernet, cellular, VPN, hotspot, state, prompt broker (`GetPromptBroker`, `SubmitCredentials`, `CancelCredentials`) |
| NetworkManager (source) | C | `https://gitlab.freedesktop.org/NetworkManager/NetworkManager/-/raw/main/src/core/supplicant/nm-supplicant-interface.c`, mirror `.../nm-supplicant-config.c` | Grep-level | key-mgmt token map (OWE, SAE, WPA-EAP, IEEE8021X, NONE); SSID byte handling |
| NM introspection XML | XML | `https://gitlab.freedesktop.org/NetworkManager/NetworkManager/-/raw/main/introspection/*.xml` | Read in full (parsed) | Member signatures |
| NM API reference | HTML | `https://networkmanager.dev/docs/api/latest/nm-dbus-types.html` | Read (parsed to text) | Enum values |
| iwd docs | text | `https://git.kernel.org/pub/scm/network/wireless/iwd.git/plain/doc/{agent,station,network,knownnetwork,device}-api.txt` | Read in full | iwd method/property contract |
| wpa_supplicant D-Bus | HTML | `https://w1.fi/wpa_supplicant/devel/dbus.html` | Read (grep + parsed) | BSS/Network/Interface shapes |
| Kernel sysfs ABI | text | `https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-class-net` | Read (grep) | carrier, operstate, speed |
| windows-sys 0.59.0 | Rust | `https://static.crates.io/crates/windows-sys/windows-sys-0.59.0.crate` | Read (grep of constants and struct names) | Numeric WLAN/DOT11 constants |
| Previous attempt `forks/nmrs` | Rust (local) | `<scratchpad>/rust_prev/desktop-systems/forks/nmrs/` | Grep only | Confirms the same SecretAgent layout |
| Previous attempt reviews | md (local) | `<scratchpad>/rust_prev/desktop-systems/reviews/{native-apple,native-windows}.md` | Read (grep) | Leads only; their cargo-path citations were not reachable |
| Not researched | | | | Quickshell `Quickshell.Networking`, KDE plasma-nm, gnome-network-panel, `wifi-rs`, `wlanapi-rs`, `kawaiifi`, `wifiscanner`, `wlctl` (crates.io listing only), `iwctl` source, `nmcli` source, Lunar, Seelen UI, Zebar, PowerToys |

Coverage honesty: NM, iwd, CoreWLAN (bindings), and WLAN constants were
checked against two independent sources in most cases. Windows routes beyond
WLAN (IP Helper, COM, WinRT, RAS, Radios, hotspot) only had their Learn page
existence checked, so their signatures are UNVERIFIED.

## 4. Double validation

Source key:
* S1 NM introspection XML (gitlab raw, `main`).
* S2 NM API reference `nm-dbus-types` (networkmanager.dev).
* S3 nmrs 3.5.6 source (crates.io tarball).
* S4 NM source `nm-supplicant-config.c` (GitHub mirror raw) and
  `nm-supplicant-interface.c` (gitlab raw).
* S5 iwd docs (git.kernel.org plain).
* S6 iwdrs 0.1.0 source.
* S7 wpa_supplicant D-Bus doc (w1.fi).
* S8 kernel sysfs-class-net ABI (kernel.org).
* S9 kernel networking statistics doc (docs.kernel.org).
* S10 objc2-core-wlan 0.3.0 generated bindings (crates.io tarball).
* S11 Hammerspoon `libwifi.m` and `wifi.lua` (raw GitHub).
* S12 Apple doc page title, NSLocationUsageDescription (JS-only; title only).
* S13 newosxbook.com Apple80211 article (export list from `nm`/`jtool`).
* S14 developer.apple.com NEVPNManager / NEHotspotConfigurationManager (title only).
* S15 windows-sys 0.59.0 (crates.io tarball).
* S16 learn.microsoft.com WLAN pages: WlanRegisterNotification, WlanConnect,
  WlanGetAvailableNetworkList, WlanGetNetworkBssList, WlanScan.
* S17 rs-wifi 0.1.8 source (crates.io tarball).
* S18 learn.microsoft.com authEncryption schema page.
* S19 learn.microsoft.com Windows.Devices.Radios.Radio.
* S20 learn.microsoft.com NetworkOperatorTetheringManager (exists only).
* S21 learn.microsoft.com IP Helper pages (exist only).
* S22 learn.microsoft.com INetworkListManager (exists only).
* S23 learn.microsoft.com Windows.Networking.Connectivity (exists only).
* S24 learn.microsoft.com RasEnumConnectionsA / RasDialA (exist only).
* S25 learn.microsoft.com Get-VpnConnection (exists only).

Claim-by-claim (section 2 claims):

| Claim | Sources | Status |
| --- | --- | --- |
| NM bus name, root path, `GetDevices`, `AddAndActivateConnection2` signature | S1, S3 (uses it) | 2 sources |
| `Device.Wireless.RequestScan(a{sv})`, `GetAllAccessPoints`, `Strength` 0-100 | S1 (names and types); S3 | 2 sources (Strength range from S1 type `y` only; 0-100 is `(single-source: S1 doc name "Strength"; range not read)`) |
| AP `Ssid` is `ay` | S1, S4 (`nm-supplicant-interface.c` byte handling) | 2 sources |
| AP flag bits (PRIVACY 0x1, PSK 0x100, 802_1X 0x200, SAE 0x400, OWE 0x800, OWE_TM 0x1000, SUITE_B 0x2000) | S2, S3 | 2 sources |
| WPA/RSN property that carries PSK/SAE | S3 comments only | `(single-source)` |
| Device state values 0-120 | S2, S3 (subset: 20, 30, 100, 120) | 2 sources for the subset; full list `(single-source: S2)` |
| StateReason codes (NO_SECRETS=7, SSID_NOT_FOUND=53, NEW_ACTIVATION=60, CARRIER=40, USER_REQUESTED=39, DHCP_FAILED=17, SUPPLICANT_*=9/10/11) | S2 (values); names also in S1 `StateReason` description | `(single-source: S2)` for values |
| Active connection state and reasons | S2 | `(single-source)` |
| Connectivity NONE=1, PORTAL=2, LIMITED=3, FULL=4 | S2, S1 (method name `CheckConnectivity`) | `(single-source: S2 for values)` |
| WIFI=2, ETHERNET=1 device types | S2 (names), S3 (values) | 2 sources |
| MODEM=8 | S3 (value), S2 (name) | 2 sources |
| SecretAgent method signatures | S1 (XML), S3 (code `iface.rs`) | 2 sources |
| AgentManager `Register`/`Unregister` | S1 (XML), S3 (builder.rs uses `AgentManagerProxy`) | 2 sources |
| `NM_SECRET_AGENT_GET_SECRETS_FLAG_ALLOW_INTERACTION = 0x1` | S2, S3 (comments) | 2 sources |
| Secret flags AGENT_OWNED 0x1, NOT_SAVED 0x2, NOT_REQUIRED 0x4 | S3 (commented constants) | `(single-source)` |
| key-mgmt strings `wpa-psk`, `sae`, `owe`, `wpa-eap` | S3 (builder), S4 (`owe`, `sae` branches) | 2 sources |
| `"ssid"` as `ay` in `802-11-wireless` | S3 (builder uses it `(single-source: not read line-by-line)`) | `(single-source)` |
| iwd `Scan`, `Disconnect`, `GetOrderedNetworks` (a(on), int16 100×dBm) | S5, S6 (`station.rs` lines 67-95) | 2 sources |
| iwd `Network.Connect`, `Name` (string), `Type` (open/wep/psk/8021x) | S5, S6 (`netowrk.rs`) | 2 sources |
| iwd `Agent.RequestPassphrase(o) -> s` | S5, S6 (`agent.rs` line 62-63) | 2 sources |
| iwd SAE/OWE exposed | none | `(UNVERIFIED)` |
| iwd SSID as bytes | S5 (string type) | `(single-source: inference)` |
| wpa_supplicant BSS `SSID` `ay`, `Privacy` `b`, `Frequency` `q` | S7 | `(single-source: S7; S7 is an old doc)` |
| wpa_supplicant `KeyMgmt` values `wpa-psk`, `wpa-eap`, `wpa-none` | S7 | `(single-source)` |
| wpa_supplicant tokens `SAE` and `OWE` | S4 (NM passes them) | `(single-source)`; S7 lacks them (doc drift) |
| sysfs `carrier`, `operstate`, `speed` | S8 | `(single-source: kernel ABI)`; other doc copies not read |
| Kernel counters `rx_bytes`, `tx_bytes`, `rx_packets`, `tx_packets` | S9 | `(single-source)` |
| CoreWLAN selectors (`associateToNetwork:password:error:`, `setPower:error:`, `disassociate`, `scanForNetworksWithName:includeHidden:error:`) | S10 (bindings), S11 (`libwifi.m` uses them) | 2 sources |
| CoreWLAN `interfaceWithName:`, `sharedWiFiClient`, delegate methods | S10, S11 (`CWWiFiClient sharedWiFiClient`, `interfaceWithName`) | 2 sources |
| SSID/BSSID/countryCode require Location Services auth | S10 (doc comments), S11 (`bssid` note: hs.location needed) | 2 sources |
| Exact macOS version of the redaction | none | `(UNVERIFIED)` (brief's "macOS 14" claim) |
| Entitlement `com.apple.security.personal-information.location` | none | `(UNVERIFIED)` |
| Apple80211 exports | S13 (`nm`/`jtool` listing), search snippets (docs.ros.org wpa_supplicant `MobileApple80211.h`) | `(single-source)` for the list; snippet only for the second |
| Apple80211 call sequence | S13 (labelled as a guess) | `(UNVERIFIED)` |
| WLAN_NOTIFICATION_SOURCE values | S15 (values), S16 (names, MSM capability rule) | 2 sources |
| MSM needs `wiFiControl`, else `ERROR_ACCESS_DENIED` | S16 | `(single-source)` |
| Don't call WlanRegisterNotification from a callback; unregister waits for callback | S16 | `(single-source)` |
| WLAN_CONNECTION_PARAMETERS mode values and flags | S15 (values), S16 (names/constraints), S17 (uses `WlanConnect`) | 2 sources |
| ACM notification codes | S15 (values), S16 (names `connection_complete`, `disconnected`) | 2 sources for names used; the rest `(single-source: S15)` |
| DOT11_AUTH_ALGO values | S15 only | `(single-source)` |
| Profile authentication strings (`WPA2PSK`, `WPA3SAE`, `OWE`, `WPA3ENT192`, `WPA3`) | S18 (MS schema page), S17 (`WPA2PSK` in profile.rs) | 2 sources |
| `WPA3` deprecated alias of WPA3ENT192 | S18 | `(single-source)` |
| `keyType` `passPhrase` | S17 (profile.rs line 127) | `(single-source)` |
| Radio consent for SetStateAsync | S19 | `(single-source)` |
| Hotspot WinRT class exists | S20 (page title) | `(single-source; members UNVERIFIED)` |
| IP Helper function names | S21 (URLs) | `(UNVERIFIED signatures)` |
| RAS function names | S24 (URLs) | `(UNVERIFIED structs)` |

Discrepancies noticed (for the lead):
1. `DOT11_AUTH_ALGO_WPA3 == DOT11_AUTH_ALGO_WPA3_ENT_192 == 8` (S15); the
   profile schema (S18) calls `WPA3` deprecated and equal to WPA3ENT192. Consistent,
   but two enum names share one value: map by name.
2. NM DBus doc value 73 appears twice (UNMANAGED_SLEEPING and
   UNMANAGED_MANAGER_DISABLED) in the parsed S2 text. Likely a doc error;
   check the NM header before coding the table.
3. NM introspection XML has a legacy `state()` method (S1) next to the
   `State` property. Use the property.
4. wpa_supplicant doc (S7) predates SAE/OWE support that NM uses (S4).

## 5. Proposed Bleu model

Platform-neutral types, in the style of ARCHITECTURE.md (`State` = plain data;
`Cap` enum; `Event` transients; commands return `Operation`). Byte-valued
SSIDs are `ubyte[]`; display label is `String`. Quantities are `typedef`s
(`Dbm`, `Percent`, `MegaHertz`, `Mbps`). Not compiled; sketch only.

```c3
module bleu::network;

typedef Dbm = int;              // Wi-Fi RSSI in dBm (negative); NM Strength is not dBm
typedef Percent = ubyte;        // 0..100 quality (NM AP Strength)
typedef MegaHertz = uint;       // channel frequency MHz (AP Frequency u / wpa_supplicant q)
typedef Mbps = uint;            // link speed (sysfs speed Mbit/s; NM MaxBitrate is kb/s - convert)
typedef Bytes = ulong;          // traffic counters

enum Radio : char { WIFI, CELLULAR }                             // closed set; extend as needed
enum Band : char { UNKNOWN, GHZ_2_4, GHZ_5, GHZ_6 }
enum Security : char { OPEN, WEP, WPA_PSK, WPA2_PSK, WPA3_SAE, WPA2_WPA3_TRANSITION, OWE, ENTERPRISE_8021X, UNKNOWN }
enum ConnectivityLevel : char { UNKNOWN, NONE, PORTAL, LIMITED, FULL }    // NM 0..4, Windows NLM equivalents
enum LinkState : char { UNKNOWN, DOWN, UP, DORMANT }
enum ConnState : char { IDLE, CONNECTING, AUTH_REQUIRED, OBTAINING_ADDRESS, CONNECTED, DISCONNECTING, FAILED }
enum FailReason : char { NONE, UNKNOWN, WRONG_SECRET, NO_SECRETS, SSID_NOT_FOUND, TIMEOUT, DHCP_FAILED, CARRIER_LOST, USER_CANCELLED, DEPENDENCY_FAILED, PERMISSION_DENIED, BACKEND_LOST }
// Mapping: NM DeviceStateReason (section 2.1.1c) -> FailReason; WLAN ACM reason -> FailReason.

struct Ssid {                    // raw bytes are the identity; label is display only
    ubyte[] bytes;               // 0..32 octets, may be non-UTF-8 (iwd cannot provide this)
    String label;                // "" when bytes are not UTF-8 or redacted (macOS without Location)
}

struct WifiNetwork {
    Ssid ssid;
    String bssid;                // "" when redacted (macOS) or hidden
    MegaHertz frequency;
    uint channel;
    Band band;
    Dbm rssi;                    // unavailable: use Percent only (NM)
    Percent quality;
    Security security;
    bool in_use;
    bool known;                  // saved profile exists
    bool autoconnect;            // meaningful only when known
    String profile_id;           // NM uuid / iwd KnownNetwork path / WLAN profile name
}

struct WifiState {
    bool radio_enabled;          // NM WirelessEnabled; WLAN interface power; CoreWLAN powerOn
    bool hardware_blocked;       // NM WirelessHardwareEnabled
    bool scanning;
    String interface_name;
    String ssid_connected_label; // only when connected
    Dbm connected_rssi;
    WifiNetwork[] networks;      // slice; newest scan snapshot
    ConnState connection;
    FailReason last_failure;
}

struct EthernetState { String interface_name; bool carrier; LinkState link; Mbps speed; bool present; }
struct CellularState { bool present; bool enabled; String operator_name; Percent signal; }   // P2
struct VpnProfile { String id; String name; bool active; bool is_plugin_type; }
struct IpConfig { String[] addresses; String gateway; String[] dns; bool metered; }
struct Counters { String interface_name; Bytes rx; Bytes tx; }

struct NetworkState {                 // immutable snapshot, published via Observable{NetworkState}
    ConnectivityLevel connectivity;
    String primary_interface;
    String primary_kind;              // "wifi" | "ethernet" | "cellular" | "vpn"
    WifiState wifi;
    EthernetState[] ethernet;
    CellularState cellular;
    VpnProfile[] vpns;
    IpConfig ip;
    Counters[] counters;
    bool airplane_mode;
    String backend;                   // "networkmanager" | "iwd" | "wlan" | "corewlan" ...
}

enum Cap : char {
    WIFI_RADIO_SET, WIFI_SCAN, WIFI_CONNECT_PSK, WIFI_CONNECT_OPEN, WIFI_CONNECT_ENTERPRISE,
    WIFI_CONNECT_HIDDEN, WIFI_DISCONNECT, WIFI_FORGET, WIFI_AUTOCONNECT_SET,
    WIFI_SECRET_PROMPT, WIFI_SSID_BYTES, WIFI_SSID_LABEL_REDACTED,
    ETHERNET_STATE, ETHERNET_SPEED, COUNTERS,
    CONNECTIVITY_CHECK, IP_CONFIG_READ, AIRPLANE_SET,
    VPN_LIST, VPN_ACTIVATE, VPN_DEACTIVATE,
    CELLULAR_STATE, HOTSPOT_START, HOTSPOT_STOP,
}

// Errors are excuses from bleu::error (STYLE.md), not faults.

enum Event : char { WIFI_LIST_CHANGED, WIFI_STATE_CHANGED, SECRET_REQUESTED, CONNECTIVITY_CHANGED, VPN_CHANGED, DEVICE_ADDED, DEVICE_REMOVED, AIRPLANE_CHANGED }
// SECRET_REQUESTED carries (token, ssid bytes, reason) and is answered via submit_secrets(token, ...).

struct SecretRequest { String token; Ssid ssid; String profile_id; SecretKind kind; }
enum SecretKind : char { PSK, ENTERPRISE_IDENTITY_PASSWORD, WEP_KEY, OTP }

struct ConnectOptions { Ssid ssid; bool hidden; SecurityRequest security; String passphrase; String identity; String username; String password; bool autoconnect; }
enum SecurityRequest : char { AUTO, OPEN, PSK, SAE, OWE, ENTERPRISE }

struct Options { String backend; bool allow_private_apis; }   // backend = "" for probe order

// Backend order (priority per OS, first that opens wins):
//   linux:   networkmanager -> iwd -> wpa_supplicant (fallback, Wi-Fi only)  [ConnMan: cut]
//   macos:   corewlan -> apple80211_private (only with allow_private_apis)  [sysconfig for IP]
//   windows: wlan_api (Wi-Fi) + iphelper (IP/counters) + nlm (connectivity) + ras (VPN) + radios (airplane)
```

Platform-unavailable fields (for `Cap`):
* SSID raw bytes: available on NM and wpa_supplicant (`ay`) and WLAN API
  (`DOT11_SSID`, `(UNVERIFIED)` field layout); not on iwd (string); on
  macOS only `ssidData` with Location authorization.
* BSSID: NM (AP `HwAddress`), wpa_supplicant (BSS), WLAN (BSS entry);
  redacted on macOS without Location.
* dBm: NM only gives Strength (0-100); dBm needs a different property
  `(UNVERIFIED)`. iwd gives 100×dBm via GetOrderedNetworks. CoreWLAN gives
  `rssiValue`. WLAN gives RSSI in BSS entry `(UNVERIFIED field)`.
* Hotspot: NM AP mode via `Mode` (AP=3); Windows via tethering manager
  `(UNVERIFIED)`; macOS `startIBSSModeWithSSID` is IBSS, not AP (S10 lists
  HostAP mode constant in Hammerspoon `kCWInterfaceModeHostAP`, S11 line 446).

## 6. Risks and cut lines

What is hard:
1. macOS SSID labels need Location Services authorization for the calling
   app (S10). A CLI or daemon without an app bundle, Info.plist and
   entitlement may never see SSIDs. This is the largest product risk for
   the `corewlan` backend. Recommend: design the snapshot so SSIDs can be
   empty and show BSSID-less rows.
2. Windows MSM notifications require the `wiFiControl` capability and user
   consent (S16). Win32 apps may only get ACM events; test on a packaged
   build before promising MSM events.
3. Linux credential prompts need an NM secret agent registered on the system
   bus (S1, S3). A daemon that is not running under the user's session may not
   be able to show UI; the design must route prompts to the shell (event
   `SECRET_REQUESTED` + `submit_secrets`), which the DankMaterialShell
   backend models with `GetPromptBroker` / `SubmitCredentials` /
   `CancelCredentials` (S12, section 3).
4. iwd cannot provide SSID bytes or SAE/OWE state through the documented
   surface (section 2.1.2). Acceptable only as a fallback.
5. macOS private Apple80211 is unstable across OS versions (S13); keep it
   behind `bleu::dl` and a `Cap`, or cut it.
6. Wrong-passphrase reason code is not verified (section 2.1.1c).
7. Windows RAS, IP Helper, WinRT connectivity and tethering signatures were
   not read (section 3 coverage note). Each needs its own header/Learn read
   before implementation.

Cannot be done without private API or admin rights (as far as this spike
found):
* macOS: SSID and BSSID of other networks without Location authorization;
  keychain password reads (deprecated CWKeychain, S10); Apple80211 association
  (private).
* Linux: creating profiles or changing NM settings usually needs polkit
  authorization (UNVERIFIED exact actions).
* Windows: all-users WLAN profiles and MSM events need admin or capability
  (UNVERIFIED for profiles; S16 for MSM).
* Airplane mode on Windows: needs radio access consent (S19).

Recommended cut lines:
* v1 (must): Linux NM backend (Wi-Fi scan/connect PSK+open/disconnect/forget/
  autoconnect, secret agent, Ethernet via NM + sysfs, connectivity,
  primary connection, sysfs counters); macOS CoreWLAN (scan, connect PSK+open,
  disconnect, power, events, redacted-SSID handling); Windows WLAN API
  (scan, list, connect via profile PSK+open, disconnect, ACM events,
  GetIfTable2 counters).
* v1.1: enterprise 802.1X credentials on all three; hidden SSID connect;
  VPN list/activate (NM VPN, RAS); IP config read; airplane mode (NM
  `WirelessEnabled`/`Enable`; Windows radios with consent).
* v2 or cut: iwd backend, wpa_supplicant fallback, ConnMan, macOS
  Apple80211 private, Windows hosted network, hotspot/AP mode on all three,
  cellular (ModemManager not researched), NEHotspotConfigurationManager.

Spike limits: nothing was run on hardware or against a live NM, iwd,
CoreWLAN, or WLAN service. No compiler or C3 checks were run. Every "works"
claim above is a documentation claim.

## Supporting source list (fetched during this spike)

S1 `https://gitlab.freedesktop.org/NetworkManager/NetworkManager/-/raw/main/introspection/org.freedesktop.NetworkManager{,.Device,.Device.Wireless,.AccessPoint,.Settings.Connection,.SecretAgent,.AgentManager,.Connection.Active,.VPN.Connection}.xml`
S2 `https://networkmanager.dev/docs/api/latest/nm-dbus-types.html`
S3 `https://static.crates.io/crates/nmrs/nmrs-3.5.6.crate`
S4 `https://raw.githubusercontent.com/NetworkManager/NetworkManager/main/src/core/supplicant/nm-supplicant-config.c` and `https://gitlab.freedesktop.org/NetworkManager/NetworkManager/-/raw/main/src/core/supplicant/nm-supplicant-interface.c`
S5 `https://git.kernel.org/pub/scm/network/wireless/iwd.git/plain/doc/{agent,station,network,knownnetwork,device}-api.txt`
S6 `https://static.crates.io/crates/iwdrs/iwdrs-0.1.0.crate`
S7 `https://w1.fi/wpa_supplicant/devel/dbus.html`
S8 `https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-class-net`
S9 `https://docs.kernel.org/networking/statistics.html`
S10 `https://static.crates.io/crates/objc2-core-wlan/objc2-core-wlan-0.3.0.crate`
S11 `https://raw.githubusercontent.com/Hammerspoon/hammerspoon/master/extensions/wifi/libwifi.m` and `.../wifi/wifi.lua`
S12 `https://raw.githubusercontent.com/AvengeMedia/DankMaterialShell/master/core/internal/server/network/backend.go`
S13 `https://newosxbook.com/articles/11208ellpA.html` (Part II not read)
S14 `https://developer.apple.com/documentation/networkextension/nevpnmanager`, `.../nehotspotconfigurationmanager` (titles only)
S15 `https://static.crates.io/crates/windows-sys/windows-sys-0.59.0.crate`
S16 `https://learn.microsoft.com/en-us/windows/win32/api/wlanapi/nf-wlanapi-wlanregisternotification`, `.../nf-wlanapi-wlanconnect`, `.../nf-wlanapi-wlangetavailablenetworklist`, `.../nf-wlanapi-wlangetnetworkbsslist`, `.../nf-wlanapi-wlanscan`
S17 `https://static.crates.io/crates/rs-wifi/rs-wifi-0.1.8.crate`
S18 `https://learn.microsoft.com/en-us/windows/win32/nativewifi/wlan-profileschema-authencryption-security-element`
S19 `https://learn.microsoft.com/en-us/uwp/api/windows.devices.radios.radio`
S20 `https://learn.microsoft.com/en-us/uwp/api/windows.networking.networkoperators.networkoperatortetheringmanager`
S21 `https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-getiftable2`, `.../nf-netioapi-notifyunicastipaddresschange`, `.../nf-netioapi-notifyroutechange2`, `.../iphlpapi/nf-iphlpapi-getadaptersaddresses`
S22 `https://learn.microsoft.com/en-us/windows/win32/api/netlistmgr/nn-netlistmgr-inetworklistmanager`
S23 `https://learn.microsoft.com/en-us/uwp/api/windows.networking.connectivity.networkinformation`
S24 `https://learn.microsoft.com/en-us/windows/win32/api/ras/nf-ras-rasenumconnectionsa`, `.../nf-ras-rasdiala`
S25 `https://learn.microsoft.com/en-us/powershell/module/vpnclient/get-vpnconnection`
