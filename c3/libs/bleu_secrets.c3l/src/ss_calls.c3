<*
 Calls to the keyring, the default collection, and the lock state.

 Every call goes through `invoke`, which turns a dropped connection into
 `DISCONNECTED` and forgets the state tied to it, so the next command reconnects.
*>
module bleu::secrets::ss @feat(LINUX);
import std::time;
import std::atomic;
import std::collections::list, bleu::error, bleu::observe, bleu::stream, bleu::dbus::message, bleu::dbus::proxy, bleu::dbus::value, bleu::dbus::marshal, bleu::dbus::connection, bleu::secrets, bleu::secrets::session;

<* How long a call may wait for its reply. Prompts are not calls; they have their own deadline. *>
const Duration CALL_TIMEOUT = (Duration)25_000_000;

<* A method call to `member` on `path`, with an empty body to be written. *>
fn Message*? call_message(Allocator allocator, String path, String interface_name, String member)
{
	return message::method_call(allocator, BUS_NAME, path, interface_name, member);
}

<*
 Send `call`, wait for its reply and decode the reply's values into `allocator`.
 `call` is released here.

 @return? error::DISCONNECTED : "The bus went away; the session and collection are forgotten"
*>
fn Value[]? invoke(SsBackend* b, Message* call, Allocator allocator)
{
	defer call.release();
	Message*? reply = b.bus.call(call, CALL_TIMEOUT);
	if (catch err = reply)
	{
		if (err == error::DISCONNECTED) drop(b);
		return err~;
	}
	Message* answer = reply;
	defer answer.release();
	return read_values(answer, allocator);
}

// Every value of a reply body, decoded into `allocator`.
fn Value[]? read_values(Message* reply, Allocator allocator)
{
	Reader body = reply.reader()!;
	List{Value} values;
	values.init(allocator);
	while (body.has_more())
	{
		Value next = body.read_value(allocator)!;
		values.push(next);
	}
	return values.array_view();
}

<*
 Make sure the default collection's object path is known, creating the
 collection when the keyring has none.
*>
fn void? ensure_collection(SsBackend* b, Atomic{bool}* cancel, String service, String account)
{
	if (b.collection.len > 0) return;
	Message* call = call_message(tmem, SERVICE_PATH, SERVICE_INTERFACE, "ReadAlias")!;
	Writer* w = call.body_writer("s")!;
	w.append_string(DEFAULT_ALIAS)!;
	w.finish()!;
	Value[] reply = invoke(b, call, tmem)!;
	String path = reply[0].as_object_path()!;
	if (path == NO_OBJECT)
	{
		path = create_collection(b, cancel, service, account)!;
	}
	b.collection = set_text(b, b.collection, path);
	ensure_watch(b)!;
}

// CreateCollection under the default alias. Returns the new collection's path.
fn String? create_collection(SsBackend* b, Atomic{bool}* cancel, String service, String account)
{
	Message* call = call_message(tmem, SERVICE_PATH, SERVICE_INTERFACE, "CreateCollection")!;
	Writer* w = call.body_writer("a{sv}s")!;
	w.begin_array("a{sv}")!;
	w.begin_dict_entry()!;
	w.append_string(COLLECTION_LABEL)!;
	w.begin_variant("s")!;
	w.append_string("Bleu keyring")!;
	w.end_variant()!;
	w.end_dict_entry()!;
	w.end_array()!;
	w.append_string(DEFAULT_ALIAS)!;
	w.finish()!;
	Value[] reply = invoke(b, call, tmem)!;
	String path = reply[0].as_object_path()!;
	String prompt = reply[1].as_object_path()!;
	if (prompt != NO_OBJECT) run_prompt(b, prompt, cancel, service, account)!;
	return path.copy(tmem);
}

<* Whether the default collection is locked, read from the service now. *>
fn bool? read_locked(SsBackend* b)
{
	Proxy collection = proxy::for_object(&b.bus, BUS_NAME, b.collection, COLLECTION_INTERFACE)!;
	return collection.get_bool(PROPERTY_LOCKED);
}

<*
 Unlock the default collection. The keyring may ask for a prompt; it is run,
 and the collection must then be unlocked, or the call fails.

 @return? error::AUTH_REQUIRED : "The keyring is still locked after the prompt"
*>
fn void? unlock_collection(SsBackend* b, Atomic{bool}* cancel, String service, String account)
{
	Message* call = call_message(tmem, SERVICE_PATH, SERVICE_INTERFACE, "Unlock")!;
	Writer* w = call.body_writer("ao")!;
	w.begin_array("ao")!;
	w.append_object_path(b.collection)!;
	w.end_array()!;
	w.finish()!;
	Value[] reply = invoke(b, call, tmem)!;
	String prompt = reply[1].as_object_path()!;
	if (prompt != NO_OBJECT) run_prompt(b, prompt, cancel, service, account)!;
	if (read_locked(b)!)
	{
		return error::raise(error::AUTH_REQUIRED, error::Domain.INTERNAL, 0, "the keyring is still locked")~;
	}
}

<* Subscribe to the collection's property changes, so a lock or unlock by someone else is noticed. *>
fn void? ensure_watch(SsBackend* b)
{
	if (b.watching) return;
	Proxy collection = proxy::for_object(&b.bus, BUS_NAME, b.collection, COLLECTION_INTERFACE)!;
	collection.watch_properties(&on_properties, b)!;
	b.watching = true;
}

fn void on_properties(void* context, PropertyChange* change)
{
	((SsBackend*)context).lock_dirty = true;
}

<*
 Read the collection's lock and publish it if it changed. Failures are not
 reported: the state simply keeps its last known value.
*>
fn void refresh_lock(SsBackend* b)
{
	if (b.collection.len == 0 || !b.bus.is_open) return;
	if (try locked = read_locked(b))
	{
		Lock now = locked ? LOCKED : UNLOCKED;
		if (now != b.lock)
		{
			b.lock = now;
			emit(b, LOCK_CHANGED, "", "");
		}
	}
	publish(b);
}

<* Publish the current transport and lock, if they differ from the last published state. *>
fn void publish(SsBackend* b)
{
	Snapshot{State}* snapshot = b.hub.begin();
	snapshot.value = { .transport = b.transport, .lock = b.lock };
	b.hub.publish_if_changed(snapshot);
}

<* Emit a transient event. Strings are copied into the event packet. *>
fn void emit(SsBackend* b, EventKind kind, String service, String account)
{
	Packet{Event}* packet = b.hub.emit_begin();
	packet.value = { .kind = kind, .service = service.copy(packet.allocator()), .account = account.copy(packet.allocator()) };
	b.hub.emit(packet);
}
