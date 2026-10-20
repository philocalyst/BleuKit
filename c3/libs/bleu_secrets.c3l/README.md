# bleu_secrets

A platform keyring: store, read, delete and search small secrets (Wi-Fi and VPN
passwords, tokens) keyed by a service and an account. Module root `bleu::secrets`.

* Linux: freedesktop Secret Service over D-Bus (`org.freedesktop.secrets`), with the
  encrypted `dh-ietf1024-sha256-aes128-cbc-pkcs7` session; `plain` only when allowed.
* Windows: Credential Manager (`CredWriteW`, `CredReadW`, `CredDeleteW`, `CredEnumerateW`).
* macOS: login-keychain generic passwords (`SecItemAdd`, `SecItemCopyMatching`, `SecItemUpdate`, `SecItemDelete`).

Design and sources: `docs/research/apps_sysinfo_secrets_appearance.md` (part C);
implementation notes and deviations: `docs/research/secrets_impl.md`.

## Public API

```c3
Keyring* keyring = secrets::open(mem, { .allow_plain_transport = false })!;
defer keyring.close();
Operation{Entry}* stored = keyring.store({ .service = "bleu.wifi", .account = "home" }, password)!;
defer stored.release();
stored.wait(time::sec(10))!;
Operation{Secret}* read = keyring.read({ .service = "bleu.wifi", .account = "home" })!;
defer read.release();
Secret secret = read.wait(time::sec(10))!;   // bytes live in the operation; secret.wipe() when done
Snapshot{State}* state = keyring.latest()!;  // transport and lock state, never secrets
```

* `open(allocator, Options)`: the first working backend; `Options.backend`, `bus_address` (Linux), `prompt_timeout`, `allow_plain_transport`.
* `store(Entry, char[])`, `read(Entry)`, `delete(Entry)`, `search(Entry filter)`, `unlock()`: each returns an `Operation{T}*`.
* `latest()`, `wait_after(seen, timeout)`: the published `State{Transport, Lock}`.
* `subscribe()`: `Event{kind, service, account}`: STORED, DELETED, LOCK_CHANGED, PROMPT_SHOWN, PROMPT_ENDED.
* `capability(Cap)`: STORE, READ, DELETE, SEARCH, UNLOCK, ENCRYPTED_TRANSPORT.
* Attribute keys beginning with `bleu.` are reserved. Only entries this library wrote (marked `bleu.owner=bleu`) are read, searched or deleted.

## Coverage

Run = executed on Linux against a private `dbus-daemon` and the Python mock
(`tests/run.sh`, six modes). Compiled-only = type-checked for the target with
`tools/check.sh`, never executed. Not done = refused or absent (see the list below).

| Capability | Linux / Secret Service | Windows / Credential Manager | macOS / Keychain |
| --- | --- | --- | --- |
| STORE, READ, DELETE | Run (normal, no-collection) | Compiled-only | Compiled-only |
| SEARCH | Run | Compiled-only | Compiled-only |
| UNLOCK, unlock prompt | Run (locked; prompt accepted) | Not done (UNSUPPORTED_OS) | Not done (UNSUPPORTED_OS) |
| Prompt dismissed / timed out / cancelled | Run (dismiss, hang) | Not done | Not done |
| ENCRYPTED_TRANSPORT (DH + AES) | Run (mock, against the crate's conventions) | Not done (UNSUPPORTED_OS) | Not done (UNSUPPORTED_OS) |
| Plain transport, only when allowed | Run (refuse-dh + allow) | Not done | Not done |
| Refusal without permission | Run (refuse-dh) | Not done | Not done |
| Lock change by another client | Compiled-only (PropertiesChanged handler; not asserted) | Not done | Not done |
| Pure: DH modexp, HKDF, AES-CBC, names, codes, blob, wipe | Run (27 `@test` functions in this library, plus 12 live) | Pure parts run on Linux | Pure parts run on Linux |

## Not done

* KWallet, DPAPI, the macOS data-protection keychain (needs entitlements), and
  Credential Manager's roaming persistence (`CRED_PERSIST_ENTERPRISE`).
* Live tests against a real keyring daemon (gnome-keyring, KWallet, KeePassXC):
  none is installed in the development container. Interop is checked against the
  Python mock and the conventions of secret-service-4.0.0 (shared secret padded to
  128 bytes, HKDF with no salt).
* Windows and macOS have never run. The Windows and macOS code is type-checked only.
* macOS: keychain prompts happen inside the call and cannot be bounded or observed.
  `errSecInteractionNotAllowed` (-25308) is not mapped (no verified source).
  Created and modified times are not read.
* Windows: no Created time (Credential Manager does not keep one).
* Secret Service: `Session.Close` is not sent; the service ends the session when
  the connection closes. `GetSecrets` (batch) is not used.
* The DH modexp is not constant time (see `bignum.c3`).
* Zeroing covers the operation's arena and the backend's AES key. Copies made by
  callers, and the swap file, are not covered.
* The Secret Service bus is not encrypted at the D-Bus level: with
  `allow_plain_transport`, the value crosses the session bus unencrypted.

## Verified how

* `tests/run.sh`: six live modes plus the pure unit tests, all passing on Linux
  x86-64 (glibc, C3 0.8.5), against a private `dbus-daemon` and
  `tests/secret_service_mock.py` (dbus-next 0.2.3, cryptography 50.0.2). The mock's
  DH, HKDF and AES are independent Python code (`pow`, `hmac`, `cryptography`).
* Pure vectors: `tests/gen_vectors.py` writes `src/*_vectors_test.c3`: 13 modexp
  rows against Python `pow`; HKDF rows against Python `hmac`; AES-128-CBC rows
  against `openssl enc` and the `cryptography` package.
* `tools/check.sh bleu_core bleu_rt bleu_service bleu_dbus bleu_objc bleu_win bleu_secrets`:
  clean on all six targets.
