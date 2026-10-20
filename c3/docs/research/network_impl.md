# `bleu_network`: implementation notes

Companion to `docs/research/network.md` (sections 2, 5 and 6, the v1 cut). This file records
what was built, what was run and how, every deviation from the research, and the status of
each item the research marked UNVERIFIED. The lib README has the coverage matrix.

## 1. Deviations from the research

* **`Command` carries `Operation` pointers.** The research asks for plain-data commands. The
  service runs in-process, so `Command` holds the `Operation` that the worker completes. The
  command never leaves the process. An out-of-process backend would need a different shape.
* **Transition to WPA2-PSK.** NetworkManager's AP flags can mark a WPA/WPA2 transition network.
  `security_from_flags` (`nm_convert.c3`) maps it to WPA2_PSK. WEP is reported only when both
  the WPA and RSN flags are zero and the privacy bit is set.
* **`AUTH_REJECTED` is derived, not reported.** NetworkManager does not say "the passphrase was
  wrong". The backend reports `AUTH_REJECTED` when the NEED_AUTH state follows a connect that
  was started with a passphrase (`last_supplied`), and `AUTH_REQUIRED` when no passphrase was
  given. See section 2.1 for the reason code.
* **Wrong passphrase reason is UNVERIFIED on real NetworkManager.** The mock fails a wrong PSK
  with reason 7 (NO_SECRETS) after NEED_AUTH. Real NM may use the supplicant codes 8 to 11
  instead. The backend maps all of them to the same failure family, so either way the
  connect fails. The distinction between a wrong key and a missing key is not reliable here.
* **Passphrase in a profile.** A secured connect with a passphrase writes it into the saved
  profile, so later connects need no prompt. A secured connect without a passphrase writes a
  profile with no `psk`, so NetworkManager asks the agent.
* **Agent object path and interface.** `/org/freedesktop/NetworkManager/SecretAgent` and
  `org.freedesktop.NetworkManager.SecretAgent` are from the NetworkManager introspection XML
  (cited in the research, section 2.1.1). The `AgentManager` interface and the default object
  path are confirmed in the nmrs crate: `nmrs src/agent/builder.rs:18`
  (`DEFAULT_OBJECT_PATH`) and `src/dbus/agent_manager.rs`. Not confirmed against a real NM.
  The research deferred the secret agent until the bleu_dbus server export existed. It now
  exists, so the agent is implemented and run against the mock.
* **Profile UUID.** `uuid_for_ssid` is a 64-bit FNV-1a value, formatted as a UUID-shaped
  string. It is stable per SSID. It is not an RFC 4122 UUID, and NetworkManager does not require
  one for a profile it created itself.
* **Signal strength.** NetworkManager gives a 0-100 strength. dBm is not computed from it, so
  `WIFI_SIGNAL_DBM` is refused on Linux with a reason, and `Dbm` is empty.
* **Interface speed.** sysfs reports -1 when the speed is unknown (wlan0 in the fake root),
  and `speed_from_sysfs` turns any value at or below zero into an empty value.
* **CoreWLAN events.** The delegate is installed with `ClassBuilder` at runtime. Its IMPs only
  enqueue a refresh through a Mailbox. They do not read state.
* **CoreWLAN SSID withheld.** Without Location authorization, CoreWLAN gives empty SSID data.
  The backend publishes such an access point with an empty name and the BSSID withheld too.
  Multiple withheld access points therefore look like several entries with no name.
* **Windows profile name.** A UTF-8 SSID is the profile name. Any other SSID is named
  `bleu-` plus its hex, so every profile name is one Windows accepts.
* **Windows WLAN API failures.** WLAN reason codes are not decoded. A failed join reports
  BACKEND_FAILURE. The research listed the reason codes; decoding them is not done.
* **Windows notifications only enqueue.** `WlanRegisterNotification` callbacks enqueue a
  REFRESH command. They do not call any WLAN function from inside the callback.

## 2. Verified facts and the UNVERIFIED items

### 2.1 Linux (NetworkManager, sysfs)

Run against a private `dbus-daemon` and `tests/nm_mock.py`, a `dbus-next` mock of
`org.freedesktop.NetworkManager`, and a fake `/sys/class/net` tree. The mock implements the
members the backend uses. Its values follow the spec; its failure reasons are the mock's own.

* Device states, reason codes, AP flags and the device type codes are from the NetworkManager
  headers and the nmrs `state_reason.rs` table, as cited in `nm_convert.c3`.
