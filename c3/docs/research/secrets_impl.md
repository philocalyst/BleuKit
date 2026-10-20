# secrets: implementation notes

Library: `libs/bleu_secrets.c3l` (module root `bleu::secrets`). Spec:
`docs/research/apps_sysinfo_secrets_appearance.md`, part C (v1 cut). Coverage
and limits: `libs/bleu_secrets.c3l/README.md`.

## Deviations from the research note

1. **Prompts are implemented, not failed fast.** The v1 cut says "fail fast with
   AUTH_REQUIRED instead". The task asked for `UnlockPrompt` as an event and a
   bounded, cancellable wait. Implemented in `ss_prompt.c3`: subscribe to
   `Completed` before `Prompt`, wait until the operation's deadline or
   cancellation, dismiss on both. Events PROMPT_SHOWN and PROMPT_ENDED.
2. **Unlock prompt is an event, not a `Phase`.** `bleu::operation` has fixed
   phases; the operation stays RUNNING while the prompt is shown.
3. **Attributes are looked up by the service, not by the keychain, on macOS.**
   The attribute blob goes into `kSecAttrComment` as hex, because the
   generic-data key `kSecAttrGeneric` appears in none of the sources read.
4. **Ownership marker.** Every item carries `bleu.owner = bleu`; reads, searches
   and deletes only see items with it. This is a design decision, not in the
   research note.
5. **Windows persistence.** `CRED_PERSIST_LOCAL_MACHINE` (the research's
   recommendation). The keyring crate uses `CRED_PERSIST_ENTERPRISE`. Not verified
   against Windows behaviour.
6. **Secret Service method used:** `Item.GetSecret` per item, not `GetSecrets`
   (the crate's `get_secrets` declares no session argument; the spec's
   `GetSecrets` does take one, so `Item.GetSecret` is the unambiguous path).

## What was verified, and how

| Fact | Source(s) |
| --- | --- |
| DH prime (RFC 2409 group 2), generator 2 | RFC 2409 section 6.2 hex block; crate `session.rs` bytes; RFC closed form `2^1024-2^960-1+2^64*(floor(2^894 pi)+129093)` checked with a Machin pi. All three agree. |
| Algorithm names, `Secret` = `(oayays)`, `Item.GetSecret(o)` | Spec `transfer-secrets`, `Types` (14.1.1), `Item`; crate `ss.rs`, `proxy/item.rs` |
| Public keys minimal big-endian; secret = HKDF-SHA256 (no salt, empty info) to 16 bytes; AES-128-CBC PKCS#7 | Spec `ch07s03.html` (7.3); crate `session.rs` `derive_shared`, `hkdf` |
| Shared secret padded to 128 bytes before HKDF | Crate `session.rs` lines 88-92 only. The spec does not say; this is the one place where interop depends on a single source. |
| Prompt: `Prompt(s)`, `Dismiss()`, `Completed(b, v)`; dismissal emits `dismissed = true` | Spec `org.freedesktop.Secret.Prompt`, `prompts.html`; crate `proxy/prompt.rs` |
| `Session.Close()` | Spec `org.freedesktop.Secret.Session` |
| `Created`/`Modified` are UNIX seconds | Spec `org.freedesktop.Secret.Item` properties |
| Credential Manager constants and layouts | Wine `wincred.h` (lines 92-106, 65-71, 191-226, 252, 281); `winerror.h` 1011 (`ERROR_NOT_FOUND`). Microsoft Learn's `CREDENTIALW` page was not fetched; Wine is the single header source here. |
| Keychain item functions and constants | `security-framework-sys-2.14.0` `keychain_item.rs` and `item.rs` (two independent sources with keyring for -25300) |
| Keychain status codes | `base.rs` (-50, -25293, -25299, -25300); `keyring-3.6.2` `macos.rs` (-25291, -25300); `security-framework-3.0.1` example (-128) |
| `CFDictionaryCreate` and callback structs | `core-foundation-sys-0.8.7` `dictionary.rs` |

Not verified: Apple's own headers (`SecItem.h`, `SecBase.h`, `CFDictionary.h`) were
not readable here; the Apple developer pages are JavaScript-rendered. The DH
shared-secret padding is not in the spec.

## Crypto

* `std::crypto::aes` (labelled "Experimental implementation" in the standard
  library) with `CBC`, checked against `openssl enc` (`tests/gen_vectors.py`).
* HKDF is written here (the standard library has HMAC and SHA-256, no HKDF);
  checked against Python `hmac`/`hashlib`.
* Modexp: a fixed 1024-bit CIOS Montgomery multiplication (`bignum.c3`), checked
  against Python `pow` on 13 vectors. The standard library's `BigInt` was not used:
  it is not constant time either, and a fixed-size type keeps the code small.
  Not constant time.

## Defects found while testing (fixed)

* `ss_driver.c3`: the trial connection in `create` was initialised twice (the
  trial struct did not set `bus_ready`), leaking the connection's lists. Found by the
  leak check on the live tests. Fixed by setting `.bus_ready = true`.
* `mock` (test only): dbus-next marshals a STRUCT from a list, not a tuple; the mock
  had tuples, so GetSecret failed on the bus side. Fixed in `secret_service_mock.py`.
* `error::last()` is per thread and was showing a stale DH error from an earlier
  unit test on the same test thread. Not a library bug; noted so nobody chases it.

## Shared-library observations (for the lead)

* `bleu_dbus` (committed `6fad9ad`): `src/address.c3:152` has an `if (!env::LINUX) return ...`
  that makes the following case unreachable on every target. Reported as a warning
  by `c3c` on all targets; harmless, but noisy.
* `bleu_dbus` working tree was mid-edit (`server.c3`, `server_model.c3` untracked, and
  `connection.c3` and `message.c3` modified) while this library was being tested;
  the live tests were run against the committed snapshot for a while. Later runs use
  the repo tree (see `README.md`, "Verified how").
* `bleu::error::Domain` has no value for OSStatus. Keychain failures use `INTERNAL`
  with the status in `code` and the call name in the message. A `Domain.OSSTATUS`
  would be the right value.
* `bleu_dbus`'s `errors::for_name` maps `org.freedesktop.DBus.Error.NotSupported` to
  `BACKEND_FAILURE`; this library checks the name itself (`refused_algorithm`).
  Mapping it to `UNSUPPORTED` in `bleu_dbus` would remove that string test.

## Tests

* `tests/run.sh`: six live modes (normal, no-collection, refuse-dh, locked,
  dismiss, hang) plus all pure unit tests, each run. Last run: all six modes pass.
* `tools/check.sh` (repo libs, six targets): clean for `bleu_core bleu_rt
  bleu_service bleu_dbus bleu_objc bleu_win bleu_secrets`.
