<*
 The keyring service: store, read, delete and search secrets; watch the lock.

 Keyring* keyring = secrets::open(mem)!;
 defer keyring.close();
 Operation{Entry}* stored = keyring.store({ .service = "bleu.wifi", .account = "home" }, password)!;
 defer stored.release();
 stored.wait(time::sec(10))!;

 Secret values travel only inside `Operation{Secret}` (see `read`). Neither the
 published state nor the events carry one.

 Only entries written by this library are read, searched or deleted: every one
 is marked with the reserved attribute `bleu.owner`, so a caller cannot use the
 service to enumerate the user's other secrets.

 Every method may be called from any thread.
*>
module bleu::secrets;
import std::collections::enummap, std::time, bleu::error, bleu::availability, bleu::observe, bleu::stream, bleu::service, bleu::operation, bleu::secrets::wipe;

alias KeyringHub = Hub{State, Command, Event};
alias Capabilities = EnumMap{Cap, Availability};

<* Attribute keys the library reserves for itself. Callers may not use them. *>
const RESERVED_PREFIX = "bleu.";

<* How long a prompt may keep an operation waiting before it is dismissed: 120 s. *>
const Duration DEFAULT_PROMPT_TIMEOUT = (Duration)120_000_000;

<* How `open` finds and tunes a backend. *>
struct Options
{
	Backend backend; // AUTO tries every backend of the platform in priority order
	String bus_address; // Linux: D-Bus address of the bus; "" means the session bus. Tests use a private bus.
	Duration prompt_timeout; // how long a prompt may wait; 0 means the default (120 s)
	bool allow_plain_transport; // send values unencrypted when the service refuses the DH session. Default false.
}

struct Keyring
{
	Allocator allocator;
	KeyringHub hub;
	Driver* driver;
	void* driver_state;
	Capabilities capabilities;
	WipingAllocator operations; // arenas of every operation: zeroed when freed
}

<*
 Open the first working backend of this platform (or the one in `options`).

 @param allocator : "Allocator for the service and its snapshots"
 @return? error::UNAVAILABLE : "No keyring service answers here"
 @return? error::UNSUPPORTED : "The requested backend does not exist on this platform"
*>
fn Keyring*? open(Allocator allocator, Options options = { })
{
	if (options.prompt_timeout == time::DURATION_ZERO) options.prompt_timeout = DEFAULT_PROMPT_TIMEOUT;
	Driver* driver = select_driver(options)!;
	Keyring* self  = alloc::new(allocator, Keyring);
	self.allocator = allocator;
	self.driver = driver;
	self.operations.inner = allocator;
	self.driver_state = driver.create(allocator, options, &self.capabilities)!;
	if (catch err = self.hub.start(allocator, "secrets", driver.info.name, driver.run, self.driver_state))
	{
		driver.destroy(allocator, self.driver_state);
		alloc::free(allocator, self);
		return err~;
	}
	return self;
}

<* Stop the backend and release everything. Operations still held by callers stay valid until released. *>
fn void Keyring.close(&self)
{
	self.hub.stop();
	self.driver.destroy(self.allocator, self.driver_state);
	Allocator allocator = self.allocator;
	alloc::free(allocator, self);
}

<* Name of the backend in use, for diagnostics ("secret-service", "credential-manager", "keychain"). *>
fn String Keyring.backend_name(&self) => self.hub.backend_name;

<* Whether `cap` works with this backend, and if not, why. *>
fn Availability Keyring.capability(&self, Cap cap) => self.capabilities.values[cap.ordinal];

<*
 The newest state, retained for the caller (call `release()` on it).

 @return? error::UNAVAILABLE : "The backend has not published a state yet"
*>
fn Snapshot{State}*? Keyring.latest(&self) => self.hub.latest();

<*
 Block until a state newer than `seen` exists. Start with `seen = 0`.

 @return? TIMEOUT : "Nothing changed in time"
 @return? error::DISCONNECTED : "The service was closed"
*>
fn Snapshot{State}*? Keyring.wait_after(&self, ulong seen, Duration timeout = time::FOREVER)
{
	return self.hub.state.wait_after(seen, timeout);
}

<* Subscribe to transient events. Only events after this call are delivered. *>
fn Reader{Event}*? Keyring.subscribe(&self) => self.hub.events.subscribe();

<*
 Store `value` under `entry`, replacing an entry with the same service and account.
 The value is copied into the operation; the caller may wipe its own buffer
 afterwards. The operation completes with the entry as stored.

 @param value : "The secret bytes"
 @return? error::INVALID_ARGUMENT : "The service or account is empty, or an attribute key is reserved"
 @return? error::UNAVAILABLE : "The command queue is full or the library is closing"
