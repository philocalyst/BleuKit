<*
 Keyring state and vocabulary, as plain data.

 The published `State` says how secrets travel and whether the default
 collection is locked. It never contains a secret value, and nothing a backend
 publishes or emits carries one. Secret values appear only in the `Secret`
 returned by `read`, inside an operation.
*>
module bleu::secrets;
import std::time, std::collections::maybe, bleu::availability;

<*
 How secret values travel between this process and the keyring daemon.
 `ENCRYPTED` is the Secret Service DH + AES-128-CBC session. `PLAIN` sends the
 value unencrypted over the bus, and happens only when the caller allowed it.
 `NONE` means no session is open.
*>
enum Transport : char
{
	NONE,
	ENCRYPTED,
	PLAIN,
}

<* Whether the default collection is locked. `UNKNOWN` until the first read. *>
enum Lock : char
{
	UNKNOWN,
	UNLOCKED,
	LOCKED,
}

<* The published state: the transport in use and the lock of the default collection. *>
struct State
{
	Transport transport;
	Lock lock;
}

<* One caller-chosen lookup attribute, such as ("ssid", "home"). *>
struct Attribute
{
	String key;
	String value;
}

<*
 A secret's identity and metadata, without its value. `service` and `account`
 together name the entry; `attributes` are extra lookup keys. Keys beginning with
 "bleu." are reserved for the library.
*>
struct Entry
{
	String service;
	String account;
	String label;
	Attribute[] attributes;
	Maybe{Time} created; // empty when the backend does not record it
	Maybe{Time} modified; // empty when the backend does not record it
}

<* What a keyring operation can do here. *>
enum Cap : char
{
	STORE,
	READ,
	DELETE,
	SEARCH,
	UNLOCK,              // explicit unlock, and unlock prompts shown by the keyring
	ENCRYPTED_TRANSPORT, // the DH session is available (values are encrypted on the bus against passive observation; the session is not authenticated)
}

<* A transient: something happened. Re-read `latest()` for the state. *>
enum EventKind : char
{
	STORED,
	DELETED,
	LOCK_CHANGED,
	PROMPT_SHOWN, // the keyring asked the user for something; the operation waits
	PROMPT_ENDED, // the user answered, dismissed, or the wait timed out
}

<* A transient event. `service` and `account` are empty when they do not apply. *>
struct Event
{
	EventKind kind;
	String service;
	String account;
}

<* The requests a caller can make. *>
enum CommandKind : char
{
	STORE,
	READ,
	DELETE,
	SEARCH,
	UNLOCK,
}

<*
 A request queued for the worker. `operation` is a retained `Operation{T}*`
 whose `T` is fixed by `kind` (Entry for STORE, Secret for READ, bool for
 DELETE, Entry[] for SEARCH, Lock for UNLOCK). The strings and bytes in
 `entry` and `value` live in that operation's arena.
*>
struct Command
{
	CommandKind kind;
	void* operation;
	Entry entry;
	Secret value;
}

<* Which concrete mechanism provides the keyring. *>
enum Backend : char
{
	AUTO,
	SECRET_SERVICE,     // Linux: org.freedesktop.secrets over D-Bus
	CREDENTIAL_MANAGER, // Windows: Credential Manager (CredWriteW and friends)
	KEYCHAIN,           // macOS: generic passwords in the login keychain
}

<*
 A secret value. `bytes` is owned by the operation that carries it (see `read`).
*>
struct Secret
{
	char[] bytes;
}