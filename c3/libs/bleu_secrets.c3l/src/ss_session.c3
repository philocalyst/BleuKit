<*
 The Secret Service backend's connection state, and the session negotiation.

 Everything here runs on the keyring worker thread. A `Connection` belongs to
 the thread that initialised it, so `create` probes with its own short-lived
 connection, and the worker initialises the long-lived one.

 Source for the negotiation: Secret Service API, transfer of secrets
 (https://specifications.freedesktop.org/secret-service/latest/ch07s03.html).
*>
module bleu::secrets::ss @feat(LINUX);
import std::atomic;
import std::collections::list, std::time, bleu::deadline, bleu::error, bleu::dbus::bus, bleu::dbus::connection, bleu::dbus::message, bleu::dbus::value, bleu::dbus::marshal, bleu::secrets, bleu::secrets::bignum, bleu::secrets::dh, bleu::secrets::session, bleu::service;

<* One Secret Service backend: the bus, the negotiated session, and what was last read. *>
struct SsBackend
{
	Allocator allocator;
	String bus_address; // "" means the session bus
	Duration prompt_timeout;
	bool allow_plain;
	Connection bus;
	bool bus_ready; // `bus` is initialised, on the worker thread
	KeyringHub* hub; // set by the worker before any command runs
	Transport transport;
	String session; // object path of the negotiated session, "" when none
	char[session::KEY_BYTES] key; // AES key, zeroed when the session ends
	String collection; // object path of the default collection, "" when unknown
	Lock lock;
	bool lock_dirty; // set by the PropertiesChanged handler
	bool watching; // a PropertiesChanged subscription is active on the collection
}

<*
 Replace the text held in `field` by a copy of `value`, freeing the old copy.
*>
fn String set_text(SsBackend* b, String field, String value)
{
	if (field.len > 0) alloc::free(b.allocator, field.ptr);
	return value.len == 0 ? "" : value.copy(b.allocator);
}

<*
 Connect to the bus if needed. Subscriptions die with the connection, so
 the caller must re-establish them after this reconnects.

 @return? error::UNAVAILABLE : "No bus is listening where the address says"
*>
fn void? ensure_bus(SsBackend* b)
{
	if (b.bus.is_open) return;
	if (!b.bus_ready)
	{
		b.bus.init(b.allocator);
		b.bus_ready = true;
	}
	if (b.bus_address.len > 0)
	{
		b.bus.open_address(b.bus_address)!;
	}
	else
	{
		b.bus.open_session()!;
	}
}

<*
 Forget everything tied to the connection: the session, its key, the collection
 and the subscriptions. Called after a disconnect and before the bus is freed.
*>
fn void drop(SsBackend* b)
{
	b.bus.close();
	b.session = set_text(b, b.session, "");
	b.collection = set_text(b, b.collection, "");
	mem::set(&b.key, 0, b.key.len, 0, true);
	b.transport = NONE;
	b.watching = false;
	b.lock_dirty = false;
}

<*
 Make sure a session is open, negotiating one on first use.

 @return? error::UNSUPPORTED : "The service refuses the encrypted session and plain transport was not allowed"
*>
fn void? ensure_session(SsBackend* b)
{
	ensure_bus(b)!;
	if (b.session.len > 0) return;
	if (catch err = open_encrypted(b))
	{
		if (!refused_algorithm()) return err~;
		if (!b.allow_plain)
		{
			return error::raise(
				error::UNSUPPORTED,
				error::Domain.INTERNAL,
				0,
				"the keyring refuses the encrypted session; set Options.allow_plain_transport to send values unencrypted over the bus"
			)~;
		}
		open_plain(b)!;
	}
}

// True when the last failure was the service rejecting the algorithm (org.freedesktop.DBus.Error.NotSupported).
fn bool refused_algorithm()
{
	Detail* detail = error::last();
	return detail.domain == error::Domain.DBUS && detail.message()
		.starts_with("org.freedesktop.DBus.Error.NotSupported");
}

<*
 OpenSession with `dh-ietf1024-sha256-aes128-cbc-pkcs7`: exchange DH public
 values, derive the AES key, and keep the session path.
*>
fn void? open_encrypted(SsBackend* b)
{
	Montgomery group     = dh::group()!;
	Num exponent         = dh::random_private()!;
	Num public_key       = dh::dh_public(&group, &exponent);
	char[] client_public = public_key.to_be_minimal(tmem);

	Message* call = call_message(tmem, SERVICE_PATH, SERVICE_INTERFACE, "OpenSession")!;
	Writer* w     = call.body_writer("sv")!;
	w.append_string(ALGORITHM_DH)!;
	w.begin_variant("ay")!;
	write_bytes(w, client_public)!;
	w.end_variant()!;
	w.finish()!;
	Value[] reply = invoke(b, call, tmem)!;

	char[] server_bytes = bytes_of(reply[0], tmem)!;
	Num server_public   = bignum::from_be(server_bytes)!;
	char[dh::ELEMENT_BYTES] secret;
	dh::dh_shared(&group, &exponent, &server_public, secret[..])!;
	char[session::KEY_BYTES] key = session::hkdf_sha256_key(secret[..]);
	mem::set(secret[..].ptr, 0, secret.len, 0, true);
	mem::set(&exponent, 0, bignum::BYTES, 0, true);
	String path = reply[1].as_object_path()!;
	set_session(b, path, ENCRYPTED, key[..]);
}

<* OpenSession with `plain`: the secret travels unencrypted. Only reached when the caller allowed it. *>
fn void? open_plain(SsBackend* b)
{
	Message* call = call_message(tmem, SERVICE_PATH, SERVICE_INTERFACE, "OpenSession")!;
	Writer* w     = call.body_writer("sv")!;
	w.append_string(ALGORITHM_PLAIN)!;
	w.begin_variant("s")!;
	w.append_string("")!;
	w.end_variant()!;
	w.finish()!;
	Value[] reply                   = invoke(b, call, tmem)!;
	char[session::KEY_BYTES] no_key = { };
	set_session(b, reply[1].as_object_path()!, PLAIN, no_key[..]);
}

<* Record the negotiated session. The key is copied in; an empty key is recorded as zeros. *>
fn void set_session(SsBackend* b, String path, Transport transport, char[] key)
{
	b.session = set_text(b, b.session, path);
	mem::copy(&b.key, key.ptr, key.len);
	b.transport = transport;
}