*>
fn Operation{Entry}*? Keyring.store(&self, Entry entry, char[] value)
{
	check_key(entry)!;
	Operation{Entry}* op = operation::begin{Entry}(&self.operations);
	Command command = {
		.kind = STORE,
		.entry = copy_entry(op.allocator(), entry),
		.value = { .bytes = alloc::clone_slice(op.allocator(), value) },
	};
	command.operation = (void*)op.retain();
	if (catch err = self.hub.post(command))
	{
		op.release();
		op.release();
		return err~;
	}
	return op;
}

<*
 Read the secret of `entry` (only its service and account are used).
 The returned operation holds the value; `wipe()` the `Secret` when done.

 @return? NOT_FOUND : "No entry with this service and account (completes the operation)"
 @return? error::AUTH_REQUIRED : "The keyring is locked and the user did not unlock it"
*>
fn Operation{Secret}*? Keyring.read(&self, Entry entry)
{
	check_key(entry)!;
	Operation{Secret}* op = operation::begin{Secret}(&self.operations);
	Command command       = { .kind = READ, .entry = copy_entry(op.allocator(), entry) };
	command.operation = (void*)op.retain();
	if (catch err = self.hub.post(command))
	{
		op.release();
		op.release();
		return err~;
	}
	return op;
}

<*
 Delete the entry with this service and account. The operation completes with
 `true` when an entry was removed and `false` when there was none.

 @return? error::INVALID_ARGUMENT : "The service or account is empty"
*>
fn Operation{bool}*? Keyring.delete(&self, Entry entry)
{
	check_key(entry)!;
	Operation{bool}* op = operation::begin{bool}(&self.operations);
	Command command     = { .kind = DELETE, .entry = copy_entry(op.allocator(), entry) };
	command.operation = (void*)op.retain();
	if (catch err = self.hub.post(command))
	{
		op.release();
		op.release();
		return err~;
	}
	return op;
}

<*
 Find entries written by this library whose attributes contain every attribute
 of `filter`, and whose service and account match when those are non-empty.
 Values are not returned.

 @return? error::INVALID_ARGUMENT : "An attribute key is reserved"
*>
fn Operation{Entry[]}*? Keyring.search(&self, Entry filter)
{
	check_attributes(filter.attributes)!;
	Operation{Entry[]}* op = operation::begin{Entry[]}(&self.operations);
	Command command        = { .kind = SEARCH, .entry = copy_entry(op.allocator(), filter) };
	command.operation = (void*)op.retain();
	if (catch err = self.hub.post(command))
	{
		op.release();
		op.release();
		return err~;
	}
	return op;
}

<*
 Unlock the default collection, showing the keyring's prompt if it asks for one.
 The operation completes with the resulting lock state. Cancelling it dismisses
 the prompt.
*>
fn Operation{Lock}*? Keyring.unlock(&self)
{
	Operation{Lock}* op = operation::begin{Lock}(&self.operations);
	Command command     = { .kind = UNLOCK };
	command.operation = (void*)op.retain();
	if (catch err = self.hub.post(command))
	{
		op.release();
		op.release();
		return err~;
	}
	return op;
}

// Mandatory identity of an entry: a service and an account, and no reserved attribute keys.
fn void? check_key(Entry entry)
{
	if (entry.service.len == 0 || entry.account.len == 0) return error::INVALID_ARGUMENT~;
	check_attributes(entry.attributes)!;
}

fn void? check_attributes(Attribute[] attributes)
{
	foreach (attribute : attributes)
	{
		if (attribute.key.len == 0) return error::INVALID_ARGUMENT~;
		if (attribute.key.starts_with(RESERVED_PREFIX)) return error::INVALID_ARGUMENT~;
	}
}

// Deep copy of `entry` into `allocator`, so the operation owns everything it refers to.
fn Entry copy_entry(Allocator allocator, Entry entry)
{
	Attribute[] attributes = alloc::alloc_array(allocator, Attribute, entry.attributes.len);
	foreach (i, attribute : entry.attributes)
	{
		attributes[i] = { .key = attribute.key.copy(allocator), .value = attribute.value.copy(allocator) };
	}
	return {
		.service = entry.service.copy(allocator),
		.account = entry.account.copy(allocator),
		.label = entry.label.copy(allocator),
		.attributes = attributes,
		.created = entry.created,
		.modified = entry.modified,
	};
}