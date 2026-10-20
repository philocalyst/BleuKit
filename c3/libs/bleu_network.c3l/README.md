# bleu_network

The network service: Wi-Fi (scan, visible networks, connect with a passphrase or
to an open network, disconnect, forget, autoconnect, radio), the passphrase
prompt, Ethernet and wired interface state, traffic counters and connectivity.
Module root `bleu::network`. Spec: `docs/research/network.md` (v1 cut, section 6);
what was implemented and verified: `docs/research/network_impl.md`.

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
Reader{Event}* events = net.subscribe()!;                // NETWORKS_CHANGED, CONNECTION_CHANGED, CREDENTIALS_WANTED ...
net.capability(WIFI_SECRET_PROMPT).ok();                 // every operation has a Cap; unsupported ones say why
```

`State` is plain data: `Wifi` (phase, failure, connected SSID, networks),
`AccessPoint` (SSID bytes and label, BSSID, MHz, band, dBm, quality, security,
in use, known), `Interface` (link, carrier, speed, counters), `connectivity`,
`location`. Backends: `networkmanager` (Linux), `corewlan` (macOS), `wlanapi`
(Windows).

## Coverage matrix

Legend: **Run** = executed on Linux against fakes (mock NetworkManager on a
private D-Bus daemon, fake sysfs, pure tests); **Compiled** = type-checked for
the target only, never executed; **Not done** = not implemented, the Cap says so.

| Capability | Linux / NetworkManager | macOS / CoreWLAN | Windows / WLAN API |
| --- | --- | --- | --- |
| Radio on/off (`WIFI_RADIO`) | Run (mock) | Compiled | Not done (Radios consent path) |
| Scan (`WIFI_SCAN`) | Run (mock: RequestScan, LastScan) | Compiled | Compiled (accepted; result by next read) |
| Connect open (`WIFI_CONNECT_OPEN`) | Run (mock) | Compiled | Compiled (profile XML: `wlan_profile_test`) |
| Connect PSK / SAE (`WIFI_CONNECT_PSK`) | Run (WPA2-PSK wrong and right passphrase, WPA3-SAE) | Compiled | Compiled (WPA2PSK, WPA3SAE profile XML tested) |
| Disconnect (`WIFI_DISCONNECT`) | Run | Compiled | Compiled (accepted) |
| Forget (`WIFI_FORGET`) | Run | Not done (no profile API) | Compiled |
| Autoconnect (`WIFI_AUTOCONNECT`) | Run | Not done | Not done |
| Passphrase prompt (`WIFI_SECRET_PROMPT`) | Run (mock agent: answer and refusal) | Not done (password is up front) | Not done (key is up front) |
| SSID bytes and label | Run (incl. non-UTF-8 SSID) | Compiled (withheld -> empty) | Compiled |
| BSSID (`WIFI_BSSID`) | Run | Compiled (withheld without Location) | Compiled |
| Signal in dBm (`WIFI_SIGNAL_DBM`) | Not done (NM gives strength 0-100 only) | Compiled | Compiled |
| Interface link state / carrier | Run (sysfs) | Not done | Not done (IP Helper not bound) |
| Interface speed | Run (sysfs) | Not done | Not done |
| Traffic counters | Run (sysfs; refresh shown) | Not done | Not done (IP Helper) |
| Connectivity | Run (mock property) | Not done | Not done |
| Location authorization (`location`) | not applicable | Compiled (UNVERIFIED on macOS) | not applicable |
| Events (`subscribe`) | Run (CONNECTION_CHANGED, CREDENTIALS_WANTED) | Compiled (delegate) | Compiled (notification enqueues) |
| Pure conversions (security, bands, reasons, phases, profile XML, sysfs words, SSID labels) | Run (`compile-test`, 26 tests) | Compiled | Compiled |

## Not done

* 802.1X / enterprise, WEP, hidden SSID, VPN, hotspot, cellular, iwd, wpa_supplicant,
  ConnMan, macOS Apple80211 (private): deferred by the v1 cut (research section 6).
  Enterprise and WEP are detected and refused with UNSUPPORTED.
* The real NetworkManager was never run; the mock implements the subset of its API
  the backend uses, and the failure reasons are the mock's, not NM's (see impl notes).
* Linux: radio state of the hardware switch (only the software switch is reported),
  DNS/IP addresses, metered flag, device hot-plug beyond the next read.
* macOS: nothing was executed; `known` and `autoconnect` cannot be read from CoreWLAN;
  no connectivity; withheld SSIDs appear as empty names (one entry per withheld access point).
* Windows: nothing was executed. The WLAN failure reason is not decoded (a failed join
  reports BACKEND_FAILURE). The radio, autoconnect and IP Helper parts are not done.
  Notifications only enqueue a refresh; scan and disconnect complete when the request is accepted.
* The `Event` kinds `CREDENTIALS_WITHDRAWN` and `INTERFACES_CHANGED` exist; the withdrawal
  is not published yet (a cancelled prompt is answered on the bus, no event is emitted).

## Verified how

* Linux, executed: `libs/bleu_network.c3l/tests/run.sh` starts a private `dbus-daemon`
  with `tests/nm_mock.py` (python `dbus-next`), builds a fake `/sys/class/net` tree
  and runs `c3c compile-test` over 26 pure tests and the 2 end-to-end tests
  (`tests/nm_scenario_test.c3`). Result: 78 of 78 tests pass; the 50 others are the
  dependency libraries' own tests, which the same compile pulls in. Passed on every run.
* Type-checked for all six targets: `c3c ... --target <t> compile-only tools/empty.c3`
  for linux-x64, linux-aarch64, macos-aarch64, macos-x64, windows-x64, windows-aarch64.
  `tools/check.sh` itself passes `--libdir libs`, which the unfinished libraries break;
  the check was run through a libdir of the network dependencies only.
* `c3fmt --check` is clean for every file in `src/` and `tests/`.

## Running the tests

```
libs/bleu_network.c3l/tests/run.sh          # needs dbus-daemon, c3c, python3 (+ dbus-next, installed in a venv if needed)
BLEU_NETWORK_PYTHON=/path/to/python libs/bleu_network.c3l/tests/run.sh   # a python that has dbus-next
BLEU_NETWORK_KEEP=1 libs/bleu_network.c3l/tests/run.sh                   # keep the work dir with the mock's logs
```
