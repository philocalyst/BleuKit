# bleu_network

The network service: Wi-Fi (scan, visible networks, connect with a passphrase or
to an open network, disconnect, forget, autoconnect, radio), the passphrase
prompt, Ethernet and wired interface state, traffic counters and connectivity.
Module root `bleu::network`. Spec: `docs/research/network.md` (v1 cut, section 6);
the review of this library and the state of each finding: `docs/reviews/bleu_network.md`.

## Public API

```c3
Network* net = network::open(mem, { .backend = AUTO, .poll = time::sec(5) })!;
defer net.close();
Snapshot{State}* s = net.wait_after(0, time::sec(5))!;   // state, published, never mutated
ConnectOp* op = net.connect({ .ssid = (char[])"Office", .passphrase = "...", .autoconnect = true })!;
Connected joined = op.wait(time::sec(60))!;              // Operation{Connected}: AUTH_REQUIRED on refusal
SettleOp* down = net.disconnect()!;                      // Operation{Settled}: CHANGED or ALREADY
net.scan()!; net.forget(ssid)!; net.set_radio(false)!; net.set_autoconnect(ssid, false)!;
net.supply_credentials(request, "secret")!; net.cancel_credentials(request)!;  // answer CREDENTIALS_WANTED
Reader{Event}* events = net.subscribe()!;                // NETWORKS_CHANGED, CONNECTION_CHANGED, CREDENTIALS_WANTED, CREDENTIALS_WITHDRAWN ...
net.capability(WIFI_SECRET_PROMPT).ok();                 // every operation has a Cap; unsupported ones say why
```

`open` returns once the backend has published its first picture, so every
capability is final by then. `State` is plain data: `Wifi` (phase, failure,
connected SSID, networks), `AccessPoint` (SSID bytes and label, BSSID, MHz, band,
dBm, quality, security, in use, known), `Interface` (link, carrier, speed,
counters), `connectivity`, `location`, and `stale`: the parts that a failed read
could not refresh. A stale part keeps the value of the previous picture, so a
transient failure changes nothing a shell shows. Backends: `networkmanager`
(Linux), `corewlan` (macOS), `wlanapi` (Windows).

## Coverage matrix

Legend: **Run** = executed on Linux against fakes (mock NetworkManager on a
private D-Bus daemon, fake sysfs, pure tests); **Compiled** = type-checked for
the target only, never executed; **Not done** = not implemented, the Cap says so.

| Capability | Linux / NetworkManager | macOS / CoreWLAN | Windows / WLAN API |
| --- | --- | --- | --- |
| Radio on/off (`WIFI_RADIO`) | Run (mock) | Compiled | Not done (Radios consent path) |
| Scan (`WIFI_SCAN`) | Run (mock: RequestScan, LastScan) | Compiled | Compiled (completes on the scan-complete notification, TIMEOUT otherwise) |
| Connect open (`WIFI_CONNECT_OPEN`) | Run (mock) | Compiled | Compiled (keyless profile: `wlan_profile_test`) |
| Connect PSK / SAE (`WIFI_CONNECT_PSK`) | Run (WPA2-PSK wrong and right passphrase, WPA3-SAE) | Compiled | Compiled (profile XML and route tested; a saved profile is used without a passphrase) |
| Disconnect (`WIFI_DISCONNECT`) | Run | Compiled | Compiled (completes when the interface leaves the network) |
| Forget (`WIFI_FORGET`) | Run (every profile of the SSID) | Not done (no profile API) | Compiled |
| Autoconnect (`WIFI_AUTOCONNECT`) | Run | Not done | Not done |
| Passphrase prompt (`WIFI_SECRET_PROMPT`) | Run (mock agent: answer, refusal, superseded, refused agent) | Not done (password is up front) | Not done (key is up front) |
| SSID bytes and label | Run (incl. non-UTF-8 SSID) | Compiled (withheld -> empty) | Compiled |
| BSSID (`WIFI_BSSID`) | Run | Compiled (withheld without Location) | Compiled |
| Signal in dBm (`WIFI_SIGNAL_DBM`) | Not done (NM gives strength 0-100 only) | Compiled | Compiled |
| Interface link state / carrier | Run (sysfs) | Not done | Not done |
| Interface speed | Run (sysfs) | Not done | Not done |
| Traffic counters | Run (sysfs; refresh shown) | Not done | Not done (IP Helper) |
| Connectivity | Run (mock property) | Not done | Not done |
| Location authorization (`location`) | not applicable | Compiled (UNVERIFIED on macOS) | not applicable |
| Events (`subscribe`) | Run (CONNECTION_CHANGED, CREDENTIALS_WANTED, CREDENTIALS_WITHDRAWN) | Compiled (delegate) | Compiled (notification enqueues) |
| Failed sub-read keeps the previous part (`stale`) | Run (mock fault: access point list fails; access point that left) | Not applicable (no failing read) | Compiled (same shape as Linux) |
| Pure conversions (security, bands, reasons, phases, profile XML, sysfs words, SSID labels, merges) | Run (`compile-test`) | Compiled (CoreWLAN convert tests run on Linux) | Compiled (profile tests run on Linux) |