* Reason 7 (NO_SECRETS) after NEED_AUTH is the mock's model of a wrong passphrase. UNVERIFIED
  on real NM (section 1).
* sysfs: `operstate`, `carrier`, `speed`, `statistics/rx_bytes` and `tx_bytes` are from the
  kernel `Documentation/ABI/testing/sysfs-class-net` and `sysfs-class-net-statistics`.
* The secret agent: GetSecrets flag `ALLOW_INTERACTION` is 0x1 (nm-dbus-types, and nmrs
  `src/agent/request.rs`). Requests without the flag are refused with NoSecrets. Verified
  end to end against the mock: a prompt is parked, `supply_credentials` answers it,
  `cancel_credentials` refuses it with UserCanceled, and a stale request is NOT_FOUND.
* Not verified: real NetworkManager's behaviour for SAE, OWE and legacy (non-UTF-8) SSIDs.
  The scenario tests cover them against the mock only.

### 2.2 macOS (CoreWLAN)

Type-checked for `macos-aarch64` and `macos-x64` only. Never run.

* Security constants, band codes, event type numbers and the kCWErr* values are from the
  objc2-core-wlan 0.3.0 crate source and the CoreWLAN headers it mirrors.
* `supportsSecurity:` is used to probe the class of an access point. Its answers are the
  driver's, so the probe order is a convention, not an Apple guarantee.
* Location authorization: `CLLocationManager authorizationStatus` through
  `CoreLocation.framework`. UNVERIFIED on macOS. The TCC prompt and the redaction behaviour
  were not observed.
* `known` and `autoconnect` cannot be read from CoreWLAN, so both are reported as unknown.

### 2.3 Windows (WLAN API, Native Wifi)

Type-checked for `windows-x64` and `windows-aarch64` only. Never run.

* Struct layouts are from the `wlanapi.h` declarations as mirrored in windows-sys 0.59.0.
  `WLAN_BSS_ENTRY.ulChCenterFrequency` is in kHz.
* Auth algorithm values (1 OPEN, 2 SHARED, 3 WPA, 4 WPA_PSK, 6 RSNA, 7 RSNA_PSK, 8 WPA3,
  9 SAE, 10 OWE, 11 WPA3_ENT) are from the same header.
* Profile XML: the namespace and element order follow the WLAN profile schema (the
  AuthEncryption element) and rs-wifi 0.1.8's profile shape. The tests check element order and
  content. No XSD is on disk, so schema validation is NOT claimed.
* IP Helper (`GetIfTable2` and related) is not bound. Interface state and counters are not
  offered on Windows.

## 3. Pitfalls found while writing

These are C3 and bindings pitfalls hit during this work. `C3_GOTCHAS.md` is not owned by this
lib, so the list is kept here.

* Enum and constant names from another module need qualification. Unqualified names resolve
  to nothing useful.
* `Settled?` cannot be a parameter type. Handlers take `SettleOp*` and complete it.
* An `interface` field name is a keyword. The field is named `iface`.
* `extern` function names must be lowercase. The Win32 symbol goes in `@cname`.
* Distinct ObjC types (ObjId) need `import std::os::darwin::objc` next to `bleu::objc`.
  `objc::borrow` is a free function, not a method.
* `??` cannot be used with `return` or `continue`. Use `try`/`else` or an explicit branch.
* `mem::equals` needs arguments of the same type.
* `$elif` is not supported. Use nested `$if`/`$else`.
* A `Connection` may only be used by the thread that initialised it. The bus is opened and
  freed on the worker thread, and the probe uses a separate short-lived connection.
* A slice of a local array dangles once the function returns. Copy into the arena or into the
  backend.
* `foreach (&x : ...)` already yields pointers.
* Contract `@return?` lines must come before any text in the contract.
* Long-running timers in the mock need a generation guard, or a timer from an earlier test
  fires into a later one.

## 4. How it was checked

* Six-target type-check: `bash /tmp/claude-0/netcheck.sh bleu_core bleu_rt bleu_service bleu_dbus bleu_objc bleu_win bleu_dl bleu_network`
  (filtered libdir; `tools/check.sh` cannot be used while other libs are unfinished). Result:
  `ok` for linux-x64, linux-aarch64, macos-aarch64, macos-x64, windows-x64, windows-aarch64.
* Linux run: `libs/bleu_network.c3l/tests/run.sh`. Result: 78 of 78 tests passed, exit 0.
* Formatting: `c3fmt --check` on `src/*.c3` and `tests/*.c3`. Exit 0.