## Not done

* 802.1X / enterprise, WEP, hidden SSID, VPN, hotspot, cellular, iwd, wpa_supplicant,
  ConnMan, macOS Apple80211 (private): deferred by the v1 cut (research section 6).
  Enterprise and WEP are detected and refused with UNSUPPORTED.
* The real NetworkManager was never run; the mock implements the subset of its API
  the backend uses, and the failure reasons are the mock's, not NM's (see impl notes).
* Linux: when the bus is lost the service stops: it publishes the empty picture and
  refuses new commands (UNAVAILABLE). It does not reconnect. Radio state of the hardware
  switch (only the software switch is reported), DNS/IP addresses, metered flag, device
  hot-plug beyond the next read. A saved profile keeps its autoconnect setting when it is
  joined again (`connect` documents it); `set_autoconnect` changes it.
* macOS: nothing was executed. `known` and `autoconnect` cannot be read from CoreWLAN;
  no connectivity. Withheld SSIDs appear as empty names, one entry per withheld access
  point (they cannot be identified). Location Services is not requested by bleu: the
  host app must request it (`connect` refuses with PERMISSION_DENIED and says how).
* Windows: nothing was executed. The WLAN failure reason is not decoded (a failed join
  reports BACKEND_FAILURE). Only the first Wi-Fi interface is used. The radio, autoconnect
  and IP Helper parts are not done. Notifications only enqueue a refresh, and a scan
  notification completes the scan in progress. Profiles are named `bleu-<hex of the SSID>`:
  bleu never overwrites a profile of another name, but a user profile with that exact name
  would be replaced.

## Verified how

* Linux, executed: `libs/bleu_network.c3l/tests/run.sh` starts a private `dbus-daemon`
  with `tests/nm_mock.py` (python `dbus-next`), builds a fake `/sys/class/net` tree,
  switches the mock's faults on and off, and runs `c3c compile-test` over 51 bleu_network
  tests: the pure tests, and the end-to-end tests in `tests/nm_scenario_test.c3`. All pass
  on every run. The same compile pulls in the dependency libraries' own tests.
* Each end-to-end regression test was run against the library before its fix and failed
  there (the access point list, the sub-read, the failed-read settle, the superseded
  prompt, the refused agent, the duplicate profiles).
* Type-checked for all six targets: `tools/check.sh bleu_core bleu_rt bleu_service
  bleu_dbus bleu_objc bleu_win bleu_dl bleu_network`, which compiles the library for
  linux-x64, linux-aarch64, macos-aarch64, macos-x64, windows-x64 and windows-aarch64.
* `c3fmt --check` is clean for every file in `src/` and `tests/`.

## Running the tests

```
libs/bleu_network.c3l/tests/run.sh          # needs dbus-daemon, c3c, python3 (+ dbus-next, installed in a venv if needed)
BLEU_NETWORK_PYTHON=/path/to/python libs/bleu_network.c3l/tests/run.sh   # a python that has dbus-next
BLEU_NETWORK_KEEP=1 libs/bleu_network.c3l/tests/run.sh                   # keep the work dir with the mock's logs
```

`c3c` writes `out/`, `obj/` and the test binary into a private work directory, never
into the checkout, so runs do not collide. The mock's `__pycache__` is not written.
